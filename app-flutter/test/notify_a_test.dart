/* 「数据管理与通知渠道」章 · 段 A（2.2.5 / VC225）契约 + widget 测试。
   覆盖：10 种渠道配置表 / 12 事件（含 period）/ 提交体 / 模型解析 /
   7-C 错误通道 6 个写方法 4xx 原文 / validate_config 双呈现 / 订阅落库与
   杀进程重开 / 删除确认 / 通知中心过滤与三个动作 / 两页返回两条独立路径 /
   铃铛角标字段区分 / 凭据红线源码护栏 / 定案文档。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。 */
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart' show chatBaseProvider;
import 'package:love_space/core/chat/chat_state.dart' show chatUnreadProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/auth/auth_state.dart';
import 'package:love_space/features/chat/chat_toast.dart'
    show
        ChatToastController,
        ChatToastHost,
        ChatToastMessage,
        ChatToastTone,
        chatToastProvider;
import 'package:love_space/features/notify/channels_page.dart';
import 'package:love_space/features/notify/notices_page.dart';
import 'package:love_space/features/notify/notify_api.dart';
import 'package:love_space/features/notify/notify_models.dart';
import 'package:love_space/features/notify/system_unread_provider.dart';
import 'package:love_space/features/personal/personal_controller.dart'
    show personalCurrentUserProvider;
import 'package:shared_preferences/shared_preferences.dart';

// ── 服务端契约夹具（模拟 main.py / notifications.py 的形状）───────────

/// `notifications.py:25-28` required 键表（夹具按此判 422）。
const Map<String, List<String>> _requiredKeys = <String, List<String>>{
  'smtp': <String>['host', 'port', 'username', 'password', 'from', 'to'],
  'bark': <String>['key'],
  'serverchan': <String>['key'],
  'pushplus': <String>['token'],
  'wecom': <String>['url'],
  'webhook': <String>['url'],
  'telegram': <String>['token', 'chat_id'],
  'dingtalk': <String>['token', 'secret'],
  'feishu': <String>['token', 'secret'],
  'ntfy': <String>['host', 'topic'],
};

bool _configComplete(String kind, Map<String, dynamic> config) {
  final List<String> keys = _requiredKeys[kind] ?? const <String>[];
  return keys.every(
      (String k) => (config[k] ?? '').toString().trim().isNotEmpty);
}

