/// 2.4.5 甲组 · 「已决定（弹或不弹）」id 集合的本地持久化。
///
/// 提示词判定矩阵条件③「按事件/记录 id 本地持久化去重，存储跨 App 重启、
/// 服务重连依然有效」。落 JSON 文件于 application support 目录（不进用户可见区、
/// 不随卸载缓存被清）；主 isolate 与服务 isolate 读同一份文件。
///
/// 🔴 seen 语义（与 notify_decision.dart 对齐）：记的是「已决定过」的 id，
/// 含前台不弹的——否则回后台后同一批消息会被当成新的再弹一遍。
///
/// 上限各 800 条（聊天上限 ≈ 4 个补拉窗口）：LRU 淘汰最旧的；被淘汰的最旧 id
/// 重新变成「未通知」的概率极低（那是一条 800 条之前的旧消息），即便发生，
/// 呈现层同 key 同 androidId 的覆盖语义保证只是更新而非重复弹。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const int kNotifiedCapPerKind = 800;

class NotifiedStore {
  NotifiedStore(this._path);

  final String _path;
  Set<String> _chat = <String>{};
  Set<String> _notice = <String>{};

  /// 自上次 save() 后是否有未落盘变更（服务侧据此决定是否写盘）
  bool dirty = false;

  /// 新增顺序记录（LRU 淘汰依据）：插入序=首次决定序
  final List<String> _chatOrder = <String>[];
  final List<String> _noticeOrder = <String>[];

  static Future<NotifiedStore> loadDefault() async {
    final dir = await getApplicationSupportDirectory();
    final store =
        NotifiedStore('${dir.path}${Platform.pathSeparator}notify_seen.json');
    await store.load();
    return store;
  }

  Future<void> load() async {
    try {
      final raw = await File(_path).readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _chat = ((j['chat'] ?? const []) as List).map((e) => e.toString()).toSet();
      _notice =
          ((j['notice'] ?? const []) as List).map((e) => e.toString()).toSet();
      _chatOrder..clear()..addAll(_chat);
      _noticeOrder..clear()..addAll(_notice);
    } catch (_) {
      // 文件缺失/损坏 = 全新开始：通知可能重弹一次，可接受（宁可弹靠去重防重复
      // 的反面是重启后丢记录；丢失代价是单次重弹，好于漏弹）
      _chat = <String>{};
      _notice = <String>{};
    }
    dirty = false;
  }

  bool contains(String key) {
    if (key.startsWith('chat:')) return _chat.contains(key);
    if (key.startsWith('notice:')) return _notice.contains(key);
    return false;
  }

  /// 记入一批（弹或不弹都记）；置位 dirty，调用方据此决定是否落盘
  bool addAll(Iterable<String> keys) {
    var changed = false;
    for (final k in keys) {
      if (k.startsWith('chat:')) {
        if (_chat.add(k)) {
          _chatOrder.add(k);
          changed = true;
          if (_chatOrder.length > kNotifiedCapPerKind) {
            final evicted = _chatOrder.removeAt(0);
            _chat.remove(evicted);
          }
        }
      } else if (k.startsWith('notice:')) {
        if (_notice.add(k)) {
          _noticeOrder.add(k);
          changed = true;
          if (_noticeOrder.length > kNotifiedCapPerKind) {
            final evicted = _noticeOrder.removeAt(0);
            _notice.remove(evicted);
          }
        }
      }
    }
    if (changed) dirty = true;
    return changed;
  }

  Future<void> save() async {
    try {
      final f = File(_path);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'chat': _chat.toList(),
        'notice': _notice.toList(),
      }));
      await tmp.rename(f.path); // 原子替换：断电不留半截文件
      dirty = false;
    } catch (_) {
      // 落盘失败不崩服务：下次同一事件会重弹一次，可接受
    }
  }
}
