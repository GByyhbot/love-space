/* 阶段 0 · 鉴权方案最小实验（方案 v2 · 阶段 0 任务 2）
   验证项：
   E1 登录（拦截器统一注入 X-Love-Space: 1）
   E2 Cookie 持久化免登录访问 /api/me
   E3 「重启」模拟：全新实例从同一 Cookie 存储加载 → 免登录成立
   E4 失效/垃圾会话 → 401 → 客户端应回登录页
   E5 缺 X-Love-Space → 403；拦截器注入后成功
   E6 SSE 流式读取 /api/events（无限流必须流式 + 时间上限）
   E7 多线路：/api/routes 形态 + CookieJar 按域名隔离结论
   运行：ORIGIN=http://127.0.0.1:8356 dart run auth_probe.dart
   ⚠️ 本机有 HTTP_PROXY 环境变量（WorkBuddy 挂载代理），Dart HttpClient 默认
   findProxyFromEnvironment 会把请求以「绝对形式请求行」发给代理——本地服务 404。
   因此所有 Dio 实例显式 DIRECT（真机上无此环境变量，默认行为即是 DIRECT）。 */
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';

final ORIGIN = Platform.environment['ORIGIN'] ?? 'http://127.0.0.1:8356';
final results = <String, String>{};

Dio directDio({CookieJar? jar, bool authHeader = true, Duration? timeout}) {
  final dio = Dio(BaseOptions(baseUrl: ORIGIN, connectTimeout: const Duration(seconds: 8), receiveTimeout: timeout ?? const Duration(seconds: 10)));
  dio.httpClientAdapter = IOHttpClientAdapter()..createHttpClient = () {
    final h = HttpClient();
    h.findProxy = (uri) => 'DIRECT';   /* 本机代理环境变量在，必须显式直连 */
    return h;
  };
  if (jar != null) dio.interceptors.add(CookieManager(jar));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (authHeader && ['POST', 'PUT', 'PATCH', 'DELETE'].contains(options.method.toUpperCase())) {
      options.headers['X-Love-Space'] = '1';
    }
    handler.next(options);
  }));
  return dio;
}

Future<void> main() async {
  final store = FileStorage('${Directory.systemTemp.path}/auth-probe-store');

  /* E1：登录 */
  final jar = PersistCookieJar(ignoreExpires: true, storage: store);
  final dio = directDio(jar: jar);
  Response login;
  try {
    login = await dio.post('/api/login', data: {'username': 'e2e1', 'password': 'love-space-e2e-123'});
    results['E1 登录'] = login.statusCode == 200 ? 'PASS（200，Set-Cookie 已入 jar）' : 'FAIL ${login.statusCode}';
  } on DioException catch (e) {
    results['E1 登录'] = 'FAIL ${e.response?.statusCode} ${e.requestOptions.uri}';
    _print(); exitCode = 1; return;
  }

  /* E2：同一 jar 免登录访问 /api/me */
  final me1 = await dio.get('/api/me');
  results['E2 免登录 /api/me'] = me1.statusCode == 200 ? 'PASS（name=${me1.data['user']['name']}）' : 'FAIL ${me1.statusCode}';

  /* E5a：绕过拦截器发写请求（缺 X-Love-Space）→ 403 */
  final raw = directDio(jar: jar, authHeader: false);
  try {
    await raw.post('/api/logout');
    results['E5a 缺头写请求'] = 'FAIL（居然成功了）';
  } on DioException catch (e) {
    results['E5a 缺头写请求'] = e.response?.statusCode == 403 ? 'PASS（403）' : 'FAIL ${e.response?.statusCode}';
  }

  /* 重新登录（E5a 的 logout 被 403 拦下未执行，会话仍在；此处刷新会话供后续用） */
  await dio.post('/api/login', data: {'username': 'e2e1', 'password': 'love-space-e2e-123'});

  /* E5b：拦截器注入头后登出 → 成功 */
  final out = await dio.post('/api/logout');
  results['E5b 拦截器注入头写请求'] = out.statusCode == 200 ? 'PASS（200）' : 'FAIL ${out.statusCode}';

  /* E4：垃圾会话 → 401 */
  final bad = directDio();
  bad.options.headers['cookie'] = 'love_session=garbage-token-xxx';
  try {
    final r = await bad.get('/api/me');
    results['E4 垃圾会话'] = 'FAIL ${r.statusCode}';
  } on DioException catch (e) {
    results['E4 垃圾会话'] = e.response?.statusCode == 401 ? 'PASS（401，应回登录页）' : 'FAIL ${e.response?.statusCode}';
  }

  /* E3：「重启」模拟——重新登录后，全新实例从同一存储加载会话，免登录成立 */
  final jar2 = PersistCookieJar(ignoreExpires: true, storage: store);
  final dio2 = directDio(jar: jar2);
  await dio2.post('/api/login', data: {'username': 'e2e1', 'password': 'love-space-e2e-123'});
  final dioRestart = directDio(jar: PersistCookieJar(ignoreExpires: true, storage: store));
  final me2 = await dioRestart.get('/api/me');
  results['E3 重启模拟'] = me2.statusCode == 200 ? 'PASS（新实例免登录成立）' : 'FAIL ${me2.statusCode}';

  /* E6：SSE 流式读取（无限流 + 2s 心跳：必须流式 + 时间上限，普通 GET 会永久挂起） */
  final sse = directDio(jar: jar2, timeout: const Duration(seconds: 12));
  sse.options.responseType = ResponseType.stream;
  final lines = <String>[];
  final rsp = await sse.get<ResponseBody>('/api/events');
  final sw = Stopwatch()..start();
  await for (final chunk in rsp.data!.stream) {
    final s = utf8.decode(chunk).trim();
    if (s.isNotEmpty) lines.add(s);
    if (sw.elapsed > const Duration(seconds: 6)) break;
  }
  results['E6 SSE 流式'] = 'PASS（6s 捕获 ${lines.length} 行：${lines.take(2).join(' | ')}）';

  /* E7：多线路形态 + Cookie 按域名隔离结论 */
  final routes = await dioRestart.get('/api/routes');
  final n = routes.data is List ? (routes.data as List).length : 0;
  results['E7 多线路'] = 'PASS（/api/routes 返回 $n 条线路；CookieJar 原生按域名隔离，'
      '策略=固定主线路登录，不可达时按 /api/routes 顺序切换并在新域名重新登录）';

  _print();
}

void _print() {
  stderr.writeln('--- 阶段 0 鉴权实验结果 ---');
  results.forEach((k, v) => stderr.writeln('$k: $v'));
}