class _Store {
  _Store() {
    // 服务端既有通知数据：period 提醒 / 活动通知 / 已读互动 / 聊天消息。
    notices.addAll(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'n1',
        'event': 'period',
        'title': '生理期快到了，记得照顾好自己',
        'record_id': '',
        'created': 1731667200.0,
        'seen': 0,
      },
      <String, dynamic>{
        'id': 'n2',
        'event': 'activity',
        'title': 'TA 发布了新动态',
        'record_id': 'r-activity',
        'created': 1731660000.0,
        'seen': 0,
      },
      <String, dynamic>{
        'id': 'n3',
        'event': 'comment',
        'title': 'TA 给你的留言点了赞',
        'record_id': 'r-comment',
        'created': 1731650000.0,
        'seen': 1,
      },
      <String, dynamic>{
        'id': 'n4',
        'event': 'chat',
        'title': '一条聊天消息',
        'record_id': '',
        'created': 1731640000.0,
        'seen': 0,
      },
    ]);
    deliveries.addAll(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'd1',
        'status': 'failed',
        'attempts': 3,
        'error': 'HTTP 500',
        'sent_at': null,
        'title': '恋爱空间测试通知',
        'name': '我的 Bark',
      },
      <String, dynamic>{
        'id': 'd2',
        'status': 'sent',
        'attempts': 1,
        'error': '',
        'sent_at': 1731667200.0,
        'title': '纪念日提醒',
        'name': '我的 Bark',
      },
    ]);
  }

  final List<Map<String, dynamic>> channels = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> deliveries = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> notices = <Map<String, dynamic>>[];
  final List<RequestOptions> requests = <RequestOptions>[];
  int unread = 3;
  int chatUnread = 1;
  int channelCreateStatus = 200;
  String channelCreateDetail = '请填写完整的渠道配置';
  int testChannelStatus = 200;
  String testChannelDetail = '渠道不存在';
  int writeStatus = 200;
  String writeDetail = '出了点小问题，稍后再试';
  int nextId = 0;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.store);

  final _Store store;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    store.requests.add(options);
    final String path = options.uri.path;
    final String method = options.method;

    if (method == 'GET' && path == '/api/me') {
      return _json(<String, dynamic>{
        'user': <String, dynamic>{
          'id': 'u1',
          'name': '我',
          'username': 'u1',
        },
        'users': <Object>[
          <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        ],
        'space': <String, dynamic>{
          'name': '我们的小世界',
          'since': '2020-05-20',
          'theme': 'rose',
          'custom_color': '',
          'motion': true,
          'timezone': 'Asia/Shanghai',
        },
        'unread': store.unread,
        'chat_unread': store.chatUnread,
      });
    }
    if (method == 'GET' && path == '/api/records') {
      return _json(<Object>[]);
    }
    if (method == 'GET' && path == '/api/dashboard') {
      return _json(<String, dynamic>{
        'total': 0,
        'likes': 0,
        'comments': 0,
        'photos': 0,
      });
    }
    if (method == 'GET' && path == '/api/status') {
      return _json(<String, dynamic>{'initialized': true});
    }
    if (method == 'GET' && path == '/api/channels') {
      // main.py:2524：逐行 pop('config')，绝不回传渠道配置。
      return _json(store.channels
          .map((Map<String, dynamic> c) =>
              <String, dynamic>{...c}..remove('config'))
          .toList());
    }
    if (method == 'GET' && path == '/api/deliveries') {
      return _json(<Object>[...store.deliveries]);
    }
    if (method == 'GET' && path == '/api/notices') {
      return _json(<Object>[...store.notices]);
    }

    if (method == 'POST' && path == '/api/channels') {
      final Map<String, dynamic> body =
          Map<String, dynamic>.from(options.data as Map);
      final String kind = (body['kind'] ?? '').toString();
      final Map<String, dynamic> config =
          Map<String, dynamic>.from((body['config'] ?? {}) as Map);
      // main.py:2533 kind/events 非法 422「通知类型不正确」
      if (!channelNames.containsKey(kind)) {
        return _json(<String, dynamic>{'detail': '通知类型不正确'}, 422);
      }
      // notifications.py:33 required 缺失 422「请填写完整的渠道配置」
      final bool invalid = store.channelCreateStatus >= 400 ||
          !_configComplete(kind, config);
      if (invalid) {
        return _json(
          <String, dynamic>{'detail': store.channelCreateDetail},
          store.channelCreateStatus >= 400 ? store.channelCreateStatus : 422,
        );
      }
      final String id = 'c${++store.nextId}';
      store.channels.add(<String, dynamic>{
        'id': id,
        'kind': kind,
        'name': body['name'],
        'config': config, // 服务端加密入库，但 GET 不回传
        'events': List<String>.from(body['events'] as List),
        'enabled': body['enabled'],
        'quiet_start': body['quiet_start'],
        'quiet_end': body['quiet_end'],
        'interval': body['interval'],
      });
      return _json(<String, dynamic>{'id': id});
    }
    if (method == 'DELETE' && path.startsWith('/api/channels/')) {
      if (store.writeStatus >= 400) return _writeError();
      final String cid = path.split('/').last;
      store.channels.removeWhere(
          (Map<String, dynamic> c) => c['id'].toString() == cid);
      return _json(<String, dynamic>{'ok': true});
    }
    if (method == 'POST' &&
        path.startsWith('/api/channels/') &&
        path.endsWith('/test')) {
      if (store.writeStatus >= 400) return _writeError();
      final String cid = path.split('/')[3];
      final bool exists = store.channels
          .any((Map<String, dynamic> c) => c['id'].toString() == cid);
      if (!exists || store.testChannelStatus >= 400) {
        return _json(<String, dynamic>{'detail': store.testChannelDetail},
            store.testChannelStatus >= 400 ? store.testChannelStatus : 404);
      }
      // main.py:2560-2562：插 notices(event='test') + 一条 deliveries。
      store.notices.insert(0, <String, dynamic>{
        'id': 'n-test',
        'event': 'test',
        'title': '恋爱空间测试通知',
        'record_id': '',
        'created': 1731670000.0,
        'seen': 0,
      });
      store.deliveries.insert(0, <String, dynamic>{
        'id': 'd-test',
        'status': 'pending',
        'attempts': 0,
        'error': '',
        'sent_at': null,
        'title': '恋爱空间测试通知',
        'name': '测试渠道',
      });
      return _json(<String, dynamic>{'ok': true});
    }
    if (method == 'POST' &&
        path.startsWith('/api/deliveries/') &&
        path.endsWith('/retry')) {
      if (store.writeStatus >= 400) return _writeError();
      final String did = path.split('/')[3];
      for (final Map<String, dynamic> d in store.deliveries) {
        if (d['id'].toString() == did) {
          d['status'] = 'pending';
          d['attempts'] = 0;
          d['error'] = '';
        }
      }
      return _json(<String, dynamic>{'ok': true});
    }
    if (method == 'POST' && path == '/api/notices/read') {
      if (store.writeStatus >= 400) return _writeError();
      final String? rid = options.uri.queryParameters['record_id'];
      for (final Map<String, dynamic> n in store.notices) {
        if (rid != null) {
          if (n['record_id'].toString() == rid) n['seen'] = 1;
        } else {
          n['seen'] = 1;
        }
      }
      _recalcUnread();
      return _json(<String, dynamic>{'ok': true});
    }
    if (method == 'DELETE' && path == '/api/notices/read') {
      if (store.writeStatus >= 400) return _writeError();
      final int before = store.notices.length;
      // main.py:1980：删已读且 event!='chat'。
      store.notices.removeWhere((Map<String, dynamic> n) =>
          n['seen'] == 1 && n['event'].toString() != 'chat');
      _recalcUnread();
      return _json(<String, dynamic>{
        'ok': true,
        'deleted': before - store.notices.length,
      });
    }
    return _json(<Object>[]);
  }

  void _recalcUnread() {
    store.unread = store.notices
        .where((Map<String, dynamic> n) => n['seen'] == 0)
        .length;
    store.chatUnread = store.notices
        .where((Map<String, dynamic> n) =>
            n['seen'] == 0 && n['event'].toString() == 'chat')
        .length;
  }

  ResponseBody _writeError() => _json(
        <String, dynamic>{'detail': store.writeDetail},
        store.writeStatus,
      );
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: const <String>['application/json'],
      },
    );

