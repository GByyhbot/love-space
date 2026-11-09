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
 * 状态栏配色：由网页把当前主题色直接交给原生去设，**不经过 Capacitor 的 StatusBar 插件**。
 *
 * <h3>为什么不用插件</h3>
 * 插件本身没问题（`StatusBar.setBackgroundColor` 就是 `window.setStatusBarColor()`），
 * 但它是从网页侧经 `window.Capacitor.Plugins.StatusBar` 调用的。本应用是
 * **远程加载**模式（`server.url` 指向线上站点），如果桥对象在页面脚本执行时还没就绪，
 * `_SB` 会永久为 null，后续所有调用被静默跳过 —— 表现就是状态栏一直停在
 * `styles.xml` 里写死的 `#FCF8F9`，换主题也不动。
 * 走原生直连就不存在这个问题：网页只传一个颜色串过来。
 *
 * <h3>为什么要把设置结果读回来</h3>
 * `setStatusBarColor` 在 API 35 起被标记废弃，targetSdk ≥ 35 时会变成空操作。
 * 本项目 targetSdk 停在 34（见 variables.gradle），理论上仍然有效；
 * 但不同厂商 ROM 不一定守规矩，所以设完立刻 `getStatusBarColor()` 读一次回值，
 * 对不上就在 logcat 里明确记一笔 —— 免得下次又靠猜。
 */
final class StatusBarTheme {
    private static final String TAG = "LoveSpace/StatusBar";

    private StatusBarTheme() {}

    /**
     * @param hex       形如 "#26322E"，必须 6 位；格式不对直接忽略（保留系统当前值）
     * @param lightIcons true = 状态栏图标用深色（浅色背景），false = 用浅色（深色背景）
     * @return 是否确实设进去了（读回值比对）
     */
    static boolean apply(Activity activity, String hex, boolean lightIcons) {
        if (activity == null || hex == null) return false;
        int color;
        try {
            String s = hex.trim();
            if (!s.startsWith("#")) s = "#" + s;
            if (s.length() != 7) return false;
            color = Color.parseColor(s);
        } catch (Throwable t) {
            Log.w(TAG, "颜色解析失败: " + hex, t);
            return false;
        }
        try {
            Window window = activity.getWindow();
            // 让系统把状态栏当成一块由我们着色的区域来画（而不是透出下层内容）
            window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            window.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS);
            window.setStatusBarColor(color);

            View decor = window.getDecorView();
            WindowInsetsControllerCompat c = WindowCompat.getInsetsController(window, decor);
            if (c != null) c.setAppearanceLightStatusBars(lightIcons);

            int back = window.getStatusBarColor();
            boolean ok = back == color;
            if (!ok) {
                Log.w(TAG, "setStatusBarColor 未生效：期望 " + Integer.toHexString(color)
                        + " 实际 " + Integer.toHexString(back));
            } else {
                Log.i(TAG, "状态栏已设为 " + hex + "，图标 " + (lightIcons ? "深色" : "浅色"));
            }
            return ok;
        } catch (Throwable t) {
            Log.w(TAG, "apply failed", t);
            return false;
        }
    }
}
