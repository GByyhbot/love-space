package cn.iepose.lovespace;

import android.app.Activity;
import android.os.Build;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.webkit.WebView;

import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsAnimationCompat;
import androidx.core.view.WindowInsetsCompat;

import java.util.List;
import java.util.Locale;

/**
 * 窗口诊断探针 —— **只读，不修改任何窗口标志**。
 *
 * 为什么要有它：键盘避让这块，我们前后改了两轮都是「先改代码 → 上真机 → 发现假设错了 →
 * 回退」，两次都被同一个未经验证的前提带偏（"关掉 LAYOUT_FULLSCREEN 才能 adjustResize"）。
 * 这次先把真机事实采齐，再决定要不要动窗口。
 *
 * 它要回答五个问题：
 *  ① 当前窗口的标志位到底是什么（LAYOUT_FULLSCREEN 还在不在）
 *  ② statusBars / navigationBars / systemGestures 各多高（决定关掉全屏后要补多高的色带）
 *  ③ 键盘弹起/收起时，decor 与 WebView 的尺寸到底变不变
 *  ④ WebView 父容器旁路读到的 IME inset，和 WebView 自身拿到的是否一致
 *     （Chromium 会吃掉一部分，这可能正是"网页算不出键盘高"的真正原因）
 *  ⑤ WindowInsetsAnimation 在键盘动画期间是否每帧回调（决定能不能做平滑跟随）
 *
 * 用法：
 *   adb logcat -c && adb logcat -s LoveSpace/Win
 *   然后打开 App → 进聊天页 → 点输入框弹出键盘 → 等 2 秒 → 收起 → 再抓一段
 *
 * 全程只打日志。装上去不改任何现有表现，可以放心在正式包上跑一次。
 */
final class WindowProbe {
    static final String TAG = "LoveSpace/Win";

    /**
     * 总开关。发正式包前改回 false，避免刷屏。
     *
     * 🔴 2026-11-09：实测发现每帧一条 Log.i 在键盘动画里就是几十条输出，
     * 与逐帧改布局叠加会明显掉帧。**探针只能单独用于诊断，不能和逐帧改动同时开**。
     */
    static final boolean ENABLED = false;

    private WindowProbe() {}

    static void install(final Activity activity, final WebView webView) {
        if (!ENABLED) return;
        try {
            final Window window = activity.getWindow();
            final View decor = window.getDecorView();
            /* 🔴 监听必须挂 decor，不能挂 WebView 父容器：
               KeyboardAvoidance 在父容器上也挂了同名监听，后挂的会把先挂的顶掉，
               两者不能共用同一个 View。decor 是 insets 的第一站，在这里旁路读最准，
               而且不影响下面的子 View 继续收到真实 insets。
               🔴 更不能挂 WebView 自身 —— 会顶掉 Chromium 的 onApplyWindowInsets，
               env(safe-area-inset-*) 全部归零。 */
            dumpEnvironment(activity, decor);
            installWatchers(decor, webView);
            Log.i(TAG, "===== 探针就绪：请点输入框弹出键盘，2 秒后收起 =====");
        } catch (Throwable t) {
            Log.w(TAG, "install failed", t);
        }
    }

    private static void dumpEnvironment(Activity activity, View decor) {
        Log.i(TAG, "===== 环境 =====");
        Log.i(TAG, "Android " + Build.VERSION.RELEASE + " / API " + Build.VERSION.SDK_INT
                + " / " + Build.MANUFACTURER + " " + Build.MODEL);
        Log.i(TAG, "targetSdk=" + activity.getApplicationInfo().targetSdkVersion
                + " compileSdk=" + Build.VERSION.SDK_INT);

        int fl = decor.getSystemUiVisibility();
        StringBuilder sb = new StringBuilder();
        if ((fl & View.SYSTEM_UI_FLAG_LAYOUT_STABLE) != 0) sb.append("LAYOUT_STABLE ");
        if ((fl & View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN) != 0) sb.append("LAYOUT_FULLSCREEN ");
        if ((fl & View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION) != 0) sb.append("LAYOUT_HIDE_NAV ");
        if ((fl & View.SYSTEM_UI_FLAG_FULLSCREEN) != 0) sb.append("FULLSCREEN ");
        if ((fl & View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) != 0) sb.append("HIDE_NAV ");
        if ((fl & View.SYSTEM_UI_FLAG_IMMERSIVE) != 0) sb.append("IMMERSIVE ");
        if ((fl & View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY) != 0) sb.append("IMMERSIVE_STICKY ");
        Log.i(TAG, "systemUiVisibility=0x" + Integer.toHexString(fl) + " → " + sb);

        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsets rwi = decor.getRootWindowInsets();
            if (rwi != null) {
                Log.i(TAG, "statusBars=" + rwi.getInsets(WindowInsets.Type.statusBars())
                        + " navBars=" + rwi.getInsets(WindowInsets.Type.navigationBars())
                        + " systemGestures=" + rwi.getInsets(WindowInsets.Type.systemGestures())
                        + " ime=" + rwi.getInsets(WindowInsets.Type.ime()));
            }
        }
    }

    private static void installWatchers(final View decor, final WebView webView) {
        final int[] last = { -1, -1 };

        ViewCompat.setOnApplyWindowInsetsListener(decor, new androidx.core.view.OnApplyWindowInsetsListener() {
            @Override public WindowInsetsCompat onApplyWindowInsets(View v, WindowInsetsCompat insets) {
                int ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom;
                int top = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top;
                if (ime != last[0] || top != last[1]) {
                    last[0] = ime; last[1] = top;
                    Log.i(TAG, "[decor] ime=" + ime + " statusTop=" + top
                            + " | decor=" + decor.getWidth() + "x" + decor.getHeight()
                            + " wv=" + (webView == null ? "-" : webView.getWidth() + "x" + webView.getHeight()));
                }
                return insets;   /* 原样下发，子 View 继续收到真实 insets */
            }
        });

        ViewCompat.setWindowInsetsAnimationCallback(decor,
                new WindowInsetsAnimationCompat.Callback(
                        WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                    @Override public WindowInsetsCompat onProgress(WindowInsetsCompat insets,
                                                                   List<WindowInsetsAnimationCompat> running) {
                        for (WindowInsetsAnimationCompat a : running) {
                            if (a.getTypeMask() == WindowInsetsCompat.Type.ime()) {
                                Log.i(TAG, "[anim] ime="
                                        + insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
                                        + " progress=" + String.format(Locale.US, "%.2f", a.getInterpolatedFraction())
                                        + " wvH=" + (webView == null ? "-" : webView.getHeight()));
                            }
                        }
                        return insets;
                    }
                });
    }
}
