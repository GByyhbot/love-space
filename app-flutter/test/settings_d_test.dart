/* 条目 8 · 段 D · 设置缺口单测 / widget 用例。
   覆盖验收点 ②③④⑤ 与「防抹除」「8 卡无死卡（段 A 补提醒设置）」「两段返回路径」。
   跑前 unset 八个代理变量（flutter_tester 本地 WebSocket 会被代理劫持）。 */
import 'dart:async';
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
import 'package:love_space/core/config.dart';
import 'package:love_space/core/sse/sse_client.dart'
    show SseEvent, sseEventsProvider;
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/personal/personal_controller.dart';
import 'package:love_space/features/settings/settings_home_page.dart';
import 'package:love_space/features/settings/settings_state.dart';
import 'package:love_space/features/together/together_page.dart';
import 'package:love_space/main.dart' show LoveApp, routerProvider;
import 'package:shared_preferences/shared_preferences.dart';

// ── 完整 space（含服务端不回退的所有字段） ──────────────────────────
Map<String, dynamic> _fullSpace() => <String, dynamic>{
  'name': '我们的小世界',
  'since': '2020-05-20',
  'cover': 'old-cover-id',
  'cover_pos': <String, dynamic>{'x': 33, 'y': 66, 'z': 1.4},
  'theme': 'rose',
  'custom_color': '',
  'motion': true,
  'timezone': 'Asia/Shanghai',
  'chat_bg': 'sakura',
  'chat_bg_media': 'wallpaper-media-id',
  'chat_bg_dim': 42,
  'chat_bg_users': <String, dynamic>{
    'u1': <String, dynamic>{'bg': 'night', 'media': '', 'dim': 30},
  },
  'chat_bubble': 'p1/1000.png',
  'chat_bubble_fg': 'dark',
  'chat_bubble_swap': true,
};

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.store);

  final _Store store;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (options.method == 'GET' && path == '/api/me') {
      return _json(<String, dynamic>{
        'user': <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        'users': <Object>[
          <String, dynamic>{'id': 'u1', 'name': '我', 'username': 'u1'},
        ],
        'space': store.space,
        'unread': 0,
        'chat_unread': 0,
      });
    }
    if (options.method == 'GET' && path == '/api/records') {
      return _json(<Object>[]);
    }
    if (options.method == 'GET' && path == '/api/dashboard') {
      return _json(<String, dynamic>{
        'total': 0,
        'likes': 0,
        'comments': 0,
        'photos': 0,
      });
    }
    if (options.method == 'GET' && path == '/api/routes') {
      return _json(<String, dynamic>{'routes': store.routes});
    }
    if (options.method == 'GET' && path == '/api/status') {
      return _json(<String, dynamic>{
        'initialized': true,
        'paired': false,
        'version': '2.2.4',
        'build': 'vc224',
        'apk_version': store.apkVersion,
        'apk_url': '/apk/download',
        'apk_mirror': store.apkMirror,
        'apk_has_local': true,
        'apk_notes': '段 C 数据分析 + 段 D 设置缺口',
      });
    }
    if (options.method == 'PUT' && path == '/api/space') {
      final body = Map<String, dynamic>.from(options.data as Map);
      store.putBodies.add(body);
      if (store.spaceStatus >= 400) {
        return _json(<String, dynamic>{
          'detail': store.spaceDetail,
        }, store.spaceStatus);
      }
      // 模拟 main.py:849 `data = body.model_dump()`：全量覆盖，无 None 回退。
      store.space = body;
      return _json(<String, dynamic>{'ok': true});
    }
    if (options.method == 'POST' && path == '/api/media') {
      return _json(<String, dynamic>{'id': 'new-cover-media'});
    }
    return _json(<Object>[]);
  }
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: const <String>['application/json'],
  },
);

