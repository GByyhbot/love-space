/// 2.8.0 报备入口 P0 · 离线待发队列（`report_outbox`）。
///
/// 🔴 盘线结论（二选一取舍，回执同口径）：**不走 Drift**，走 peer 链现行
/// 文件持久化惯例（`path_provider` + JSON 原子重写，与 `peer_fatal_log.dart`
/// 同一套 doc 目录写法）。理由：
/// ① 层级：报备队列属于 peer 链，寄生在 `chat_cache.sqlite` 会让 peer 反向
///    依赖 chat 库，而该库有 500 条裁剪窗口与聊天强绑定的语义；
/// ② 风险面：chat_db 加表要抬 schemaVersion（3→4），2.x 历史上「升版打开
///    失败」出过事故（QA2① 根因），为零风险的队列再碰一次升版不值；
/// ③ 量级：队列稳态个位数，串行 flush、整文件原子重写足够，用不到条件查询。
///
/// 🔴 行为铁律（令文二·3）：
/// · **单飞锁**：[flush] 执行期间新触发一律直接返回 skipped，防冷启动
///   「回前台 + SSE 重连 + 组件 initState」三路并发撞同一条重入；
/// · **只重试值得重试的**：网络类错误 / 5xx → 保留（下次再发）；
///   422 关闭 → 出队并回 [FlushResult.closedOff]；其他 4xx → 出队丢弃
///   （毒丸必须清掉，否则一条坏数据卡死整条队列）；
/// · `created=false` = 服务端幂等命中（已达）→ 出队，不提示用户。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'peer_report_api.dart';

/// 队列上限：稳态个位数，超过就丢最旧的（防止长期离线无限增长）。
const int reportOutboxCap = 50;

/// 待发项：完整 body + client_id + 创建时间（令文二·2）。
class PendingReport {
  const PendingReport({
    required this.scene,
    required this.clientId,
    required this.createdAt,
    this.summary = '',
    this.note = '',
    this.placeName = '',
    this.push = true,
  });

  final String scene;
  final String clientId;

  /// 用户点下发送的时刻（unix 秒）——补发时原样作为 `ts`，
  /// 报备时间按「当时」算，不按补发时刻算。
  final double createdAt;

  final String summary;
  final String note;
  final String placeName;
  final bool push;

  static PendingReport? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final scene = (j['scene'] ?? '').toString();
    final clientId = (j['client_id'] ?? '').toString();
    if (scene.isEmpty || clientId.isEmpty) return null;
    return PendingReport(
      scene: scene,
      clientId: clientId,
      createdAt: (j['created_at'] as num?)?.toDouble() ?? 0,
      summary: (j['summary'] ?? '').toString(),
      note: (j['note'] ?? '').toString(),
      placeName: (j['place_name'] ?? '').toString(),
      push: j['push'] is bool ? j['push'] as bool : true,
    );
  }

  Map<String, Object?> toJson() => {
        'scene': scene,
        'client_id': clientId,
        'created_at': createdAt,
        'summary': summary,
        'note': note,
        'place_name': placeName,
        'push': push,
      };
}

/// 一轮 flush 的结果（供 UI 决定是否弹提示）。
class FlushResult {
  const FlushResult({
    this.sent = 0,
    this.dropped = 0,
    this.kept = 0,
    this.closedOff = false,
    this.skipped = false,
  });

  /// 发成功（含 `created=false` 的幂等命中）。
  final int sent;

  /// 出队丢弃（422 关闭 / 其他 4xx 业务错误）。
  final int dropped;

  /// 仍留在队列里的条数。
  final int kept;

  /// 本轮遇到「报备事件共享已关闭」——UI 要弹固定文案。
  final bool closedOff;

  /// 单飞锁拦住（本次没干活）。
  final bool skipped;
}

/// 目录解析器（测试可注入临时目录，避免依赖真机 path_provider）。
typedef OutboxDirProvider = Future<Directory?> Function();

