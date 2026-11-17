/// 生理期阶段色语义表（2.3.9 视觉对齐 rollout 段）。
///
/// Web 端这组色是**主题变量机制**：`--period` / `--fertile` / `--green` /
/// `--amber` 定义在 `:root`（浅）与 `:root.dark`（夜）两处全局兜底层，
/// **七套主题块（style.css:165-192 浅 / :1542-1569 夜）不覆盖本组变量**——
/// 即阶段色只随明暗模式切换，不随主题色板变化（与 Web 行为逐位一致）。
/// 本表即该机制的 App 端等价：按 `Brightness` 取明暗两档值，逐值实读：
///
/// 浅色（style.css）：
///   --period:#C23F68 / --period-soft:#FBE3EC / --period-ink:#8A2445 /
///   --period-rgb:194,63,104（:57-60）
///   --fertile:#7B63A0 / --fertile-ink:#54407A / --fertile-rgb:123,99,160（:61-63）
///   --green:#4B6B3F（:38）/ --green-rgb:75,107,63（:49）
///   --amber:#8A5A22（:40）/ --amber-rgb:138,90,34（:50）
/// 夜色（style.css:1506-1511）：
///   --period:#EE7C9F / --period-soft:#3D1C28 / --period-ink:#FFC6D8 /
///   --period-rgb:238,124,159（:1510）
///   --fertile:#B49BD6 / --fertile-ink:#D8C8EE / --fertile-rgb:180,155,214（:1511）
///   --green:#8FB27C / --green-rgb:143,178,124（:1506/:1508）
///   --amber:#D2A472 / --amber-rgb:210,164,114（:1506/:1508）
///
/// 🔴 本文件只有色值常量与明暗取值，零计算、零日期逻辑（period parity
/// 245/245 的数学在 period_engine.dart，与本文件无交集）。
library;

import 'package:flutter/material.dart';

bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

/// `--period`（月经期：圆点 / 描边 / 环形进度，style.css:57/:1510）。
/// 🔴 纯色——Web `cycle-ring .ring-fill` 为 `stroke:var(--period)`
/// （style.css:1699），不存在渐变（plan 1.8:131 已复核）。
Color periodStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFEE7C9F) : const Color(0xFFC23F68);

/// `--period-soft`（月经期铺底浅粉，style.css:58/:1510）。
Color periodSoftColor(BuildContext c) =>
    _dark(c) ? const Color(0xFF3D1C28) : const Color(0xFFFBE3EC);

/// `--period-ink`（浅粉底上的字，style.css:59/:1510）。
Color periodInkColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFFFC6D8) : const Color(0xFF8A2445);

/// `--fertile`（排卵窗 / 排卵日圆点，style.css:61/:1511）。
Color fertileStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFB49BD6) : const Color(0xFF7B63A0);

/// 卵泡期 = `--green`（Web 卵泡期阶段色 `rgba(var(--green-rgb),.26)`
/// 的实体色，style.css:38/:1506）。
Color follicularStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFF8FB27C) : const Color(0xFF4B6B3F);

/// 黄体期 = `--amber`（Web 黄体期阶段色 `rgba(var(--amber-rgb),.28)`
/// 的实体色，style.css:40/:1506）。
Color lutealStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFD2A472) : const Color(0xFF8A5A22);