Dio _dio(_Store store) => Dio(
      BaseOptions(
        baseUrl: 'https://test.local',
        validateStatus: api.validateAppStatus,
      ),
    )..httpClientAdapter = _FakeAdapter(store);

/// 测试替身：保留顶部通知文本（供「双呈现」断言），但不启动 2.2s Timer，
/// 避免 flutter_test 结束时 `A Timer is still pending` 不变量失败。
class _NoTimerToastController extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

ProviderContainer _container(_Store store) {
  final Dio dio = _dio(store);
  final ProviderContainer c = ProviderContainer(
    overrides: <Override>[
      api.dioProvider.overrideWith((ref) async => dio),
      chatToastProvider.overrideWith(_NoTimerToastController.new),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      personalCurrentUserProvider.overrideWith((ref) => 'u1'),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c, {required GoRouter router}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? child) => Stack(
          children: <Widget>[
            child ?? const SizedBox.shrink(),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
            ),
          ],
        ),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1080, 3600);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(w);
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}

/// 只保留代码行（去掉 `//` / `///` 注释），用于源码级护栏断言。
String _codeOnly(String src) => src
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String _classBody(String src, String name) {
  final int start = src.indexOf('class $name ');
  expect(start, greaterThanOrEqualTo(0), reason: '$name 类存在');
  final int end = src.indexOf('\n}', start);
  return src.substring(start, end);
}