Future<Directory?> _defaultDir() async {
  try {
    final root = await getApplicationDocumentsDirectory();
    final sub = Directory('${root.path}${Platform.pathSeparator}peer-loc');
    if (!sub.existsSync()) sub.createSync(recursive: true);
    return sub;
  } catch (_) {
    return null; // 平台无实现（测试未注入）→ 队列静默降级为空
  }
}

/// 报备待发队列（文件版）。
class ReportOutbox {
  ReportOutbox({OutboxDirProvider? dirProvider})
      : _dirProvider = dirProvider ?? _defaultDir;

  final OutboxDirProvider _dirProvider;
  bool _flushing = false;

  /// 单飞锁状态（测试与调试用）。
  bool get isFlushing => _flushing;

  Future<File?> _file() async {
    try {
      final dir = await _dirProvider();
      if (dir == null) return null;
      return File('${dir.path}${Platform.pathSeparator}report-outbox.json');
    } catch (_) {
      return null;
    }
  }

  /// 读队列（文件不存在 / 损坏 → 空表，绝不抛）。
  Future<List<PendingReport>> load() async {
    try {
      final f = await _file();
      if (f == null || !f.existsSync()) return const [];
      final text = f.readAsStringSync();
      if (text.trim().isEmpty) return const [];
      final raw = jsonDecode(text);
      final list = raw is Map ? raw['items'] : raw;
      if (list is! List) return const [];
      return list
          .map(PendingReport.fromJson)
          .whereType<PendingReport>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  /// 原子重写整表（临时文件 + rename，避免半截文件）。
  Future<void> save(List<PendingReport> items) async {
    try {
      final f = await _file();
      if (f == null) return;
      final body = jsonEncode({
        'items': items.map((e) => e.toJson()).toList(growable: false),
      });
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(body, flush: true);
      tmp.renameSync(f.path);
    } catch (_) {
      // 落盘失败不炸主链：本轮当作「未入队」，UI 仍提示已存待发会不诚实，
      // 故由调用方读取 load() 结果判断；此处保持静默（与 fatal 落盘同口径）。
    }
  }

  /// 入队（同 client_id 去重；超上限丢最旧）。
  Future<void> enqueue(PendingReport item) async {
    final items = [...await load()];
    if (!items.any((e) => e.clientId == item.clientId)) items.add(item);
    while (items.length > reportOutboxCap) {
      items.removeAt(0);
    }
    await save(items);
  }

  /// 按 client_id 出队。
  Future<void> remove(String clientId) async {
    final items = (await load()).where((e) => e.clientId != clientId).toList();
    await save(items);
  }

  /// 串行补发。**进锁即返回 skipped 的那一批什么都不做**（防三路并发重入）。
  Future<FlushResult> flush(Dio dio) async {
    if (_flushing) return const FlushResult(skipped: true);
    _flushing = true;
    var sent = 0;
    var dropped = 0;
    var closedOff = false;
    try {
      final items = await load();
      if (items.isEmpty) return const FlushResult();
      final kept = <PendingReport>[];
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        try {
          await sendReport(
            dio,
            scene: item.scene,
            clientId: item.clientId,
            summary: item.summary,
            note: item.note,
            placeName: item.placeName,
            push: item.push,
            ts: item.createdAt > 0 ? item.createdAt : null,
          );
          sent++; // created=false 也走这里：已达即出队，不提示用户
        } on ReportShareClosed {
          dropped++;
          closedOff = true;
        } on PeerApiException {
          dropped++; // 其他 4xx 业务错误：毒丸出队，别卡死后续
        } catch (_) {
          // 网络类 / 5xx：整批保留（含本条与后续），等下一次触发
          kept
            ..add(item)
            ..addAll(items.skip(i + 1));
          break;
        }
      }
      await save(kept);
      return FlushResult(
        sent: sent,
        dropped: dropped,
        kept: kept.length,
        closedOff: closedOff,
      );
    } finally {
      _flushing = false;
    }
  }
}

/// 全局单例（页面/组件共享，单飞锁才有意义）。
final ReportOutbox reportOutbox = ReportOutbox();
