# 内置贴纸包资产说明（2.4.4 第 2 项）

## 包 A · bigmoji「大表情」（60 张 · 256px WebP · 356KB）

- **图库**：OpenMoji v17.0.0（官方全量包 openmoji-618x618-color.zip，618px PNG → 256px WebP q82）
- **许可证**：**CC BY-SA 4.0**（Creative Commons Attribution-ShareAlike 4.0）
- **署名**：Emoji art by [OpenMoji](https://openmoji.org) – CC BY-SA 4.0（来源仓库 https://github.com/hfg-gmuend/openmoji）
- **清单**：0.webp–59.webp，按常用度排序（笑脸/爱心/手势/日常类，码点清单见
  仓库 2.4.4 提交二提交说明与交付摘要）

## 包 B · memes「梗图」（28 张 · ≤256px WebP · 320KB）

- **来源**：GitHub 公开合集 [ChineseBQB](https://github.com/zhaoolee/ChineseBQB)
  （zhaoolee 维护的中文表情包仓库），取「斗图之王BQB」「微信网友贡献表情包_
  暂存_有时间慢慢整理BQB」「038Jacky_张学友BQB」「039YaoMing表情包三巨头_
  姚明BQB」四个目录
- **性质**：网络公开流传的中文梗图合集（斗图/熊猫头/日常吐槽/三巨头经典脸）；
  本仓库仅作个人空间内部分享用途打包，出处备查如上；短边 ≥200px 程序化把关
- **清单**：0.webp–27.webp（部分为动画 WebP，源自原 GIF）

## 双落位约定

两个包的资产**同时**存在于：
1. App assets（本目录，pubspec.yaml 声明）——面板本地渲染、离线秒开；
2. 服务端 `static/stickers/bigmoji|memes/<序号>.webp`（部署同步）——发送
   载荷 `sticker: '/static/stickers/<dir>/<i>.webp'` 走既有贴纸链，
   对方（Web/App）按 URL 渲染，互通。