Map<String, dynamic> _channelPayload({
  String kind = 'bark',
  Map<String, dynamic>? config,
  List<String>? events,
}) =>
    <String, dynamic>{
      'kind': kind,
      'name': '我的 Bark',
      'config': config ?? <String, dynamic>{'key': 'bark-key-123'},
      'events': events ?? <String>['chat', 'period'],
      'quiet_start': 22,
      'quiet_end': 8,
      'interval': 300,
      'enabled': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  // ── 契约常量与纯函数 ────────────────────────────────────────────
  group('契约常量（app.js:1493/1494/1498/2436）', () {
    test('① 10 种渠道中文名逐字对齐 Web', () {
      expect(channelNames.length, 10);
      expect(channelNames['smtp'], '邮件');
      expect(channelNames['bark'], 'Bark');
      expect(channelNames['serverchan'], 'Server酱');
      expect(channelNames['pushplus'], 'PushPlus');
      expect(channelNames['wecom'], '企业微信机器人');
      expect(channelNames['webhook'], '自定义 Webhook');
      expect(channelNames['telegram'], 'Telegram');
      expect(channelNames['dingtalk'], '钉钉机器人');
      expect(channelNames['feishu'], '飞书机器人');
      expect(channelNames['ntfy'], 'ntfy');
    });

    test('② 12 事件含 period，中文名逐字对齐 Web', () {
      expect(eventNames.length, 12);
      expect(eventNames['chat'], '聊天消息');
      expect(eventNames['comment'], '点赞与评论');
      expect(eventNames['note'], '留言');
      expect(eventNames['activity'], '新动态与互动');
      expect(eventNames['anniversary'], '纪念日');
      expect(eventNames['period'], '生理期提醒');
      expect(eventNames['wish'], '愿望到期');
      expect(eventNames['surprise'], '惊喜公开');
      expect(eventNames['habit'], '共同打卡');
      expect(eventNames['backup'], '备份失败');
      expect(eventNames['storage'], '空间不足');
      expect(eventNames['system'], '系统消息');
    });

    test('③ 10 种 config 字段表逐项对齐，port 默认 465、两个非必填', () {
      expect(channelConfigs.length, 10);
      expect(channelConfigs['smtp']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['host', 'port', 'username', 'password', 'from', 'to']);
      expect(channelConfigs['smtp']![1].initialValue, '465');
      expect(channelConfigs['bark']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['key', 'url']);
      expect(channelConfigs['bark']!.last.required, isFalse);
      expect(channelConfigs['webhook']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['url', 'token']);
      expect(channelConfigs['webhook']!.last.required, isFalse);
      expect(channelConfigs['telegram']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['token', 'chat_id']);
      expect(channelConfigs['dingtalk']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['token', 'secret']);
      expect(channelConfigs['feishu']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['token', 'secret']);
      expect(channelConfigs['ntfy']!.map((ChannelConfigField f) => f.key).toList(),
          <String>['host', 'topic']);
      expect(channelConfigs['wecom']!.single.key, 'url');
      expect(channelConfigs['serverchan']!.single.key, 'key');
      expect(channelConfigs['pushplus']!.single.key, 'token');
      for (final MapEntry<String, List<ChannelConfigField>> e
          in channelConfigs.entries) {
        for (final ChannelConfigField f in e.value) {
          expect(f.label.isNotEmpty, isTrue, reason: '${e.key}.${f.key} 有标签');
        }
      }
    });

    test('④ 提交体逐键对齐 app.js:2437 末尾（enabled:true）', () {
      final Map<String, dynamic> p = buildChannelPayload(
        kind: 'bark',
        name: '我的 Bark',
        config: <String, String>{'key': 'abc'},
        events: <String>['period', 'chat'],
        quietStart: 22,
        quietEnd: 8,
        interval: 300,
      );
      expect(p.keys.toSet(), <String>{
        'kind',
        'name',
        'config',
        'events',
        'quiet_start',
        'quiet_end',
        'interval',
        'enabled',
      });
      expect(p['enabled'], true);
      expect(p['quiet_start'], 22);
      expect(p['quiet_end'], 8);
      expect(p['interval'], 300);
      expect(p['events'], <String>['period', 'chat']);
    });

    test('⑤ buildChannelConfig 只收非空字段（对齐 Web data["config-"+id]）', () {
      final Map<String, String> cfg = buildChannelConfig(
        'bark',
        <String, String>{'key': '  abc  ', 'url': ''},
      );
      expect(cfg, <String, String>{'key': 'abc'});
      expect(buildChannelConfig('bark', <String, String>{}), isEmpty);
    });

    test('⑥ 状态文案 / 事件中文名 / 免打扰 / 时间 / 角标', () {
      expect(deliveryStatusLabel('sent'), '已发送');
      expect(deliveryStatusLabel('pending'), '待发送');
      expect(deliveryStatusLabel('sending'), '发送中');
      expect(deliveryStatusLabel('failed'), '失败');
      expect(deliveryStatusLabel('merged'), '已合并');
      expect(deliveryStatusLabel('skipped'), '已跳过');
      expect(deliveryStatusLabel('unknown'), 'unknown');
      expect(eventsLabel(<String>['period', 'activity']),
          '生理期提醒、新动态与互动');
      expect(eventsLabel(<String>[]), '未订阅事件');
      expect(quietLabel(22, 8), '22:00–8:00 免打扰');
      expect(quietLabel(0, 0), '全天接收');
      expect(noticeTimeLabel(0), '');
      expect(unreadBadgeLabel(99), '99');
      expect(unreadBadgeLabel(100), '99+');
      expect(defaultSelectedEvents().length, 12);
    });
  });

  // ── 模型解析（内容只来自服务端）─────────────────────────────────
  group('模型解析', () {
    test('ChannelItem 解析 events（含 period），且模型无 config 字段', () {
      final ChannelItem c = ChannelItem.fromJson(<String, dynamic>{
        'id': 'c1',
        'kind': 'bark',
        'name': '我的 Bark',
        'events': <String>['period', 'activity'],
        'enabled': 1,
        'quiet_start': 22,
        'quiet_end': 8,
        'interval': 300,
      });
      expect(c.events, <String>['period', 'activity']);
      expect(c.enabled, isTrue);
      expect(c.quietStart, 22);
      final String src =
          File('lib/features/notify/notify_models.dart').readAsStringSync();
      expect(_classBody(src, 'ChannelItem').contains('config'), isFalse,
          reason: 'GET pop("config")，客户端模型不得承载凭据');
      expect(parseStringList('["chat","period"]'), <String>['chat', 'period']);
      expect(parseStringList(<String>['chat']), <String>['chat']);
    });

    test('NoticeItem / DeliveryItem 解析（period 与活动通知夹具）', () {
      final NoticeItem n = NoticeItem.fromJson(<String, dynamic>{
        'id': 'n1',
        'event': 'period',
        'title': '生理期快到了',
        'record_id': '',
        'created': 1731667200.0,
        'seen': 0,
      });
      expect(n.event, 'period');
      expect(n.seen, isFalse);
      expect(n.title, '生理期快到了');
      final DeliveryItem d = DeliveryItem.fromJson(<String, dynamic>{
        'id': 'd1',
        'status': 'failed',
        'attempts': 3,
        'error': 'HTTP 500',
        'sent_at': null,
        'title': '测试通知',
        'name': '我的 Bark',
      });
      expect(d.isFailed, isTrue);
      expect(d.attempts, 3);
      expect(d.error, 'HTTP 500');
    });
  });

  // ── 🔴 7-C 错误通道：6 个写方法 4xx 原文透传 ───────────────────
  group('7-C 错误通道（validateAppStatus 放行 4xx 也必须显式判）', () {
    test('① POST /api/channels：validate_config 422 原文', () async {
      final _Store store = _Store()..channelCreateStatus = 422;
      store.channelCreateDetail = '通知类型不正确';
      final String? err =
          await NotifyApi(_dio(store)).createChannel(_channelPayload());
      expect(err, '通知类型不正确');
    });

    test('② DELETE /api/channels/{cid}：403 原文', () async {
      final _Store store = _Store()
        ..writeStatus = 403
        ..writeDetail = '无权操作该渠道';
      expect(await NotifyApi(_dio(store)).deleteChannel('c1'), '无权操作该渠道');
    });

    test('③ POST /api/channels/{cid}/test：404「渠道不存在」原文', () async {
      final _Store store = _Store()..testChannelStatus = 404;
      expect(await NotifyApi(_dio(store)).testChannel('missing'), '渠道不存在');
    });

    test('④ POST /api/deliveries/{did}/retry：429 原文', () async {
      final _Store store = _Store()
        ..writeStatus = 429
        ..writeDetail = '操作过于频繁';
      expect(await NotifyApi(_dio(store)).retryDelivery('d1'), '操作过于频繁');
    });

    test('⑤ POST /api/notices/read：422 原文', () async {
      final _Store store = _Store()
        ..writeStatus = 422
        ..writeDetail = '参数不正确';
      expect(await NotifyApi(_dio(store)).markNoticesRead(), '参数不正确');
    });

    test('⑥ DELETE /api/notices/read：403 原文', () async {
      final _Store store = _Store()
        ..writeStatus = 403
        ..writeDetail = '需要管理员账号';
      expect(await NotifyApi(_dio(store)).deleteReadNotices(), '需要管理员账号');
    });

    test('2xx 六方法均返回 null（真成功）', () async {
      final _Store store = _Store();
      final NotifyApi svc = NotifyApi(_dio(store));
      expect(await svc.createChannel(_channelPayload()), isNull); // 落库 c1
      expect(await svc.testChannel('c1'), isNull); // c1 存在时才 200
      expect(await svc.retryDelivery('d1'), isNull);
      expect(await svc.markNoticesRead(), isNull);
      expect(await svc.deleteReadNotices(), isNull);
      expect(await svc.deleteChannel('c1'), isNull); // 删除放最后
    });

    test('5xx 抛 DioException → errorDetail 兜底，不当成成功', () async {
      final _Store store = _Store()
        ..writeStatus = 500
        ..writeDetail = '服务器内部错误';
      final String? err = await NotifyApi(_dio(store)).deleteChannel('c1');
      expect(err, isNotNull);
      expect(err, '服务器内部错误');
    });

    test('写请求参数形状：空参全部已读 / record_id 单条已读', () async {
      final _Store store = _Store();
      final NotifyApi svc = NotifyApi(_dio(store));
      await svc.markNoticesRead();
      await svc.markNoticesRead(recordId: 'r-activity');
      final List<RequestOptions> reads = store.requests
          .where((RequestOptions r) =>
              r.method == 'POST' && r.uri.path == '/api/notices/read')
          .toList();
      expect(reads.length, 2);
      expect(reads[0].uri.queryParameters.containsKey('record_id'), isFalse);
      expect(reads[1].uri.queryParameters['record_id'], 'r-activity');
    });

    test('源码：写封装不重复注入 X-Love-Space（dio 拦截器已有）', () {
      final String src =
          File('lib/features/notify/notify_api.dart').readAsStringSync();
      expect(_codeOnly(src).contains('X-Love-Space'), isFalse);
      expect(_codeOnly(src).contains('api.writeResponseError(resp)'), isTrue);
      expect(_codeOnly(src).contains('Future<String?> _write('), isTrue);
    });
  });

  // ── widget：两页返回按钮 + 系统手势两条独立路径 ─────────────────
  group('二级页返回路径（验收点 ⑤）', () {
    testWidgets('/channels 与 /notices：返回按钮 + 系统手势各一条独立路径',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/hub',
        routes: <RouteBase>[
          GoRoute(
            path: '/hub',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('page-hub'))),
          ),
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
          GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      for (final String path in <String>['/channels', '/notices']) {
        router.push(path);
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget,
            reason: '$path AppBar automaticallyImplyLeading 不关');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('page-hub'), findsOneWidget,
            reason: '$path 返回按钮回上一页');
        router.push(path);
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('page-hub'), findsOneWidget,
            reason: '$path 系统返回手势回上一页');
      }
    });

    test('main.dart 注册 /channels → ChannelsPage、/notices → NoticesPage', () {
      final String src = File('lib/main.dart').readAsStringSync();
      expect(src.contains("path: '/channels'"), isTrue);
      expect(src.contains("path: '/notices'"), isTrue);
      expect(src.contains('const ChannelsPage()'), isTrue);
      expect(src.contains('const NoticesPage()'), isTrue);
    });
  });

  // ── 铃铛角标：系统未读 vs 聊天未读严格区分 ─────────────────────
  group('AppBar 铃铛角标（验收点 ⑤）', () {
    test('角标播种：me.unread → systemUnreadProvider，chat_unread → 私聊',
        () async {
      final _Store store = _Store()
        ..unread = 7
        ..chatUnread = 2;
      final ProviderContainer c = _container(store);
      await c.read(authProvider.notifier).reload();
      expect(c.read(systemUnreadProvider), 7);
      expect(c.read(chatUnreadProvider), 2);
    });

    test('shell 源码：铃铛在私聊之前、用 systemUnread、push /notices', () {
      final String src =
          File('lib/features/shell/shell_page.dart').readAsStringSync();
      final int bell = src.indexOf("tooltip: '通知'");
      final int chat = src.indexOf("tooltip: '私聊'");
      expect(bell, greaterThanOrEqualTo(0));
      expect(chat, greaterThanOrEqualTo(0));
      expect(bell < chat, isTrue, reason: '铃铛在私聊之前');
      expect(src.contains('context.push(\'/notices\')'), isTrue);
      expect(_codeOnly(src).contains('systemUnreadProvider'), isTrue);
      expect(_codeOnly(src).contains('unreadBadgeLabel(systemUnread)'), isTrue);
      expect(src.contains('Icons.notifications_none_rounded'), isTrue);
      expect(unreadBadgeLabel(120), '99+');
    });
  });

  // ── /notices 通知中心（验收点 ③）───────────────────────────────
  group('通知中心（内容只来自服务端）', () {
    testWidgets('period 提醒与活动通知渲染；chat 被首行过滤',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/notices',
        routes: <RouteBase>[
          GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      expect(find.text('生理期快到了，记得照顾好自己'), findsOneWidget);
      expect(find.text('TA 发布了新动态'), findsOneWidget);
      expect(find.textContaining('生理期提醒 · '), findsOneWidget,
          reason: 'subtitle 里的 eventNames.period 中文名（说明卡不算）');
      expect(find.textContaining('新动态与互动'), findsOneWidget);
      expect(find.text('一条聊天消息'), findsNothing,
          reason: 'app.js:1492 首行过滤 event!="chat"');
      expect(find.text('删除已读提醒（1）'), findsOneWidget);
    });

    testWidgets('全部已读（空参）+ 删除已读确认文案 + 查看单条已读',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/notices',
        routes: <RouteBase>[
          GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));

      // 「查看」→ 弹层只呈现服务端字段 → POST ?record_id=
      await tester.tap(find.byKey(const Key('notice-detail-n2')));
      await tester.pumpAndSettle();
      expect(find.text('这一刻的故事'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      final List<RequestOptions> singleReads = store.requests
          .where((RequestOptions r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/notices/read' &&
              r.uri.queryParameters['record_id'] == 'r-activity')
          .toList();
      expect(singleReads, hasLength(1));

      // 删除已读：先取消（不删），再确认（真删）
      await tester.tap(find.byKey(const Key('notices-delete-read')));
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除 2 条已读提醒，不会影响未读提醒、动态或聊天记录。'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('notices-delete-cancel')));
      await tester.pumpAndSettle();
      expect(store.notices.length, 4, reason: '确认可取消，不删');
      await tester.tap(find.byKey(const Key('notices-delete-read')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notices-delete-confirm')));
      await tester.pumpAndSettle();
      expect(
        store.notices.any((Map<String, dynamic> n) => n['id'] == 'n3'),
        isFalse,
      );

      // 全部已读：空参数
      await tester.tap(find.byKey(const Key('notices-read-all')));
      await tester.pumpAndSettle();
      final List<RequestOptions> allReads = store.requests
          .where((RequestOptions r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/notices/read' &&
              r.uri.queryParameters.isEmpty)
          .toList();
      expect(allReads, hasLength(1));
      expect(c.read(systemUnreadProvider), 0,
          reason: '全部已读后重拉 me，角标以服务端为准');
    });

    testWidgets('全部已读 4xx：原文双呈现、不发成功通知、列表不动',
        (WidgetTester tester) async {
      final _Store store = _Store()
        ..writeStatus = 422
        ..writeDetail = '已读标记失败';
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/notices',
        routes: <RouteBase>[
          GoRoute(path: '/notices', builder: (_, _) => const NoticesPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      final int before = store.notices.length;
      await tester.tap(find.byKey(const Key('notices-read-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notify-inline-error')), findsOneWidget);
      expect(find.text('已读标记失败'), findsNWidgets(2),
          reason: '顶部通知(error) + 页面内联错误区双呈现');
      expect(store.notices.length, before, reason: '失败不本地改动列表');
      expect(find.text('已全部标记为已读'), findsNothing,
          reason: '不发成功通知');
    });
  });

  // ── /channels 渠道页（验收点 ①②④）────────────────────────────
  group('通知渠道页', () {
    testWidgets('② 新建时切换两项订阅 → 重拉 GET 落库 → 杀进程重开仍保持',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      await tester.tap(find.byKey(const Key('channels-new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('channel-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bark').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('channel-name')), '我的 Bark');
      await tester.enterText(
          find.byKey(const Key('channel-config-key')), 'bark-key-123');
      // Web 语义：订阅切换＝新建表单里取消两个 checkbox。
      await tester.tap(find.byKey(const Key('channel-event-chat')));
      await tester.tap(find.byKey(const Key('channel-event-comment')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('channel-submit')));
      await tester.pumpAndSettle();

      final RequestOptions post = store.requests.firstWhere(
          (RequestOptions r) =>
              r.method == 'POST' && r.uri.path == '/api/channels');
      final Map<String, dynamic> body =
          Map<String, dynamic>.from(post.data as Map);
      expect(body['kind'], 'bark');
      expect(body['name'], '我的 Bark');
      expect(body['enabled'], true);
      expect((body['events'] as List).contains('chat'), isFalse);
      expect((body['events'] as List).contains('comment'), isFalse);
      expect((body['events'] as List).contains('period'), isTrue,
          reason: 'period 仍在订阅里');
      expect((body['config'] as Map)['key'], 'bark-key-123');

      // POST 后重拉 GET /api/channels 确认 events 落库。
      final List<RequestOptions> gets = store.requests
          .where((RequestOptions r) =>
              r.method == 'GET' && r.uri.path == '/api/channels')
          .toList();
      expect(gets.length, greaterThanOrEqualTo(2));
      expect(store.channels.single['events'], isNot(contains('chat')));
      expect(find.textContaining('生理期提醒'), findsOneWidget);
      expect(find.textContaining('聊天消息'), findsNothing);
      expect(find.textContaining('服务端已保存配置'), findsOneWidget);
      expect(find.text('bark-key-123'), findsNothing,
          reason: 'config 不回传，列表绝不展示凭据明文');

      // 杀进程重开：全新 ProviderContainer（客户端不缓存订阅态），
      // 服务端 store 持久化不变 → 列表仍是切换后的 events。
      final ProviderContainer c2 = _container(store);
      final GoRouter router2 = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await tester.pumpWidget(_app(c2, router: router2));
      await tester.pumpAndSettle();
      expect(find.textContaining('生理期提醒'), findsOneWidget);
      expect(find.textContaining('聊天消息'), findsNothing);
    });

    testWidgets('④ 配置不全 → validate_config 原文双呈现、不假成功、输入保留',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      await tester.tap(find.byKey(const Key('channels-new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('channel-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bark').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('channel-name')), '缺 Key 的 Bark');
      // 故意不填 config-key → 服务端 validate_config 返回中文原文。
      await tester.tap(find.byKey(const Key('channel-submit')));
      await tester.pumpAndSettle();

      expect(store.channels, isEmpty, reason: '不假成功、不落库');
      expect(find.byKey(const Key('notify-inline-error')), findsOneWidget,
          reason: '表单内联错误区');
      expect(find.text('请填写完整的渠道配置'), findsNWidgets(2),
          reason: '顶部通知(error tone) + 表单内联错误区双呈现');
      expect(find.byKey(const Key('channel-name')), findsOneWidget,
          reason: '失败不 pop、输入保留');
      expect(find.text('渠道已添加，订阅已保存到服务端'), findsNothing,
          reason: '不发成功通知');
      // 失败后不自动重试、不改列表
      final int posts = store.requests
          .where((RequestOptions r) =>
              r.method == 'POST' && r.uri.path == '/api/channels')
          .length;
      expect(posts, 1);
    });

    testWidgets('① 测试 404 原文透传 + 删除确认可取消/确认后重拉消失',
        (WidgetTester tester) async {
      final _Store store = _Store();
      store.channels.add(<String, dynamic>{
        'id': 'c-existing',
        'kind': 'bark',
        'name': '已有渠道',
        'config': <String, dynamic>{'key': 'secret'},
        'events': <String>['period'],
        'enabled': true,
        'quiet_start': 22,
        'quiet_end': 8,
        'interval': 300,
      });
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      expect(find.text('已有渠道'), findsOneWidget);
      expect(find.text('secret'), findsNothing, reason: 'config 不回传');

      // 测试 404「渠道不存在」原文透传
      store.testChannelStatus = 404;
      await tester.tap(find.byKey(const Key('channel-test-c-existing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notify-inline-error')), findsOneWidget);
      expect(find.text('渠道不存在'), findsNWidgets(2));
      expect(store.channels.length, 1, reason: '失败不改列表');

      // 删除确认：取消不删；确认后重拉 GET 消失
      store.testChannelStatus = 200;
      await tester.tap(find.byKey(const Key('channel-delete-c-existing')));
      await tester.pumpAndSettle();
      expect(find.text('该渠道的配置和发送日志会一并移除。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('channel-delete-cancel')));
      await tester.pumpAndSettle();
      expect(store.channels.length, 1);
      await tester.tap(find.byKey(const Key('channel-delete-c-existing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('channel-delete-confirm')));
      await tester.pumpAndSettle();
      expect(store.channels, isEmpty);
      expect(find.text('选择你的提醒方式'), findsOneWidget,
          reason: '删掉后列表消失、重拉不复活');
    });

    testWidgets('发送记录状态文案 + 失败重试（POST retry 后重拉）',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('已发送'), findsOneWidget);
      expect(find.textContaining('尝试 3 次'), findsOneWidget);
      await tester.tap(find.byKey(const Key('delivery-retry-d1')));
      await tester.pumpAndSettle();
      final List<RequestOptions> retries = store.requests
          .where((RequestOptions r) =>
              r.method == 'POST' &&
              r.uri.path == '/api/deliveries/d1/retry')
          .toList();
      expect(retries, hasLength(1));
      expect(store.deliveries.firstWhere(
          (Map<String, dynamic> d) => d['id'] == 'd1')['status'], 'pending');
      expect(find.text('待发送'), findsOneWidget);
    });

    testWidgets('页面口径：WebPush 原生跳过 / 不做编辑 / 无假开关',
        (WidgetTester tester) async {
      final _Store store = _Store();
      final ProviderContainer c = _container(store);
      final GoRouter router = GoRouter(
        initialLocation: '/channels',
        routes: <RouteBase>[
          GoRoute(path: '/channels', builder: (_, _) => const ChannelsPage()),
        ],
      );
      await _pump(tester, _app(c, router: router));
      expect(find.textContaining('浏览器系统通知仅网页端可用'), findsOneWidget);
      expect(find.textContaining('不支持修改；需要调整请删除后重新添加'),
          findsOneWidget);
      expect(find.text('开启本设备通知'), findsNothing);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('修改'), findsNothing);
    });
  });

  // ── 源码级护栏：凭据红线 / 不自创 / 定案文档 ───────────────────
  group('源码护栏', () {
    test('凭据不落本地存储 / 不进日志 / 不入 provider', () {
      const List<String> files = <String>[
        'lib/features/notify/notify_models.dart',
        'lib/features/notify/notify_api.dart',
        'lib/features/notify/notify_widgets.dart',
        'lib/features/notify/channels_page.dart',
        'lib/features/notify/notices_page.dart',
        'lib/features/notify/system_unread_provider.dart',
      ];
      for (final String p in files) {
        final String code =
            _codeOnly(File(p).readAsStringSync()).replaceAll('debugPrint(', '');
        expect(code.contains('SharedPreferences'), isFalse, reason: p);
        expect(code.contains('FlutterSecureStorage'), isFalse, reason: p);
        expect(code.contains('storeSessionToken'), isFalse, reason: p);
        expect(code.contains('writeAsString'), isFalse, reason: p);
        expect(code.contains('print('), isFalse, reason: p);
        expect(code.contains('File('), isFalse, reason: p);
      }
    });

    test('表单提交后凭据即弃（成功分支 clear + 失败保留输入）', () {
      final String src =
          File('lib/features/notify/channels_page.dart').readAsStringSync();
      expect(src.contains('_clearCredentialControllers()'), isTrue);
      expect(src.contains('if (err == null)'), isTrue);
      expect(src.contains('c.clear()'), isTrue);
      expect(src.contains('for (final TextEditingController c in _configControllers.values)'),
          isTrue);
    });

    test('不自创：无 webpush 端点 / 无 PUT 编辑 / 无提前天数设置 / 无本地通知',
        () {
      final List<FileSystemEntity> all =
          Directory('lib').listSync(recursive: true);
      for (final FileSystemEntity f in all) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final String code = _codeOnly(f.readAsStringSync());
        expect(code.contains('/api/webpush'), isFalse, reason: f.path);
        expect(code.contains('PERIOD_REMIND_DAYS'), isFalse, reason: f.path);
      }
      final String apiSrc =
          _codeOnly(File('lib/features/notify/notify_api.dart').readAsStringSync());
      expect(apiSrc.contains('dio.put('), isFalse, reason: '无 PUT /api/channels 编辑');
    });

    test('D9：⊕ 面板旧编号占位留痕 + 与 2dcb4a4 逐字一致（护栏加强）', () async {
      final String src =
          File('lib/features/chat/chat_compose.dart').readAsStringSync();
      // ① 正向：历史占位仍在（D9 仅文档层面口径定案，不改行为）。
      expect(src.contains("case 'dashboard':"), isTrue);
      expect(src.contains("case 'weekly':"), isTrue);
      expect(src.contains("_snack('条目 9 迁移后开放')"), isTrue,
          reason: 'D9 仅文档层面口径定案；占位原样保留为历史留痕');
      expect(src.contains("context.push('/together/dashboard')"), isFalse,
          reason: '本段不改 ⊕ 面板行为（条目 6 段 G 回归面）');
      expect(src.contains("context.push('/together/weekly')"), isFalse);
      // ② 加强：与基线 2dcb4a4 的 git blob **全文逐字比对**——比原「lib 内
      // 无旧编号字面」护栏更强，实证本段对该文件零改动。
      // Windows checkout 把 LF 转 CRLF，两侧统一规范化行尾后再比；
      // stdoutEncoding:null 取 bytes 再 utf8.decode，避免系统编码把中文解乱。
      final ProcessResult r = await Process.run(
        'git',
        <String>[
          'show',
          '2dcb4a4:app-flutter/lib/features/chat/chat_compose.dart',
        ],
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      expect(r.exitCode, 0,
          reason: 'git 基线 blob 必须可读取（exit ${r.exitCode}）');
      final String baseline =
          utf8.decode(r.stdout as List<int>).replaceAll('\r\n', '\n');
      final String actual = src.replaceAll('\r\n', '\n');
      expect(actual, baseline,
          reason: 'chat_compose.dart 必须与 2dcb4a4 逐字一致（本段零改动）');
    });

    test('hub 第 8 张提醒设置卡：key / 顺序 / 跳转', () {
      final String src = File('lib/features/together/together_page.dart')
          .readAsStringSync();
      final int invite = src.indexOf("key: 'settings-hub-invite'");
      final int remind = src.indexOf("key: 'settings-hub-remind'");
      final int all = src.indexOf("key: 'settings-hub-all'");
      expect(remind, greaterThan(invite), reason: '在邀请之后');
      expect(remind, lessThan(all), reason: '在全部设置之前');
      expect(src.contains("context.push('/channels')"), isTrue);
      expect(src.contains("emoji: '🔔'"), isTrue);
      expect(src.contains("title: '提醒设置'"), isTrue);
    });

    test('版本位 2.2.5+225（VC225）', () {
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec.contains('version: 2.2.5+225'), isTrue);
      expect(pubspec.contains('2.2.4+224'), isFalse);
    });

    test('定案文档：标题 / 第四节定案标题 / 第五节分段定案 / 附录 A', () {
      final String doc =
          File('docs/data-notification-plan.md').readAsStringSync();
      expect(doc.contains('定案'), isTrue);
      expect(doc.contains('决策点定案（2026-11-15 主人拍板，不再复议）'), isTrue);
      expect(doc.contains('分段定案与版本位'), isTrue);
      expect(doc.contains('附录 A · 段 A 落地清单'), isTrue);
      expect(doc.contains('段 A 已定案/已落地 · 2.2.5 (VC225)'), isTrue);
      expect(doc.contains('终验返修包顺延'), isFalse,
          reason: 'D10 版本位落定，不再写未定表述');
    });
  });
}
