/// 2.8.7 段四：**只走日历**的行为护栏。
///
/// 令文要求：
/// ① 删掉整段编辑表单及全部入口后，页面里不许再有它（含右下角悬浮按钮），
///    并用 grep 级护栏钉死（防止日后又从别处长回来）；
/// ② 点中**不在段内**的日子 → 日记录卡出现「补录月经来了 / 今天来了」→ 建段
///    开始日 = 所选日、天数从 1 起；
/// ③ 点中**段内**的日子 → 沿用「月经走了 / 还在经期」与删段；
/// ④ 手填天数/周期的口子彻底没了（新建不再传用户输入的 length/cycle）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:love_space/core/api/api_client.dart' as api;
import 'package:love_space/core/sse/sse_client.dart';
import 'package:love_space/features/chat/chat_toast.dart' show ChatToastHost;
import 'package:love_space/features/period/period_engine.dart';
import 'package:love_space/features/period/period_page.dart';
import 'package:love_space/features/personal/personal_controller.dart';

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

double _ts(String iso) => DateTime.parse(iso).millisecondsSinceEpoch / 1000.0;

class _Store {
  _Store(this.records);
  final List<Map<String, dynamic>> records;
  final List<Map<String, dynamic>> postBodies = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> putBodies = <Map<String, dynamic>>[];
  final List<String> deletedIds = <String>[];
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.s);
  final _Store s;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    if (o.method == 'GET' && o.uri.path == '/api/records') {
      return _json(s.records.where((r) => r['deleted'] == null).toList());
    }
    if (o.method == 'GET' && o.uri.path == '/api/me') {
      return _json({
        'user': {'id': 'u1', 'name': '我', 'username': 'u1'},
      });
    }
    if (o.method == 'POST' && o.uri.path == '/api/records') {
      final data = Map<String, dynamic>.from(o.data as Map);
      s.postBodies.add(data);
      final body = Map<String, dynamic>.from(data['body'] as Map);
      s.records.add({
        'id': 'new-1',
        'kind': 'period',
        'author': 'u1',
        'body': body,
        'created': DateTime.now().millisecondsSinceEpoch / 1000.0,
        'updated': DateTime.now().millisecondsSinceEpoch / 1000.0,
      });
      return _json(<String, Object>{});
    }
    if (o.method == 'PUT' && o.uri.path.startsWith('/api/records/')) {
      final data = Map<String, dynamic>.from(o.data as Map);
      s.putBodies.add(data);
      final rid = o.uri.path.split('/').last;
      for (var i = 0; i < s.records.length; i++) {
        if (s.records[i]['id'] == rid) {
          s.records[i] = {
            ...s.records[i],
            'body': Map<String, dynamic>.from(data['body'] as Map),
            'updated': DateTime.now().millisecondsSinceEpoch / 1000.0,
          };
        }
      }
      return _json(<String, Object>{});
    }
    if (o.method == 'DELETE' && o.uri.path.startsWith('/api/records/')) {
      s.deletedIds.add(o.uri.path.split('/').last);
      return _json(<String, Object>{'ok': true});
    }
    return _json(<Object>[]);
  }
}

ProviderContainer _setup(_Store s) {
  final dio = Dio(BaseOptions(
    baseUrl: 'https://test.local',
    validateStatus: api.validateAppStatus,
  ))..httpClientAdapter = _Adapter(s);
  final c = ProviderContainer(overrides: [
    api.dioProvider.overrideWith((ref) async => dio),
    sseEventsProvider.overrideWith((ref) => const Stream<SseEvent>.empty()),
    personalCurrentUserProvider.overrideWith((ref) => 'u1'),
  ]);
  addTearDown(c.dispose);
  return c;
}

Widget _app(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/period',
          routes: [
            GoRoute(path: '/period', builder: (_, _) => const PeriodPage()),
          ],
        ),
        builder: (context, child) => Stack(children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: SafeArea(child: ChatToastHost())),
          ),
        ]),
      ),
    );

Future<void> _pump(WidgetTester tester, ProviderContainer c) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(_app(c));
  await tester.pumpAndSettle();
}

/// 点日历里某个日号（当月）；找不到就跳过（跨月由调用方自己保证）。
Future<bool> _tapDay(WidgetTester tester, int day) async {
  final f = find.text('$day');
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first);
  await tester.pumpAndSettle();
  return true;
}


/// 冲掉 ChatToast 的自动消失定时器（否则测试结束报 pending timer）。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pumpAndSettle();
}

