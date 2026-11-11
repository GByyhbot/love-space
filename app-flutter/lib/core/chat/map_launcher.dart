/// 高德地图唤起（段三 · Step 8，对齐 Web openMap 顺序，无需 KEY）：
/// ① androidamap:// 直 scheme（externalApplication，未装高德会抛）；
/// ② 回退 https://uri.amap.com/marker（callnative=1，网页自己会再试拉起）。
/// 纯 URL 构造函数可单测；position 参数顺序是 lng,lat（对齐 Web）。
library;

import 'package:url_launcher/url_launcher.dart';

/// App scheme（对齐 Web：sourceApplication/poiname/lat/lon/dev=0）
Uri amapAppUrl(double lat, double lng, String name) {
  final q = 'sourceApplication=LoveSpace'
      '&poiname=${Uri.encodeQueryComponent(name)}'
      '&lat=$lat&lon=$lng&dev=0';
  return Uri.parse('androidamap://viewMap?$q');
}

/// 网页地图（对齐 Web：position=lng,lat & coordinate=gaode & callnative=1）
Uri amapWebUrl(double lat, double lng, String name) {
  return Uri.parse('https://uri.amap.com/marker?position=$lng,$lat'
      '&name=${Uri.encodeQueryComponent(name)}'
      '&coordinate=gaode&callnative=1&src=love-space');
}

/// 依次尝试 App scheme → 网页地图；都失败静默（无浏览器极端环境）
Future<void> openAmap(double lat, double lng, {String name = '我们的位置'}) async {
  try {
    await launchUrl(amapAppUrl(lat, lng, name),
        mode: LaunchMode.externalApplication);
    return;
  } catch (_) {}
  try {
    await launchUrl(amapWebUrl(lat, lng, name),
        mode: LaunchMode.externalApplication);
  } catch (_) {}
}
