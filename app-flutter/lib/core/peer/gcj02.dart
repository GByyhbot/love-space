/// 2.8.0 定位守护第 0 步 · 路线 B：WGS-84 → GCJ-02 坐标转换（纯函数）。
///
/// 口径（提示词第 0 步/主体二）：路线 B 原生 LocationManager 输出 WGS-84，
/// 端上转换后上报，后端入库统一 GCJ-02（高德底图同系无偏移），后端不做二次转换。
/// 算法为公开的标准偏移模型（国测局偏移公式），与 couple-tracker 的实现无关
/// （其仓库无 LICENSE，红线：只借鉴设计与参数，代码自研）。
///
/// 精度边界：偏移模型在境内（约 72–135°E, 0.8–56°N）有效；境外坐标直接原样
/// 返回（isOutOfChina 判定），海外行程不转（转了反而错）。
library;

import 'dart:math' as math;

const double _a = 6378245.0; // 长半轴
const double _ee = 0.00669342162296594323; // 扁率

bool _outOfChina(double lat, double lng) {
  return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

double _transformLat(double x, double y) {
  var ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

double _transformLng(double x, double y) {
  var ret =
      300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}

/// WGS-84 → GCJ-02。境外（模型无效域）原样返回。
({double lat, double lng}) wgs84ToGcj02(double lat, double lng) {
  if (_outOfChina(lat, lng)) return (lat: lat, lng: lng);
  var dLat = _transformLat(lng - 105.0, lat - 35.0);
  var dLng = _transformLng(lng - 105.0, lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  var magic = math.sin(radLat);
  magic = 1 - _ee * magic * magic;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
  dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
  return (lat: lat + dLat, lng: lng + dLng);
}

/// 两点球面距离（米，Haversine）。GCJ-02 下用于位移判定与 25m 门槛——
/// 偏移是系统性小形变，同系两点间距离与 WGS 距离差可忽略。
double distanceMeters(
    double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
}
