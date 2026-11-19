/// 生理期阶段色语义表（2.4.8 方案 B 换色段）。
///
/// 🔴 2026-11-19 主人裁定：App 阶段色走「方案 B · 清透柔和」（主人看图
/// 选定），**与 Web 分道**——勿按 Web style.css 的旧阶段色值回退（方案 A
/// 的浅/夜八值已全部退役，本文件与 period 表面零残留）。本裁定推翻
/// 2.3.9 的「阶段色与 Web 逐位一致」口径；Web 端保持旧色不动。
///
/// 取值口径（方案 B 定案表，2.4.8 提示词硬指标）：
///
/// 浅色（主人选定的原值）：
///   月经期  #DE6B87 / 卵泡期 #84B96E / 排卵期 #9C7CC4 / 黄体期 #E3AC55
///   派生：period-soft #FBE9EE / period-ink #96455C / fertile-ink #5F4A86
/// 深色（同色相提亮档）：
///   月经期  #F08CA6 / 卵泡期 #A3D191 / 排卵期 #BFA5E0 / 黄体期 #EFBE6E
///   派生：period-soft #40222C / period-ink #FFC9D6 / fertile-ink #E2D4F5
///
/// 派生关系沿用 2.3.9 语义：soft = 主色极浅铺底（夜档压暗底）、
/// ink = 浅底上的字（主色加深两档，夜档提亮）。
///
/// 🔴 本文件只有色值常量与明暗取值，零计算、零日期逻辑（period parity
/// 245/245 的数学在 period_engine.dart，与本文件无交集）。
library;

import 'package:flutter/material.dart';

bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

/// 月经期主色（圆点 / 描边 / 环形进度 / 阶段条 / 日历格）。
/// 🔴 纯色——Web `cycle-ring .ring-fill` 为纯色描边、无渐变（plan 1.8
/// 已复核），App 端同口径。
Color periodStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFF08CA6) : const Color(0xFFDE6B87);

/// 月经期铺底（浅档极浅粉 / 夜档压暗底）。
Color periodSoftColor(BuildContext c) =>
    _dark(c) ? const Color(0xFF40222C) : const Color(0xFFFBE9EE);

/// 月经期 ink（浅底上的字，主色加深两档 / 夜档提亮）。
Color periodInkColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFFFC9D6) : const Color(0xFF96455C);

/// 排卵期主色（排卵窗 / 排卵日圆点 / 阶段条 / 日历格）。
Color fertileStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFBFA5E0) : const Color(0xFF9C7CC4);

/// 排卵期 ink（浅底上的字，主色加深两档 / 夜档提亮）。2.4.8 新增派生档
/// （2.3.9 表无此项，随方案 B 补齐完备）。
Color fertileInkColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFE2D4F5) : const Color(0xFF5F4A86);

/// 卵泡期主色（阶段条 / 日历格）。
Color follicularStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFA3D191) : const Color(0xFF84B96E);

/// 黄体期主色（阶段条 / 日历格）。
Color lutealStageColor(BuildContext c) =>
    _dark(c) ? const Color(0xFFEFBE6E) : const Color(0xFFE3AC55);
