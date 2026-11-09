package cn.iepose.lovespace;

import android.app.Activity;
import android.graphics.Color;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsControllerCompat;

/**
 * 状态栏：走 **edge-to-edge**，状态栏本体透明，颜色由网页自己画。
 *
 * <h3>为什么放弃 setStatusBarColor</h3>
 * 它在 API 35 起被废弃。targetSdk 34 时按文档仍有效，但实测（主人机）无效 ——
 * `styles.xml` 里 `android:statusBarColor="#FCF8F9"` 的值一直显示，运行时怎么设都不变。
 * 微信、QQ 等"状态栏颜色随主题"的 App 走的是另一条路：**内容延伸到状态栏后面，
 * 颜色由 App 自己画**。这也是 Android 15+ 的唯一正解。
 *
 * <h3>为什么键盘不受影响</h3>
 * 之前键盘坏，根因是 targetSdk 35 把 adjustResize 的窗口缩放机制整个移除了；
 * 现在停在 34，缩放是老式窗口 frame 缩放，与「内容是否延伸到状态栏后面」是两回事
 * （LAYOUT_FULLSCREEN 只影响 WebView 在 frame 内怎么铺，不改 frame 本身）。
 * 就算某些机型缩放仍不生效，`setupImeHeightBridge()` 会照旧把 IME 高度喂给网页 ——
 * 那是 1.7.0 就验证过的路径，不会比历史更差。
 *
 * <h3>颜色从哪来</h3>
 * 网页（style.css 末尾的 is-native-app 块）把顶栏/聊天头部画到 y=0：
 * 非聊天页是 --bg，聊天页是 --surface，颜色天然等于主题色。
 * 状态栏本体透明，透出来的就是网页画的这块。
 *
 * <h3>图标深浅</h3>
 * 浅色主题 → 深色图标；深色主题 → 浅色图标。用现代 API
 * {@code WindowInsetsControllerCompat.setAppearanceLightStatusBars}，由网页经
 * ThemeBridge 告知当前是否深色（App 的深浅色开关独立于系统）。
 */
final class StatusBarTheme {
    private static final String TAG = "LoveSpace/StatusBar";

    private StatusBarTheme() {}

    /** 启动时调一次：建立 edge-to-edge + 透明状态栏。 */
    static void init(Activity activity) {
        apply(activity, false);
    }

    /**
     * @param dark 当前是否深色主题（决定状态栏图标用浅色还是深色）
     */
    static void apply(Activity activity, boolean dark) {
        if (activity == null) return;
        try {
            Window window = activity.getWindow();
            // 状态栏本体透明：透出下层，下层（WebView）画什么颜色就是什么颜色
            window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            window.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS);
            window.setStatusBarColor(Color.TRANSPARENT);

            // 内容延伸到状态栏后面（ WebView 铺满整屏，含状态栏那一块）
            View decor = window.getDecorView();
            int ui = decor.getSystemUiVisibility();
            ui |= View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN;
            decor.setSystemUiVisibility(ui);

            // 图标深浅：深色主题用浅色图标，浅色主题用深色图标
            WindowInsetsControllerCompat c = WindowCompat.getInsetsController(window, decor);
            if (c != null) c.setAppearanceLightStatusBars(!dark);
            Log.i(TAG, "edge-to-edge 已就绪，图标 " + (dark ? "浅色" : "深色"));
        } catch (Throwable t) {
            Log.w(TAG, "apply failed", t);
        }
    }
}
