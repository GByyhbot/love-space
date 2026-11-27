/// 全 App 统一圆角线形语义图标表（同一含义全仓共用同一图标）。
library;

import 'package:flutter/material.dart';

abstract final class AppIcons {
  // ── 媒体与内容 ──
  static const IconData music = Icons.music_note_rounded;
  static const IconData video = Icons.videocam_rounded;
  static const IconData file = Icons.insert_drive_file_rounded;
  static const IconData photo = Icons.photo_library_rounded;
  static const IconData mood = Icons.mood_rounded;
  static const IconData diary = Icons.menu_book_rounded;
  static const IconData wish = Icons.auto_awesome_rounded;
  static const IconData surprise = Icons.card_giftcard_rounded;
  static const IconData anniversary = Icons.celebration_rounded;
  static const IconData ledger = Icons.receipt_long_rounded;
  static const IconData calendar = Icons.calendar_today_rounded;
  static const IconData search = Icons.search_rounded;
  static const IconData trash = Icons.delete_outline_rounded;
  static const IconData comment = Icons.chat_bubble_outline_rounded;
  static const IconData like = Icons.favorite_outline_rounded;
  static const IconData liked = Icons.favorite_rounded;

  // ── 网络与设备状态 ──
  static const IconData wifi = Icons.wifi_rounded;
  static const IconData cellular = Icons.signal_cellular_alt_rounded;
  static const IconData offline = Icons.signal_cellular_off_rounded;
  static const IconData networkOther = Icons.public_rounded;
  static const IconData location = Icons.place_outlined;
  static const IconData locationOff = Icons.location_off_outlined;
  static const IconData track = Icons.route_rounded;
  static const IconData phone = Icons.smartphone_rounded;
  static const IconData unlock = Icons.lock_open_rounded;
  static const IconData lock = Icons.lock_outline_rounded;
  static const IconData battery = Icons.battery_std_rounded;
  static const IconData batteryLow = Icons.battery_alert_rounded;
  static const IconData charging = Icons.bolt_rounded;
  static const IconData time = Icons.schedule_rounded;

  // ── 导航与系统 ──
  static const IconData settings = Icons.settings_outlined;
  static const IconData shield = Icons.verified_user_outlined;
  static const IconData notice = Icons.notifications_outlined;
  static const IconData chat = Icons.forum_outlined;
  static const IconData sync = Icons.sync_rounded;
  static const IconData add = Icons.add_rounded;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData back = Icons.arrow_back_rounded;
}