class _Store {
  Map<String, dynamic> space = _fullSpace();
  List<Object> routes = <Object>[]; // 本地测试环境主人实测为空
  String apkVersion = '2.2.3';
  String apkMirror = '';
  int spaceStatus = 200;
  String spaceDetail = '自定义颜色要是 #RRGGBB';
  final List<Map<String, dynamic>> putBodies = <Map<String, dynamic>>[];
}

Future<Dio> _dio(_Store store) async => Dio(
  BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ),
)..httpClientAdapter = _FakeAdapter(store);

Future<ProviderContainer> _container(
  _Store store, {
  List<Override> extra = const <Override>[],
}) async {
  final dio = await _dio(store);
  final c = ProviderContainer(
    overrides: [
      api.dioProvider.overrideWith((ref) async => dio),
      api.baseProvider.overrideWith((ref) async => 'https://test.local'),
      chatBaseProvider.overrideWith((ref) async => 'https://test.local'),
      sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
      personalCurrentUserProvider.overrideWith((ref) => 'u1'),
      ...extra,
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
        builder: (context, child) => Stack(
          children: [
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
  tester.view.physicalSize = const Size(1080, 3200);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(w);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  // ── 🔴 防抹除：全量 merge，逐字段比对 PUT 前后 ─────────────────────
  group('防抹除（main.py:849 model_dump，name/since/cover/theme 不回退）', () {
    test('换主题：PUT 是完整 space，聊天背景/气泡/空间名/相恋日期纹丝不动', () async {
      final store = _Store();
      final dio = await _dio(store);
      final before = _fullSpace();
      final (merged, err) = await saveSpaceChanges(
        dio,
        themeSpaceChanges(theme: 'mint', customColor: '', motion: false),
        knownSpace: before,
      );
      expect(err, isNull);
      expect(merged, isNotNull);
      final body = store.putBodies.single;
      // 绝不能只发 {theme:...}
      expect(
        body.keys.toSet(),
        before.keys.toSet(),
        reason: 'PUT 必须是完整 space（键集合全等）',
      );
      final diff = spaceFieldDiff(before, body, <String>{
        'theme',
        'custom_color',
        'motion',
      });
      expect(diff, isEmpty, reason: '非改动字段逐字段全等：$diff');
      expect(body['name'], '我们的小世界');
      expect(body['since'], '2020-05-20');
      expect(body['chat_bg'], 'sakura');
      expect(body['chat_bg_media'], 'wallpaper-media-id');
      expect(body['chat_bg_dim'], 42);
      expect(body['chat_bubble'], 'p1/1000.png');
      expect(body['chat_bubble_fg'], 'dark');
      expect(body['chat_bubble_swap'], true);
      expect(body['cover'], 'old-cover-id');
      expect(body['cover_pos'], before['cover_pos']);
      expect(body['timezone'], 'Asia/Shanghai');
      expect(body['theme'], 'mint');
      expect(body['motion'], false);
      expect(
        body.containsKey('dark'),
        isFalse,
        reason: 'dark 只写本机，绝不进 PUT body',
      );
      expect(body.containsKey('font'), isFalse);
      // 服务端保存后逐字段比对
      expect(
        spaceFieldDiff(before, store.space, <String>{
          'theme',
          'custom_color',
          'motion',
        }),
        isEmpty,
      );
    });

    test('换主页背景：PUT 是完整 space，聊天背景/气泡/空间名/相恋日期纹丝不动', () async {
      final store = _Store();
      final dio = await _dio(store);
      final before = _fullSpace();
      final (merged, err) = await saveSpaceChanges(
        dio,
        coverSpaceChanges(cover: 'new-cover-media'),
        knownSpace: before,
      );
      expect(err, isNull);
      expect(merged, isNotNull);
      final body = store.putBodies.single;
      expect(body.keys.toSet(), before.keys.toSet());
      final diff = spaceFieldDiff(before, body, <String>{'cover', 'cover_pos'});
      expect(diff, isEmpty, reason: '非改动字段逐字段全等：$diff');
      expect(body['chat_bg'], 'sakura');
      expect(body['chat_bubble'], 'p1/1000.png');
      expect(body['name'], '我们的小世界');
      expect(body['since'], '2020-05-20');
      expect(body['theme'], 'rose');
      expect(body['cover'], 'new-cover-media');
      expect(body['cover_pos'], <String, dynamic>{'x': 50, 'y': 50, 'z': 1});
    });

    test('不带 knownSpace 时先 GET /api/me 拿完整底再 merge（不抹除）', () async {
      final store = _Store();
      final dio = await _dio(store);
      final before = _fullSpace();
      await saveSpaceChanges(
        dio,
        themeSpaceChanges(theme: 'sky', customColor: '', motion: true),
      );
      final body = store.putBodies.single;
      expect(body['name'], before['name']);
      expect(body['since'], before['since']);
      expect(body['chat_bubble'], before['chat_bubble']);
      expect(body['theme'], 'sky');
    });

    test('4xx 显式判：服务端 detail 原文、失败不写成功态、不重试', () async {
      final store = _Store();
      store.spaceStatus = 422;
      final dio = await _dio(store);
      final (merged, err) = await saveSpaceChanges(
        dio,
        themeSpaceChanges(theme: 'custom', customColor: 'bad', motion: true),
        knownSpace: _fullSpace(),
      );
      expect(err, store.spaceDetail, reason: 'detail 原文透传');
      expect(merged, isNull);
      expect(store.putBodies.length, 1, reason: '不自动重试');
      expect(store.space, _fullSpace(), reason: '失败不误写');
    });

    test('源码级护栏：settings_state.dart 是唯一 merge 入口且注释写明防抹除', () {
      final src = File('lib/features/settings/settings_state.dart')
          .readAsStringSync();
      expect(src.contains('model_dump()'), isTrue);
      expect(src.contains('{...spaceRaw, ...changes}'), isTrue);
      // 2.4.0 设置拆分段：节代码搬入独立页，逐页校验同一契约——
      // 保存链走 saveSpaceChanges/xxxSpaceChanges，绝不自己发 PUT。
      final appearance = File('lib/features/settings/appearance_page.dart')
          .readAsStringSync();
      expect(appearance.contains('saveSpaceChanges('), isTrue);
      expect(appearance.contains('themeSpaceChanges('), isTrue);
      final cover =
          File('lib/features/settings/cover_page.dart').readAsStringSync();
      expect(cover.contains('saveSpaceChanges('), isTrue);
      expect(cover.contains('coverSpaceChanges('), isTrue);
      for (final page in [appearance, cover]) {
        // 页面绝不自己构造部分体：改动的字段一律经 xxxSpaceChanges() 生成，
        // 且页面不直接发 PUT /api/space（防抹除唯一入口在 settings_state.dart）。
        expect(
          page.contains("dio.put('/api/space'"),
          isFalse,
          reason: '页面不得自己发部分体 PUT',
        );
        expect(
          page.contains("'custom_color':"),
          isFalse,
          reason: '页面不得自己构造含 custom_color 的部分体',
        );
      }
    });
  });

  // ── 主题 / 本机偏好 ──────────────────────────────────────────────
  group('主题与外观（themeForm :1870-1942）', () {
    test('7 套 + custom 与后端 SPACE_THEMES 同名单；custom 需 #RRGGBB', () {
      expect(themeIds.length, 8);
      expect(themeIds.sublist(0, 7).toSet(), <String>{
        'rose',
        'peach',
        'lemon',
        'mint',
        'sky',
        'lavender',
        'cocoa',
      });
      expect(serverThemeIds.difference(themeIds.toSet()), isEmpty);
      expect(isValidCustomColor('#9A6B5A'), isTrue);
      expect(isValidCustomColor('#9a6b5a'), isTrue);
      expect(isValidCustomColor('9A6B5A'), isFalse);
      expect(isValidCustomColor('#FFF'), isFalse);
      expect(normalizedTheme('unknown'), 'rose');
    });

    test('ThemeData seed / 夜间叠加 / 字号乘数逐项', () {
      expect(themeSeedColor('rose', ''), const Color(0xFF953753));
      expect(themeSeedColor('rose', '', dark: true), const Color(0xFFDA8BA3));
      expect(themeSeedColor('mint', ''), const Color(0xFF3A826D));
      expect(themeSeedColor('custom', '#123456'), const Color(0xFF123456));
      expect(themeSeedColor('custom', 'bad'), const Color(0xFF9A6B5A));
      expect(themeModeOf('auto'), ThemeMode.system);
      expect(themeModeOf('on'), ThemeMode.dark);
      expect(themeModeOf('off'), ThemeMode.light);
      expect(fontScaleOf('std'), 1.0);
      expect(fontScaleOf('large'), 1.08);
      expect(fontScaleOf('xl'), 1.16);
    });

    test('dark / font 只写本机，重启保留；cancel 还原', () async {
      await writeLocalPrefs(dark: 'on', font: 'xl');
      var p = await readLocalPrefs();
      expect(p.dark, 'on');
      expect(p.font, 'xl');
      // 模拟重启：新建容器重新读
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(darkPrefKey), 'on');
      expect(prefs.getString(fontPrefKey), 'xl');
      await writeLocalPrefs(dark: 'auto', font: 'std');
      p = await readLocalPrefs();
      expect(p.dark, 'auto');
      expect(p.font, 'std');
      // dark/font 绝不出现在 PUT body
      final changes = themeSpaceChanges(
        theme: 'sky',
        customColor: '',
        motion: true,
      );
      expect(changes.containsKey('dark'), isFalse);
      expect(changes.containsKey('font'), isFalse);
      expect(changes.keys.toSet(), <String>{'theme', 'custom_color', 'motion'});
    });

    test('就地预览 + 取消还原（Riverpod 驱动，不落服务端）', () async {
      final store = _Store();
      final c = await _container(store);
      final n = c.read(spaceAppearanceProvider.notifier);
      n.seed(_fullSpace());
      expect(c.read(spaceAppearanceProvider).effectiveTheme, 'rose');
      n.preview(theme: 'lavender', customColor: '', motion: false);
      final v = c.read(spaceAppearanceProvider);
      expect(v.effectiveTheme, 'lavender');
      expect(v.effectiveMotion, isFalse);
      expect(v.theme, 'rose', reason: '预览不覆盖空间实际值');
      n.cancel();
      expect(c.read(spaceAppearanceProvider).effectiveTheme, 'rose');
      expect(c.read(spaceAppearanceProvider).effectiveMotion, isTrue);
      expect(store.putBodies, isEmpty, reason: '预览/取消不发写请求');
    });
  });

  // ── 链路检测 ─────────────────────────────────────────────────────
  group('链路检测与手动切线路（linkCheckPage / runLinkProbe / useLinkRoute）', () {
    test('/api/routes 空列表兜底 AppConfig.effectiveRoutes（本地实测为空）', () {
      final empty = routesFromResponse(<String, dynamic>{'routes': <Object>[]});
      expect(empty.length, AppConfig.effectiveRoutes.length);
      expect(empty.map((r) => r.url).toList(), AppConfig.effectiveRoutes);
      final bad = routesFromResponse(const <String, dynamic>{});
      expect(bad.length, AppConfig.effectiveRoutes.length);
      final good = routesFromResponse(<String, dynamic>{
        'routes': <Object>[
          <String, dynamic>{
            'name': '节点小宝',
            'url': 'https://love-space.iepose.cn/',
          },
        ],
      });
      expect(good.length, 1);
      expect(good.single.name, '节点小宝');
    });

    test('逐条真实延迟（GET /api/status 计时、纯 ASCII UA、最快标记）', () async {
      final calls = <String>[];
      final rows = await probeRoutes(
        <LinkRoute>[
          const LinkRoute(name: 'A', url: 'https://a.test/'),
          const LinkRoute(name: 'B', url: 'https://b.test/'),
          const LinkRoute(name: 'C', url: 'https://c.test/'),
        ],
        currentBase: 'https://a.test',
        probeOne: (url, ua) async {
          calls.add('$url|$ua');
          if (url.contains('c.test')) throw Exception('unreachable');
          return Response<dynamic>(
            requestOptions: RequestOptions(path: url),
            statusCode: 200,
          );
        },
      );
      expect(rows.length, 3);
      expect(rows[0].current, isTrue);
      expect(rows[1].current, isFalse);
      expect(rows[2].ms, -1, reason: '不可达 = -1');
      expect(rows[0].ms, greaterThanOrEqualTo(0));
      for (final call in calls) {
        expect(call, contains('/api/status?_p='));
        final ua = call.split('|')[1];
        expect(
          ua.codeUnits.every((c) => c >= 0 && c < 128),
          isTrue,
          reason: 'UA 必须纯 ASCII，实际=$ua',
        );
      }
      expect(linkProbeUserAgent, contains('LoveSpaceApp/'));
      final best = fastestRoute(rows);
      expect(best, isNotNull);
      expect(best!.ms, greaterThanOrEqualTo(0));
    });

    test('手动切换落 last_route；冷启动 baseProvider 快路径优先读它', () async {
      const target = 'https://love-space.iepose.cn/';
      var invalidated = false;
      await useLinkRoute(target, invalidateBase: () => invalidated = true);
      expect(invalidated, isTrue, reason: 'ref.invalidate(baseProvider)');
      expect(await api.readLastRoute(), target);
      // 源码级：baseProvider 快路径读 readLastRoute 优先验活
      final src = File('lib/core/api/api_client.dart').readAsStringSync();
      expect(
        src.indexOf('await readLastRoute()'),
        lessThan(src.indexOf('Future.wait(routes.map(_reachable))')),
      );
      expect(src.contains('routes.contains(last)'), isTrue);
      // 会话跨线已由 seedSessionToAllRoutes / ensureSessionCookie 兜底
      expect(src.contains('seedSessionToAllRoutes'), isTrue);
      expect(src.contains('ensureSessionCookie'), isTrue);
    });
  });

  // ── 检查更新 ─────────────────────────────────────────────────────
  group('检查更新 / 复制下载链接（app.js:2843 / :2569）', () {
    test('newerVer 语义化比较逐项（Web 实跑口径）', () {
      expect(newerVer('2.2.4', '2.2.3'), isTrue);
      expect(newerVer('2.2.4', '2.2.4'), isFalse);
      expect(newerVer('2.2.3', '2.2.4'), isFalse);
      expect(newerVer('2.3.0', '2.2.9'), isTrue);
      expect(newerVer('3.0.0', '2.9.9'), isTrue);
      expect(newerVer('1.2.10', '1.2.9'), isTrue);
      expect(newerVer('1.2', '1.2.0'), isFalse);
    });

    test('apkMirror || /apk/download 拼当前 base；有新版才提示', () {
      final s1 = ApkStatus.fromJson(<String, dynamic>{
        'apk_version': '2.2.4',
        'apk_url': '/apk/download',
        'apk_mirror': '',
      });
      expect(
        apkDownloadLink(s1, 'https://love-space.iepose.cn/'),
        'https://love-space.iepose.cn/apk/download',
      );
      final s2 = ApkStatus.fromJson(<String, dynamic>{
        'apk_version': '2.2.4',
        'apk_mirror': '/static/lovespace.apk?v=2.2.4',
      });
      expect(
        apkDownloadLink(s2, 'https://x.test'),
        'https://x.test/static/lovespace.apk?v=2.2.4',
      );
      final s3 = ApkStatus.fromJson(<String, dynamic>{
        'apk_version': '2.2.4',
        'apk_mirror': 'https://cdn.test/app.apk',
      });
      expect(apkDownloadLink(s3, 'https://x.test'), 'https://cdn.test/app.apk');
      expect(s3.apkVersion, '2.2.4');
      expect(s3.apkHasLocal, isFalse);
      expect(newerVer(s3.apkVersion, '2.2.4'), isFalse, reason: '同版本不提示可更新');
    });
  });

  // ── 页面：ThemeData 真生效 / 8 卡 / 返回路径 ──────────────────────
  group('页面与路由（验收点 ②④⑤）', () {
    testWidgets('换主题色 App 立刻变（ThemeData 真的吃到 space.theme）', (tester) async {
      final store = _Store();
      // 覆盖 routerProvider 为单路由：避免 LoveApp 的真实多页 Shell 带来的
      // 多 FAB Hero tag 冲突，同时让 find.byType(Scaffold).first 稳定指向探针页。
      final probeRouter = GoRouter(
        initialLocation: '/probe',
        routes: <RouteBase>[
          GoRoute(
            path: '/probe',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('theme-probe'))),
          ),
        ],
      );
      final c = await _container(
        store,
        extra: <Override>[routerProvider.overrideWithValue(probeRouter)],
      );
      await _pump(
        tester,
        UncontrolledProviderScope(container: c, child: const LoveApp()),
      );
      final roseCtx = tester.element(find.byType(Scaffold).first);
      final rose = Theme.of(roseCtx).colorScheme.primary;

      // 空间设置变更 → commit → MaterialApp 立刻重建
      final changed = <String, dynamic>{..._fullSpace(), 'theme': 'mint'};
      c.read(spaceAppearanceProvider.notifier).commit(changed);
      await tester.pumpAndSettle();
      final mintCtx = tester.element(find.byType(Scaffold).first);
      final mint = Theme.of(mintCtx).colorScheme.primary;
      expect(mint, isNot(rose), reason: '主题色必须真的生效，不许只存不用');
      expect(
        mint,
        ColorScheme.fromSeed(seedColor: themeSeedColor('mint', '')).primary,
      );
      // 夜间模式与主题色叠加：darkTheme 用 dark swatch。
      // themeMode 切换由 AnimatedTheme 过渡，需要 pumpAndSettle 走完动画后
      // Theme.of 才会返回 darkTheme（单帧 pump 仍停在 light）。
      await c
          .read(appearancePrefsProvider.notifier)
          .save(dark: 'on', font: 'std');
      await tester.pumpAndSettle();
      final darkCtx = tester.element(find.byType(Scaffold).first);
      expect(Theme.of(darkCtx).brightness, Brightness.dark);
      expect(c.read(appThemeModeProvider), ThemeMode.dark);
      // 源码级：main.dart 用 themeSeedColor 生成 light/dark ThemeData
      final mainSrc = File('lib/main.dart').readAsStringSync();
      expect(mainSrc.contains('themeSeedColor('), isTrue);
      expect(mainSrc.contains('ColorScheme.fromSeed('), isTrue);
    });

    testWidgets('2.4.0：「我们」页设置区已退役——8 张设置卡零残留、工具区不受影响',
        (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = GoRouter(
        initialLocation: '/hub',
        routes: <RouteBase>[
          GoRoute(
            path: '/hub',
            builder: (_, _) => const TogetherPage(active: true),
          ),
          GoRoute(
            path: '/home',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('page-home'))),
          ),
        ],
      );
      await _pump(tester, _app(c, router: router));

      // 设置区整体离开「我们」页：标题与 8 张卡全部消失。
      expect(find.text('⚙️'), findsNothing,
          reason: '🔴 「⚙️ 设置」标题退役（设置入口改顶栏齿轮）');
      for (final t in <String>[
        '空间信息',
        '主题与外观',
        '主页背景',
        '聊天背景',
        '聊天气泡',
        '邀请另一半入住',
        '提醒设置',
        '全部设置',
      ]) {
        expect(find.text(t), findsNothing, reason: '$t 设置卡已随区退役');
      }
      for (final key in <String>[
        'settings-hub-space',
        'settings-hub-theme',
        'settings-hub-cover',
        'settings-hub-chat-bg',
        'settings-hub-chat-bubble',
        'settings-hub-invite',
        'settings-hub-remind',
        'settings-hub-all',
      ]) {
        expect(find.byKey(Key(key)), findsNothing, reason: '$key 卡不再存在');
      }
      // 空间信息原经由设置卡跳首页触发编辑——设置区退役后标志不得被误置位。
      expect(c.read(spaceEditRequestedProvider), isFalse);
      // 工具区不受瘦身影响：工具卡文案仍在位（宽卡 emoji 与标题分开渲染）。
      expect(find.text('🌸'), findsOneWidget, reason: '生理期宽卡 emoji 在位');
      expect(find.text('生理期'), findsOneWidget,
          reason: '生理期宽卡标题在位（瘦身不得误伤工具区）');
    });

    testWidgets('设置主页：分组索引九行落点逐行正确 + 返回可回', (tester) async {
      final store = _Store();
      final c = await _container(store);
      final router = GoRouter(
        initialLocation: '/hub',
        routes: <RouteBase>[
          GoRoute(
            path: '/hub',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('page-hub'))),
          ),
          GoRoute(
              path: '/settings', builder: (_, _) => const SettingsHomePage()),
          // 各落点占位页：验证行点击真实到达、无死行。
          for (final (path, marker) in const <(String, String)>[
            ('/settings/theme', 'page-theme'),
            ('/settings/cover', 'page-cover'),
            ('/settings/chat-wallpaper', 'page-chat-wallpaper'),
            ('/settings/chat-bubble', 'page-chat-bubble'),
            ('/channels', 'page-channels'),
            ('/settings/links', 'page-links'),
            ('/settings/export', 'page-export'),
            ('/backups', 'page-backups'),
            ('/settings/invite', 'page-invite'),
            ('/home', 'page-home'),
          ])
            GoRoute(
              path: path,
              builder: (_, _) => Scaffold(
                  body: Center(child: Text(marker, key: Key(marker))),
              ),
            ),
        ],
      );
      await _pump(tester, _app(c, router: router));
      router.push('/settings');
      await tester.pumpAndSettle();
      expect(find.text('管理空间、账号和数据。'), findsOneWidget,
          reason: '设置主页页头副题（沿用原全量页逐字）');

      // 九行逐行点通（「空间信息」行是弹窗意图置位，单独断言）。
      final routes = <(Key, String)>[
        (const Key('settings-home-theme'), 'page-theme'),
        (const Key('settings-home-cover'), 'page-cover'),
        (const Key('settings-home-chat-bg'), 'page-chat-wallpaper'),
        (const Key('settings-home-chat-bubble'), 'page-chat-bubble'),
        (const Key('settings-home-remind'), 'page-channels'),
        (const Key('settings-home-links'), 'page-links'),
        (const Key('settings-home-export'), 'page-export'),
        (const Key('settings-home-backups'), 'page-backups'),
        (const Key('settings-home-invite'), 'page-invite'),
      ];
      for (final (key, marker) in routes) {
        router.go('/settings');
        await tester.pumpAndSettle();
        final finder = find.byKey(key);
        expect(finder, findsOneWidget, reason: '$key 行存在');
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(find.byKey(Key(marker)), findsOneWidget,
            reason: '$key 点击必须真到达落点（无死行）');
      }
      // 空间信息行：置位弹窗意图标志（真实首页消费）。
      router.go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-home-space')));
      await tester.pumpAndSettle();
      expect(c.read(spaceEditRequestedProvider), isTrue,
          reason: '空间信息行置位编辑意图（沿用原机制）');
      // 返回按钮可回原页：先 go('/hub') 清掉逐行循环残留的 push 栈，
      // 再 push('/settings')（/hub 保留在栈底 → AppBar 出自动返回钮）。
      router.go('/hub');
      await tester.pumpAndSettle();
      router.push('/settings');
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('page-hub'), findsOneWidget);
    });
  });
}