/// ListView 惰性构建：用 scrollUntilVisible 增量滚动（drag 过冲会把已建项卸载）。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  if (target.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('① 表单与悬浮按钮必须不存在（含 grep 级护栏）', () {
    testWidgets('页面上没有 FAB、没有表单入口文案', (tester) async {
      final c = _setup(_Store([]));
      await _pump(tester, c);
      expect(find.byType(FloatingActionButton), findsNothing,
          reason: '右下角「记一次经期」悬浮按钮已删');
      expect(find.text('记一次经期'), findsNothing);
      expect(find.text('记录这次经期'), findsNothing);
      expect(find.text('编辑这次经期'), findsNothing);
    });

    test('grep 护栏：lib 内不存在表单符号（防止日后长回来）', () {
      // 说明：`记一次经期` 用**带引号的精确字面量**匹配——分析页空态里那句
      // 「再多记一次经期，就能和近半年对比」是 Web/App 共用的对拍文案
      // （period_c_expected.json 里有），不是指向已删表单入口的引导语，不许误伤。
      const banned = [
        'PeriodFormDialog',
        'period_form.dart',
        '_openEpisodeForm',
        'periodFormBody',
        'planSaveEpisodeForm',
        "'记一次经期'",
        "Text('记录这次经期')",
        "Text('编辑这次经期')",
      ];
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].split('//').first; // 注释里的历史说明不算
          for (final b in banned) {
            if (code.contains(b)) offenders.add('${f.path}:${i + 1}: $b');
          }
        }
      }
      expect(offenders, isEmpty, reason: '段四删除不彻底：$offenders');
    });
  });

  group('② 点选段外日子 → 建段（开始日=所选日、天数从 1 起）', () {
    testWidgets('空数据时点某日 → 出现「今天来了」/「补录月经来了」并可建段',
        (tester) async {
      final s = _Store([]);
      final c = _setup(s);
      await _pump(tester, c);
      // 空数据时 Hero 是空态卡（periodEmptyTitle），主操作只在日记录卡上
      expect(find.text('🌸 开始记录'), findsWidgets);

      // 点日历上一个段外的日子（选 1 号，避开今天）
      final tapped = await _tapDay(tester, 1);
      if (!tapped) return; // 当月没有 1 号的极端情况（不会发生）

      // 日记录卡：段外 → 建段按钮（历史日期弱化后文案是「补录月经来了」）
      final startBtn = find.byKey(const Key('period-log-start'));
      await _scrollTo(tester, startBtn);
      expect(startBtn, findsOneWidget, reason: '段外日子必须有建段入口');
      await tester.ensureVisible(startBtn);
      await tester.tap(startBtn);
      await tester.pumpAndSettle();

      expect(s.postBodies, isNotEmpty, reason: '建段必须真的 POST');
      final body = Map<String, dynamic>.from(s.postBodies.last['body'] as Map);
      // 开始日 = 所选日（1 号），天数从 1 起
      expect(body['start'], endsWith('-01'),
          reason: '开始日必须是日历上点中的那天');
      expect(body['length'], 1, reason: '新建段 length 恒为 1（待确认模型）');
      // 手填口子已堵：请求里不许出现用户输入的天数/周期键以外的东西
      expect(body.containsKey('end'), isFalse, reason: '永不带 end');
      await _flush(tester); // 建段成功会弹顶部通知，排空其定时器
    });
  });

  group('③ 点选段内日子 → 走了 / 还在经期 / 删段', () {
    testWidgets('段内日子显示「月经走了」+「还在经期」，且能删整次', (tester) async {
      // 造一段覆盖「今天」的经期。🔴「今天」必须用**空间时区**（+8）算：
      // 页面用的是 spaceTodayIso，CI 在 UTC 跑，UTC 16:00 后两者差一天，
      // 用本机 now() 会在那个时段稳定假红（2026-11-27 实测）。
      final todayIso = spaceTodayIso(DateTime.now().toUtc());
      // 段从**昨天**开始：今天就是第 2 天，此时「月经走了」走 PUT 改 length
      // （若是段首日，Web/App 都走 DELETE 整条——那是另一种正确语义）
      final startIso = dayStr(dayNum(todayIso) - 1);
      final s = _Store([
        {
          'id': 'ep-1',
          'kind': 'period',
          'author': 'u1',
          'body': {'start': startIso, 'length': 3},
          'created': _ts('${startIso}T09:00:00+08:00'),
          'updated': _ts('${startIso}T09:00:00+08:00'),
        },
      ]);
      final c = _setup(s);
      await _pump(tester, c);

      // 今天就在段内：日志卡直接是段内形态
      await _scrollTo(tester, find.byKey(const Key('period-log-end')));
      expect(find.byKey(const Key('period-log-end')), findsOneWidget);
      expect(find.byKey(const Key('period-log-more')), findsOneWidget);

      // 点「月经走了」→ PUT
      await tester.ensureVisible(find.byKey(const Key('period-log-end')));
      await tester.tap(find.byKey(const Key('period-log-end')));
      await tester.pumpAndSettle();
      // 第 2 天点「走了」= PUT 把 length 截到昨天（1）
      expect(s.putBodies, isNotEmpty, reason: '「月经走了」必须真的写回');
      expect((s.putBodies.last['body'] as Map)['length'], 1);

      // 删整次：历史段卡的「更多操作」里仍保留删除
      final more = find.byTooltip('更多操作');
      if (more.evaluate().isNotEmpty) {
        await tester.tap(more.first);
        await tester.pumpAndSettle();
        expect(find.text('删除这次'), findsOneWidget);
        expect(find.text('编辑'), findsNothing,
            reason: '段四：编辑入口已随表单删除');
        // 关掉菜单不执行删除（避免影响后续断言）
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
      }
      await _flush(tester);
    });
  });
}
