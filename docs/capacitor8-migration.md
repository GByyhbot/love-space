# Capacitor 7 → 8 迁移清单（恋爱空间 App）

> 背景：Android 15+ 强制 edge-to-edge、`setStatusBarColor` 废弃、`adjustResize`
> 窗口缩放在 targetSdk 36 被移除。Capacitor 8 内置 SystemBars 核心插件与修复过的
> Keyboard 处理，把这一类问题从"我们自研"变成"官方维护"。
> 全网调研结论见 `.workbuddy/memory/2026-11-09.md`（2026-11-09 条目）。

## 现状（升级前）

| 项 | 值 |
|---|---|
| Capacitor | 7.6.9（core/cli/android） |
| 插件 | status-bar 7.0.6 / local-notifications 7.0.7 / background-mode 7.0.2（有 postinstall 中文化补丁） |
| AGP / Gradle | 8.7.2 / 8.11.1 |
| targetSdk | 34（为躲 edge-to-edge 强制而压回的临时值） |
| 自研键盘/状态栏代码 | `KeyboardAvoidance.java`(停用)、`WindowProbe.java`(停用)、`StatusBarTheme.java`、`ThemeBridge.java`、MainActivity 的 `setupImeHeightBridge()`、CSS `--safe-top` 手动补偿 |

## 迁移步骤

1. **依赖升 8.x**：core/cli/android ^8.6.0、status-bar ^8.0.4、
   local-notifications ^8.3.1、background-mode ^8.1.0 → `npm install`
   （postinstall 会跑中文化补丁，若插件源码文本变了会**大声报错**，按提示更新补丁）
2. **AGP 对齐**：读 `node_modules/@capacitor/android/capacitor/build.gradle` 里模板要求的
   AGP 版本，同步 `android/build.gradle` 的 classpath；gradle wrapper 版本按需升
3. **variables.gradle**：compileSdk/targetSdk → 36，androidx 版本对齐 Capacitor 8 模板
4. **清理冲突的自研代码**（capgo 明确警告会与 SystemBars 冲突）：
   - 删 `StatusBarTheme.java`（SYSTEM_UI_FLAG_LAYOUT_* + 透明状态栏，SystemBars 接管）
   - 删 `ThemeBridge.java`（图标深浅改用 `SystemBars.setStyle`）
   - 删 `KeyboardAvoidance.java`、`WindowProbe.java`（早已停用，git 历史可查）
   - **保留** `setupImeHeightBridge()`：它是 insets 旁路读取、原样下发，不与 SystemBars
     冲突，且是 targetSdk 36 下键盘的最后兜底
5. **Manifest**：删 `windowOptOutEdgeToEdgeEnforcement`（36 起被忽略）、
   `android:statusBarColor`、`android:windowLightStatusBar`（由 SystemBars/style 管理）
6. **capacitor.config.json**：`plugins.StatusBar` → `plugins.SystemBars`
   （`insetsHandling: 'css'`，注入 `--safe-area-inset-*`，老 WebView 上 env() 为 0 也能用）
7. **前端**：`syncStatusBar()` 改用 `SystemBars.setStyle`；CSS `--safe-top` 改为
   `var(--safe-area-inset-top, env(safe-area-inset-top))` 双保险
8. **`npx cap sync android`**：重新生成 assets 里的 capacitor.config.json / plugins.json
   （⚠️ 校验 appendUserAgent 没丢）
9. 版本 1.7.4 / versionCode 20261136 / UA 三处同号 → 出包 → 部署 → push + tag

## 回归项（两台真机都过才算完成）

- [ ] 键盘弹出/收起：输入栏贴合、无黑带、无白条、无抖动（**最高风险项**）
- [ ] 聊天页长文本输入时输入框随内容增高
- [ ] 状态栏颜色 = 主题色（七套主题 × 深浅色都切一遍）
- [ ] 状态栏图标深浅正确（浅色主题深图标 / 深色主题浅图标）
- [ ] 刘海屏顶部不被压住（env / 注入变量都生效）
- [ ] 底部导航栏（手势条）不遮输入栏
- [ ] 后台运行通知仍是中文「恋爱空间 / 正在守护你们的小空间…」
- [ ] 本地通知（提醒）正常
- [ ] 消息收发、SSE 实时刷新正常
- [ ] 从 1.7.3 覆盖安装不丢登录态

## 回滚

`git revert` 本次提交 + 重出 1.7.3 包即可；targetSdk/依赖全部回到 7.6.9 状态。
