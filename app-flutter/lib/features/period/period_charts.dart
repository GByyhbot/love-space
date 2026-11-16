/// 生理数据分析图表件（条目 8 · 段 C）：把 [PaSvg] 的 Web 等价几何用
/// `CustomPaint` 画出来，**不引 Chart.js / 第三方图表库**（对齐 `period.js:524`
/// 「离线 PWA 不能把核心页面挂在 CDN 上」的口径）。
///
/// `PaSvg` 由 `period_analysis.dart` 的 `paGrouped/paVBars/paLine` 产出，
/// 坐标逐项与 Web 实跑 SVG 全等（见 `period_c_portrait_test.dart`）；本文件
/// 只负责把 `rect / line / path / circle / text` 映射到 Canvas，不改任何数字。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'period_analysis.dart';

/// 把 Web CSS 变量名映射成 Material 颜色；六位十六进制原样解析。
Color _colorOf(String? raw, ColorScheme cs, {bool stroke = false}) {
  final v = raw ?? '';
  switch (v) {
    case 'var(--primary)':
      return cs.primary;
    case 'var(--soft-strong)':
      return cs.primaryContainer;
    case 'var(--line)':
      return cs.outlineVariant;
    case 'var(--surface)':
      return cs.surface;
    case 'none':
    case '':
      return Colors.transparent;
  }
  if (v.startsWith('#') && v.length == 7) {
    final n = int.tryParse(v.substring(1), radix: 16);
    if (n != null) return Color(0xFF000000 | n);
  }
  return stroke ? cs.outlineVariant : cs.primary;
}

double _num(String? raw, [double fallback = 0]) =>
    double.tryParse(raw ?? '') ?? fallback;

/// 虚线段（Web `stroke-dasharray="3 3"` / `"2 4"` 等价）。
void _dashLine(Canvas canvas, Offset a, Offset b, Paint paint, double dash,
    double gap) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len == 0 || dash <= 0) return;
  final ux = dx / len;
  final uy = dy / len;
  var t = 0.0;
  while (t < len) {
    final end = math.min(t + dash, len);
    canvas.drawLine(
      Offset(a.dx + ux * t, a.dy + uy * t),
      Offset(a.dx + ux * end, a.dy + uy * end),
      paint,
    );
    t = end + gap;
  }
}

/// 解析 `paLine` 的 `M x y L x y …` 路径。
List<Offset> _pathPoints(String d) {
  final out = <Offset>[];
  final re = RegExp(r'([ML])\s*(-?[\d.]+)\s+(-?[\d.]+)');
  for (final m in re.allMatches(d)) {
    out.add(Offset(
      double.tryParse(m.group(2) ?? '') ?? 0,
      double.tryParse(m.group(3) ?? '') ?? 0,
    ));
  }
  return out;
}

/// [PaSvg] → Canvas。X 按 `width/320`、Y 按 `height/h` 缩放（卡片宽度
/// 随屏幕变化，逻辑坐标系仍是 Web 的 `viewBox="0 0 320 h"`）。
class PaChartPainter extends CustomPainter {
  const PaChartPainter(this.svg, this.scheme);

  final PaSvg svg;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 320.0;
    final sy = size.height / svg.height.toDouble();
    Offset p(double x, double y) => Offset(x * sx, y * sy);

