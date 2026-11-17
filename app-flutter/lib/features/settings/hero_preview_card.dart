/// 首页 hero 效果预览卡（2.4.1 修复包第 3 项②）：把候选封面按首页 hero
/// 的**真实布局**渲染一遍——两人名字行顶部、天数行与日期行锚定底部
/// （Positioned bottom:18，与首页 2.3.8 修复后的实现同数值）、底部渐变罩。
/// 布局数值与首页 `_Hero` 逐位一致（radius 20 / minHeight 230 /
/// padding 18px 16px / serif 22 名字 / serif 42 天数），禁止另发明摆位。
/// 封面 widget 由调用方传入（已选字节优先，未选时是当前封面网络图）。
library;

import 'package:flutter/material.dart';

import '../shell/web_chrome.dart' show webSerifStyle;

class HeroPreviewCard extends StatelessWidget {
  const HeroPreviewCard({
    super.key,
    required this.names,
    required this.days,
    required this.since,
    required this.coverImage,
  });

  /// 名字行文本（两人名 + ♥，与首页 hero 一致拼法）
  final String names;
  final int days;
  final String since;

  /// 候选封面（已选字节 = Image.memory；未选 = 当前封面网络图或占位）。
  final Widget coverImage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      key: const Key('hero-preview'),
      constraints: const BoxConstraints(minHeight: 230),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // 候选封面铺满（调用方决定字节图 / 网络图 / 占位）。
            Positioned.fill(child: coverImage),
            // --hero-shade 双层遮罩（与首页 _HomeCover 同数值：
            // style.css:2259 的 90deg + 0deg 两层）。
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[
                      const Color.fromRGBO(37, 28, 34, 0.74),
                      const Color.fromRGBO(37, 28, 34, 0.40),
                      const Color.fromRGBO(37, 28, 34, 0.10),
                    ],
                    stops: const <double>[0, 0.58, 1],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      const Color.fromRGBO(37, 28, 34, 0.62),
                      const Color.fromRGBO(37, 28, 34, 0),
                    ],
                    stops: const <double>[0, 0.52],
                  ),
                ),
              ),
            ),
            // 名字行固定顶部（serif 22/600，与首页 _Hero 同数值）。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
              child: Align(
                alignment: Alignment.topLeft,
                child: Text(
                  names,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFamily: webSerifStyle(22, color: Colors.white).fontFamily,
                    fontFamilyFallback:
                        webSerifStyle(22, color: Colors.white).fontFamilyFallback,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    height: 1.3,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            // 天数行 + 日期行锚定底部（Positioned bottom:18，2.3.8 修复后同位）。
            Positioned(
              bottom: 18,
              left: 16,
              right: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: '$days',
                          style: webSerifStyle(42,
                              color: Colors.white, height: 1.15),
                        ),
                        TextSpan(
                          text: ' 天',
                          style:
                              TextStyle(fontSize: 14, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$since 起 · 今天也要好好相爱',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.94)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
