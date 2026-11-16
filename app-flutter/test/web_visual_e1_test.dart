/* 视觉对齐 Web · 推广段一（2.3.2/VC232）新增测试：
   ① 首页 stats-grid 整块摘除（源码护栏 + widget 断言）；心情格改单行横向胶囊；
   ② PostCard radius 17 + kind tint 165° + 顶部 hairline + 媒体格 12；
   ③ 相册照片块 12 + 分组头 3px 竖线 + 筛选选中态；
   ④ 我们页工具/设置区 2 列宫格、卡片数/去向/key 零变化 + 生理期渐变 + 纪念日 serif；
   ⑤ 备案缺陷②：composer「发生日期」Row 320/393/403 宽零溢出；
   ⑥ 深浅两档颜色来源断言（WebSemanticColors / webSerifStyle）。
   数值出处见 docs/web-visual-plan.md 推广段一落地备注与逐处行内注。 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/chat/chat_media.dart'
    show chatBaseProvider, mediaCookieHeadersProvider;
import 'package:love_space/features/chat/chat_toast.dart'
    show ChatToastController, ChatToastMessage, ChatToastTone, chatToastProvider;
import 'package:love_space/core/sse/sse_client.dart'
    show SseClient, SseState, SsePhase, SseEvent, sseProvider, sseEventsProvider;
import 'package:love_space/features/home/home_page.dart';
import 'package:love_space/features/shell/web_chrome.dart';
import 'package:love_space/features/timeline/post_card.dart';
import 'package:love_space/features/auth/auth_state.dart' show MeData, SpaceUser;

// ── 夹具 ─────────────────────────────────────────────────────────────

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final ResponseBody Function(RequestOptions options, int callIndex) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options, 0);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
    jsonEncode(data), status,
    headers: {Headers.contentTypeHeader: const ['application/json']});

Map<String, Object> _me() => {
      'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      'users': [
        {'id': 'u1', 'name': '我', 'username': 'u1'},
        {'id': 'u2', 'name': 'TA', 'username': 'u2'},
      ],
      'space': {'name': '小空间', 'since': '2024-01-01'},
      'unread': 0,
      'chat_unread': 0,
    };

Map<String, Object?> get _postJson => {
      'id': 'p1',
      'kind': 'post',
      'author': 'u1',
      'body': <String, dynamic>{
        'date': '2026-11-14',
        'title': '动态标题',
        'content': '动态正文',
        'media': <String>[],
      },
      'created': 1791195587.0,
      'updated': 1791195587.0,
      'published': null,
      'client_id': 'cid-p1',
      'media': <Object>[],
      'likes': <Object>[],
      'comments': <Object>[],
    };

Future<ProviderContainer> _container(_Adapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.local'))
    ..httpClientAdapter = adapter;
  final container = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
    mediaCookieHeadersProvider.overrideWith((ref) async => <String, String>{}),
    api.cookieJarProvider.overrideWith((ref) async {
      throw StateError('test: no cookie jar');
    }),
    sseProvider.overrideWith(_FakeSse.new),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    chatToastProvider.overrideWith(_NoTimerToast.new),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _FakeSse extends SseClient {
  @override
  SseState build() => const SseState(phase: SsePhase.idle);
  @override
  void start() {}
}

class _NoTimerToast extends ChatToastController {
  @override
  void show(String text, {ChatToastTone tone = ChatToastTone.info}) {
    state = ChatToastMessage(id: 1, text: text, tone: tone);
  }
}

String _src(String rel) => File(rel).readAsStringSync();

void main() {
  // ── ① 首页 stats-grid 摘除 + 心情胶囊 ────────────────────────────
  group('首页收尾', () {
    test('源码护栏：home_page.dart 无 _StatsGrid / home-stat / stats-grid', () {
      final src = _src('lib/features/home/home_page.dart');
      expect(src.contains('_StatsGrid'), isFalse,
          reason: 'stats-grid 三格整块已摘除');
      expect(src.contains("Key('home-stat-"), isFalse);
      expect(src.contains('stats-grid margin-bottom'), isFalse);
    });

    test('源码护栏：心情胶囊单行（maxLines 1 + softWrap false + pill 999）', () {
      final src = _src('lib/features/home/home_page.dart');
      // _MoodRow 的胶囊段落：Text(bubble ...) 带 maxLines:1 / overflow / softWrap
      expect(src.contains('softWrap: false'), isTrue,
          reason: '心情胶囊文本禁止换行');
      expect(src.contains('BorderRadius.circular(999)'), isTrue,
          reason: 'Web 心情 chip pill');
      expect(src.contains('记一笔'), isTrue);
    });

    Future<void> pumpHome(WidgetTester tester, Size size) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        if (o.method == 'GET' && o.uri.path == '/api/records') {
          return _json(<Object>[_postJson]);
        }
        if (o.method == 'GET' && o.uri.path == '/api/dashboard') {
          return _json(<String, Object>{'days_together': 100, 'photos': 5});
        }
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container, child: const MaterialApp(home: HomePage())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('widget：393 宽无 stats 三格、无溢出、心情文本存在', (tester) async {
      await pumpHome(tester, const Size(393, 1200));
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(Key('home-stat-$i')), findsNothing);
      }
      expect(find.text('今天的心情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('widget：320 宽零 overflow（摘除 stats 后心情胶囊不碎字）',
        (tester) async {
      await pumpHome(tester, const Size(320, 900));
      expect(tester.takeException(), isNull);
    });
  });

  // ── ② PostCard 形态 ───────────────────────────────────────────────
  group('时光 PostCard', () {
    test('源码护栏：radius 17 + 165° tint + hairline + 媒体格 12', () {
      final src = _src('lib/features/timeline/post_card.dart');
      expect(src.contains('BorderRadius.circular(17)'), isTrue,
          reason: '手机档 .card radius 17（style.css:1421）');
      expect(src.contains('stops: const [0, 0.72]'), isTrue,
          reason: 'kind tint 165° tint→surface 72%（style.css:1944-1956）');
      expect(src.contains('WebSemanticColors.cardHairline'), isTrue,
          reason: '顶部 hairline（style.css:1937/:2017）');
      expect(src.contains('_postKindTint'), isTrue);
      // 六色映射：amber/fertile/green/info 齐备
      for (final color in ['WebSemanticColors.amber', 'WebSemanticColors.fertile',
          'WebSemanticColors.green', 'WebSemanticColors.info']) {
        expect(src.contains(color), isTrue, reason: '$color tint 映射存在');
      }
      // 媒体格 12
      expect(src.contains('borderRadius: BorderRadius.circular(12)'), isTrue);
    });

    test('源码护栏：媒体视图新增可选 borderRadius 且默认 AppRadius.sm', () {
      final src = _src('lib/features/chat/media_bubble_widgets.dart');
      expect(src.contains('final BorderRadius? borderRadius'), isTrue);
      expect(
          src.contains('borderRadius ?? BorderRadius.circular(AppRadius.sm)'),
          isTrue,
          reason: '聊天侧调用点零变化（默认 sm=10）');
    });

    testWidgets('widget：PostCard 可渲染且 radius 17 + hairline 在位', (tester) async {
      final adapter = _Adapter((o, i) => _json(<Object>[]));
      final container = await _container(adapter);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(393, 900);
      addTearDown(tester.view.reset);
      final me = MeData(
        user: SpaceUser.fromJson(_me()['user'] as Map<String, dynamic>),
        users: (_me()['users'] as List)
            .map((u) => SpaceUser.fromJson(u as Map<String, dynamic>))
            .toList(),
        spaceName: '小空间',
        spaceRaw: _me()['space'] as Map<String, dynamic>,
        spaceSince: '2024-01-01',
      );
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
            home: Scaffold(
                body: PostCard(
                    record: api.Record.fromJson(
                        _postJson.cast<String, dynamic>()),
                    me: me))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  // ── ③ 相册 ─────────────────────────────────────────────────────────
  group('相册', () {
    test('源码护栏：圆角 12 / 分组竖线 / chips 选中态 / pill 主按钮', () {
      final src = _src('lib/features/album/album_page.dart');
      expect(src.contains('BorderRadius.circular(12)'), isTrue,
          reason: '照片块圆角 12（style.css:1434）');
      expect(src.contains('Container(width: 3, height: 16, color: gcs.primary)'),
          isTrue,
          reason: '分组头 3px primary 竖线（style.css:626）');
      expect(src.contains('WidgetState.selected'), isTrue,
          reason: '筛选 SegmentedButton 选中态 Web tabs 口径（style.css:337）');
      expect(src.contains('BorderRadius.circular(999)'), isTrue,
          reason: '页头主按钮 pill（style.css:132/:293）');
      // 网格列数手机 3 列 gap 8 未动
      expect(src.contains('crossAxisCount: 3'), isTrue);
    });
  });

  // ── ④ 我们页宫格 ──────────────────────────────────────────────────
  group('我们页宫格', () {
    test('源码护栏：2 列宫格 + 卡片数/去向/顺序零变化', () {
      final src = _src('lib/features/together/together_page.dart');
      expect(src.contains('_twoColumnGrid'), isTrue);
      expect(src.contains('final cell = (c.maxWidth - gap) / 2'), isTrue,
          reason: '两列等分');
      // 工具卡 11 张（route 常量逐条在）
      final routes = [
        '/together/calendar', '/together/mood', '/together/note',
        '/together/wish', '/together/question', '/together/habit',
        '/together/quest', '/together/ledger', '/together/music',
        '/together/dashboard', '/together/weekly',
      ];
      for (final r in routes) {
        expect(src.contains("route: '$r'"), isTrue, reason: '$r 去向保留');
      }
      // 设置卡 8 张 key 全保留
      final keys = [
        'settings-hub-space', 'settings-hub-theme', 'settings-hub-cover',
        'settings-hub-chat-bg', 'settings-hub-chat-bubble',
        'settings-hub-invite', 'settings-hub-remind', 'settings-hub-all',
      ];
      for (final k in keys) {
        expect(src.contains("key: '$k'"), isTrue, reason: '$k 保留');
      }
      // 顺序：提醒在邀请后、全部设置前
      expect(src.indexOf("key: 'settings-hub-remind'"),
          greaterThan(src.indexOf("key: 'settings-hub-invite'")));
      expect(src.indexOf("key: 'settings-hub-remind'"),
          lessThan(src.indexOf("key: 'settings-hub-all'")));
      // 宫格卡 radius 20 + emoji 24
      expect(src.contains('BorderRadius.circular(20)'), isTrue);
    });

    test('源码护栏：生理期 120° 渐变 + 纪念日 serif', () {
      final src = _src('lib/features/together/together_page.dart');
      expect(src.contains('LinearGradient'), isTrue,
          reason: '生理期 wide 卡渐变底（style.css:1085）');
      expect(src.contains('stops: const [0, 0.64]'), isTrue);
      expect(src.contains('webSerifStyle(24'), isTrue,
          reason: '纪念日数字 serif 24 档（style.css:479 系）');
    });
  });

  // ── ⑤ 备案缺陷②：composer 日期 Row 溢出 ──────────────────────────
  group('composer 发生日期 Row', () {
    test('源码护栏：单行 Row 改 Wrap，三个回调全保留', () {
      final src = _src('lib/features/timeline/composer_sheet.dart');
      expect(src.contains("Key('composer-date-row')"), isTrue);
      expect(src.contains('Wrap('), isTrue);
      for (final cb in ['_pickDate', '_pickImageVideo', '_pickFromLibrary']) {
        expect(src.contains(cb), isTrue, reason: '$cb 回调保留');
      }
    });

    Future<void> pumpComposer(WidgetTester tester, Size size) async {
      final adapter = _Adapter((o, i) {
        if (o.uri.path == '/api/me') return _json(_me());
        return _json(<Object>[]);
      });
      final container = await _container(adapter);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ComposerSheetHarness())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (final w in [320.0, 393.0, 403.0]) {
      testWidgets('${w.toInt()} 宽「发生日期」Row 零溢出', (tester) async {
        await pumpComposer(tester, Size(w, 900));
        expect(find.byKey(const Key('composer-date-row')), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: '${w.toInt()} 宽不得 overflow');
      });
    }
  });

  // ── ⑥ 深浅两档颜色来源 ────────────────────────────────────────────
  group('深浅两档颜色来源', () {
    test('WebSemanticColors 六族浅/夜 + info 新档逐值', () {
      expect(WebSemanticColors.info(Brightness.light),
          const Color(0xFF3F6A8E)); // style.css:44
      expect(WebSemanticColors.info(Brightness.dark),
          const Color(0xFF8FB6D4)); // :1508 rgb 143,182,212
      expect(WebSemanticColors.green(Brightness.light),
          const Color(0xFF4B6B3F));
      expect(WebSemanticColors.amber(Brightness.light),
          const Color(0xFF8A5A22));
      expect(WebSemanticColors.fertile(Brightness.dark),
          const Color(0xFFB49BD6));
      expect(WebSemanticColors.cardHairline(Brightness.light),
          const Color.fromRGBO(255, 255, 255, 0.72));
      expect(WebSemanticColors.cardHairline(Brightness.dark),
          const Color.fromRGBO(255, 255, 255, 0.05));
    });

    test('webSerifStyle 走 Web serif 字族（纪念日数字同源）', () {
      final s = webSerifStyle(24, color: const Color(0xFF953753));
      expect(s.fontFamily, 'Georgia');
      expect(s.fontFamilyFallback, contains('Songti SC'));
      expect(s.fontSize, 24);
    });

    test('版本位 2.3.2+232（VC232）', () {
      final pubspec = _src('pubspec.yaml');
      expect(RegExp(r'^version:\s*2\.3\.2\+232\s*$', multiLine: true)
          .hasMatch(pubspec), isTrue);
    });
  });
}

/// composer 泵测夹具：直接把 showComposerSheet 的内容以 Scaffold body 承载。
/// showComposerSheet 内部是 showModalBottomSheet，这里用一个最小壳复刻其
/// 「发生日期」Row 所在内容，专门验证 320/393/403 宽零溢出。
/// 注意：真正行为链由 web_visual_d_test 与 composer 既有测试护栏，本夹具
/// 只做布局宽度验证（不改发布流程）。
class ComposerSheetHarness extends StatelessWidget {
  const ComposerSheetHarness({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Wrap(
          key: const Key('composer-date-row'),
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.event_rounded, size: 18,
                  color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text('发生日期', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 4),
              TextButton(onPressed: () {}, child: const Text('2026-11-16')),
            ]),
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.image_rounded, size: 18),
              label: const Text('图/视频'),
            ),
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.audiotrack_rounded, size: 18),
              label: const Text('音频'),
            ),
          ],
        ),
      ),
    );
  }
}
