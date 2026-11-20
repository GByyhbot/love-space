/// 「数据管理与通知渠道」章 · 段 A：全部端点的唯一封装（3 个 GET + 6 个写方法）。
///
/// 🔴 7-C 返修后的错误通道（`api_client.dart:279`
/// `validateAppStatus(s) => s != null && s < 500` 会**放行 4xx**）：
/// **全部写方法统一经 [_write] → `api.writeResponseError(r)`**
/// （`api_client.dart:332-335`：2xx→null、4xx→服务端 `data['detail']` 中文原文、
/// 拿不到原文才退兜底）。真正抛出的异常（5xx / 网络层）由 `api.errorDetail`
/// 兜底。范式见 `period_controller.dart:172-181`。
///
/// 失败一律：不发成功通知 / 不 pop / 输入保留 / 不自动重试 / 不本地改动列表；
/// **只有成功后才由页面重拉 GET**（确认 events 落库 / 渠道消失）。
/// 写路径的 `X-Love-Space: 1` 由共享 dio 拦截器注入
/// （`api_client.dart:291-298`），本封装不重复加头。
library;

import 'package:dio/dio.dart';

import '../../core/api/api_client.dart' as api;
import 'notify_models.dart';

/// GET 失败：携带服务端 `detail` 原文（或兜底文案），交给页面内联呈现。
class NotifyFailure implements Exception {
  const NotifyFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class NotifyApi {
  const NotifyApi(this._dio);

  final Dio _dio;

  /// 🔴 统一写入口：4xx 作为「成功 Response」返回也必须显式判定，
  /// 否则 `validateAppStatus` 会把 422 / 404 / 403 当成成功（7-C 真机阻断级）。
  /// 返回 null = 真成功（2xx）；否则为服务端错误文案原文。
  Future<String?> _write(
      Future<Response<dynamic>> Function(Dio dio) request) async {
    try {
      final Response<dynamic> resp = await request(_dio);
      return api.writeResponseError(resp);
    } catch (e) {
      return api.errorDetail(e);
    }
  }

  /// GET 也显式判状态码：4xx 同样被 `validateAppStatus` 放行，不能默默当空列表。
  Future<Response<dynamic>> _get(String path) async {
    try {
      final Response<dynamic> r = await _dio.get(path);
      final String? err = api.writeResponseError(r);
      if (err != null) throw NotifyFailure(err);
      return r;
    } on NotifyFailure {
      rethrow;
    } catch (e) {
      throw NotifyFailure(api.errorDetail(e));
    }
  }

  List<T> _parseList<T>(Object? data, T Function(Map<String, dynamic> j) from) {
    if (data is! List) return <T>[];
    return data
        .whereType<Map>()
        .map((Map<dynamic, dynamic> e) => from(e.cast<String, dynamic>()))
        .toList();
  }

  /// `GET /api/channels`（`main.py:2518-2527`）：服务端不回传 config。
  Future<List<ChannelItem>> loadChannels() async {
    final Response<dynamic> r = await _get('/api/channels');
    return _parseList<ChannelItem>(r.data, ChannelItem.fromJson);
  }

  /// `GET /api/deliveries`（`main.py:2567-2572`）：最近 100 条发送记录。
  Future<List<DeliveryItem>> loadDeliveries() async {
    final Response<dynamic> r = await _get('/api/deliveries');
    return _parseList<DeliveryItem>(r.data, DeliveryItem.fromJson);
  }

  /// `GET /api/notices`（`main.py:1955-1958`）：最多 200 条、仅本人。
  Future<List<NoticeItem>> loadNotices() async {
    final Response<dynamic> r = await _get('/api/notices');
    return _parseList<NoticeItem>(r.data, NoticeItem.fromJson);
  }

  /// ① `POST /api/channels`（`main.py:2530-2544`）。
  /// `validate_config` 的 422「请填写完整的渠道配置」/「通知类型不正确」等
  /// 中文原文原样返回，由页面做「顶部通知 + 表单内联错误区」双呈现。
  Future<String?> createChannel(Map<String, dynamic> payload) =>
      _write((Dio dio) => dio.post('/api/channels', data: payload));

  /// ② `DELETE /api/channels/{cid}`（`main.py:2547-2551`）。
  Future<String?> deleteChannel(String cid) =>
      _write((Dio dio) => dio.delete('/api/channels/$cid'));

  /// ③ `POST /api/channels/{cid}/test`（`main.py:2554-2564`）。
  /// 404「渠道不存在」原文透传。
  Future<String?> testChannel(String cid) =>
      _write((Dio dio) => dio.post('/api/channels/$cid/test'));

  /// ④ `POST /api/deliveries/{did}/retry`（`main.py:2575-2579`）。
  Future<String?> retryDelivery(String did) =>
      _write((Dio dio) => dio.post('/api/deliveries/$did/retry'));

  /// ⑤ `POST /api/notices/read`（`main.py:1961-1972`）：
  /// 空参数＝全部已读；`record_id` 查询参数＝单条已读
  /// （对齐 `app.js:2613` `post('/notices/read?record_id='+id)`）。
  /// 2.5.9 条目三：record_id=单条已读（不变）；event=按事件批量已读
  /// （裁定④「全部已读」只清非 chat 事件的既有后端接口，main.py:1961）。
  Future<String?> markNoticesRead({String? recordId, String? event}) => _write(
        (Dio dio) => dio.post(
          '/api/notices/read',
          queryParameters: <String, dynamic>{
            if (recordId != null && recordId.isNotEmpty) 'record_id': recordId,
            if (event != null && event.isNotEmpty) 'event': event,
          },
        ),
      );

  /// ⑥ `DELETE /api/notices/read`（`main.py:1975-1983`）：删已读。
  /// 删前确认与确认文案由页面负责（对齐 `app.js:2572`）。
  Future<String?> deleteReadNotices() =>
      _write((Dio dio) => dio.delete('/api/notices/read'));
}