    for (final e in svg.els) {
      final a = e.attrs;
      switch (e.tag) {
        case 'line':
          final paint = Paint()
            ..color = _colorOf(a['stroke'], scheme, stroke: true)
            ..strokeWidth = 1;
          final x1 = _num(a['x1']);
          final y1 = _num(a['y1']);
          final x2 = _num(a['x2']);
          final y2 = _num(a['y2']);
          final dash = a['stroke-dasharray'];
          if (dash != null) {
            final bits = dash.split(RegExp(r'\s+'));
            _dashLine(canvas, p(x1, y1), p(x2, y2), paint,
                double.tryParse(bits.first) ?? 3,
                bits.length > 1 ? double.tryParse(bits[1]) ?? 3 : 3);
          } else {
            canvas.drawLine(p(x1, y1), p(x2, y2), paint);
          }
          break;

        case 'rect':
          final x = _num(a['x']);
          final y = _num(a['y']);
          final w = _num(a['width']);
          final h = _num(a['height']);
          final r = Radius.circular(_num(a['rx'], 3));
          final rect = RRect.fromRectAndCorners(
            Rect.fromLTWH(x * sx, y * sy, w * sx, h * sy),
            topLeft: r,
            topRight: r,
            bottomLeft: r,
            bottomRight: r,
          );
          final fill = a['fill'];
          if (fill != null && fill != 'none') {
            canvas.drawRRect(
                rect, Paint()..color = _colorOf(fill, scheme));
          }
          final stroke = a['stroke'];
          if (stroke != null) {
            final paint = Paint()
              ..color = _colorOf(stroke, scheme, stroke: true)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1;
            final dash = a['stroke-dasharray'];
            if (dash != null) {
              // 虚线空框：四条边分别画虚线（Web `fill=none stroke-dasharray`）。
              final bits = dash.split(RegExp(r'\s+'));
              final on = double.tryParse(bits.first) ?? 3;
              final off = bits.length > 1 ? double.tryParse(bits[1]) ?? 3 : 3;
              final tl = Offset(rect.left, rect.top);
              final tr = Offset(rect.right, rect.top);
              final br = Offset(rect.right, rect.bottom);
              final bl = Offset(rect.left, rect.bottom);
              _dashLine(canvas, tl, tr, paint, on * sx, off * sx);
              _dashLine(canvas, tr, br, paint, on * sy, off * sy);
              _dashLine(canvas, br, bl, paint, on * sx, off * sx);
              _dashLine(canvas, bl, tl, paint, on * sy, off * sy);
            } else {
              canvas.drawRRect(rect, paint);
            }
          }
          break;

        case 'path':
          final pts = _pathPoints(a['d'] ?? '');
          if (pts.isEmpty) break;
          final path = Path();
          for (var i = 0; i < pts.length; i++) {
            final q = p(pts[i].dx, pts[i].dy);
            if (i == 0) {
              path.moveTo(q.dx, q.dy);
            } else {
              path.lineTo(q.dx, q.dy);
            }
          }
          canvas.drawPath(
            path,
            Paint()
              ..color = _colorOf(a['stroke'], scheme, stroke: true)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round,
          );
          break;

        case 'circle':
          final c = p(_num(a['cx']), _num(a['cy']));
          final r = _num(a['r'], 3.5) * ((sx + sy) / 2);
          final fill = a['fill'];
          if (fill != null && fill != 'none') {
            canvas.drawCircle(c, r, Paint()..color = _colorOf(fill, scheme));
          }
          final stroke = a['stroke'];
          if (stroke != null) {
            canvas.drawCircle(
              c,
              r,
              Paint()
                ..color = _colorOf(stroke, scheme, stroke: true)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
          }
          break;

        case 'text':
          final text = e.text ?? '';
          if (text.isEmpty) break;
          final isValue = a['class'] == 'pa-val';
          final tp = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                fontSize: isValue ? 10 : 9,
                color: isValue ? scheme.onSurface : scheme.outline,
                fontWeight: isValue ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final anchor = a['text-anchor'] ?? '';
          final x = _num(a['x']) * sx;
          final y = _num(a['y']) * sy;
          final dx = anchor == 'middle'
              ? -tp.width / 2
              : anchor == 'end'
                  ? -tp.width
                  : 0.0;
          tp.paint(canvas, Offset((x + dx).clamp(0.0, size.width - tp.width), y - tp.height / 2));
          break;
      }
    }
  }

  @override
  bool shouldRepaint(PaChartPainter old) =>
      old.svg != svg || old.scheme != scheme;
}

/// 一张图（高度取自 Web `paGrouped/paVBars/paLine` 的 h）。
class PaChart extends StatelessWidget {
  const PaChart({super.key, required this.svg});

  final PaSvg svg;

  @override
  Widget build(BuildContext context) => Semantics(
        label: svg.aria,
        child: SizedBox(
          width: double.infinity,
          height: svg.height.toDouble(),
          child: CustomPaint(
            painter: PaChartPainter(svg, Theme.of(context).colorScheme),
          ),
        ),
      );
}

/// `paDotRows` 点阵（颜色 / 白带逐日一个圆点）。
class PaDotMatrix extends StatelessWidget {
  const PaDotMatrix({super.key, required this.rows});

  final List<PaDotRow> rows;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              SizedBox(
                  width: 56,
                  child: Text(row.name,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.outline))),
              Wrap(
                spacing: 5,
                children: [
                  for (final cell in row.cells)
                    Tooltip(
                      message: cell.tip,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: cell.hollow
                              ? Colors.transparent
                              : _colorOf(cell.color, cs),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: cell.hollow
                                ? cs.outlineVariant
                                : _colorOf(cell.color, cs),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ]),
          ),
      ],
    );
  }
}
