package cn.iepose.lovespace;

import android.app.Activity;
import android.os.Build;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.webkit.WebView;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsAnimationCompat;
import androidx.core.view.WindowInsetsCompat;

import java.util.List;

/**
 * 键盘避让的「原生缩容器」方案 —— 让 WebView 的**布局视口真的变小**，而不是网页自己算高度补 padding。
 *
 * <h3>为什么这条路是根治</h3>
 * 现在的做法是：窗口尺寸全程不动，原生把 IME 高度经 {@code __kbSetNative()} 喂给网页，
 * 网页用 {@code --kb-h} / {@code --kb-shift} 自己把内容顶上去。这套能跑，但有三个结构性毛病：
 * <ol>
 *   <li>两类机器行为不同（A 类视口会缩、B 类不会），网页端必须按机型分流，
 *       判据（{@code kbShrink}）一旦判错就双份位移或完全不位移；</li>
 *   <li>{@code 100dvh} / {@code vh} / {@code position:fixed} 拿到的仍然是"键盘占着的那块"，
 *       任何依赖视口单位的新样式都得额外补偿；</li>
 *   <li>表情 dock 与 ⊕ 面板要靠 {@code dockHold} 和键盘反向同步高度，纯属在补第一条件的债。</li>
 * </ol>
 *
 * 反过来，只要让 WebView 的布局视口跟着键盘缩，Chromium 自己就会把
 * {@code innerHeight} / {@code visualViewport} / {@code dvh} 全部算对 —— 也就是
 * **主人机（A 类）今天已经在跑的那条路径**，网页端零改动、且是逐字节等价的那套已验证逻辑。
 *
 * <h3>怎么保住沉浸式</h3>
 * 关键点：不用 {@code adjustResize}（targetSdk 35 强制 edge-to-edge 后它不生效），
 * 也不碰 {@code LAYOUT_FULLSCREEN}（一碰就丢沉浸式状态栏）。
 * 只用 {@code setDecorFitsSystemWindows(false)} 声明"装饰空间由我自己处理"，
 * 然后**只把 IME 那一侧的 inset 写成父容器的 paddingBottom**：
 * 状态栏仍然盖在内容上（沉浸式不变），键盘那一块则真实地从布局里扣掉。
 *
 * <h3>为什么必须走动画回调</h3>
 * 普通 insets 分发只在键盘动画的首尾给值，中间那 ~300ms 网页拿到的是旧值；
 * 一次性 resize 又会在动画结束后才发生，新腾出的区域先露一帧底色（历史上踩过的"黑帧"）。
 * 用 {@link WindowInsetsAnimationCompat} 逐帧写 padding，缩容与键盘上升同帧推进，
 * 全程没有"先空一块"的中间态。
 *
 * <h3>风险与开关</h3>
 * 逐帧改布局意味着每帧一次 Chromium relayout，低端机上可能掉帧。
 * 所以整块逻辑由 {@link #ENABLED} 控制，关闭时行为与改造前完全一致（走老的
 * {@code setupImeHeightBridge}）。真机验证通过后再把老桥摘掉。
 */
final class KeyboardAvoidance {
    private static final String TAG = "LoveSpace/Kb";

    /**
     * 总开关。<b>打开时老的原生高度桥不再安装，两者只能二选一</b>——
     * 同时生效会让网页同时收到"视口缩了"和"原生给了高度"，判据一旦在首帧判错就是双份位移。
     *
     * 🔴 2026-11-09 真机实测：<b>这个方案会剧烈抖动，已关闭</b>。
     * 原因是两套布局驱动同时在工作且不同步：原生每帧 setPadding 缩 WebView，
     * 网页端 syncKeyboard 每帧据 viewShrink 改 --kb-shift（壁纸补偿），
     * 两次 relayout 的时序错开 → 视觉上就是来回拉扯。
     * 要重试必须先把网页端的补偿摘掉（让只有一方动），否则一定再抖。
     */
    static final boolean ENABLED = false;

    private KeyboardAvoidance() {}

    /** @return true 表示已接管键盘避让，调用方不要再装老的 IME 高度桥 */
    static boolean install(final Activity activity, final WebView webView) {
        if (!ENABLED) return false;
        if (Build.VERSION.SDK_INT < 30) return false;          // WindowInsetsAnimation 需要 API 30
        if (webView == null || !(webView.getParent() instanceof View)) return false;
        try {
            final Window window = activity.getWindow();
            final View parent = (View) webView.getParent();

            // 声明装饰空间自己处理：状态栏仍叠在内容上（沉浸式不变），但系统不再替我们决定布局。
            WindowCompat.setDecorFitsSystemWindows(window, false);

            final int[] lastPx = { -1 };

            ViewCompat.setOnApplyWindowInsetsListener(parent,
                    new androidx.core.view.OnApplyWindowInsetsListener() {
                        @Override public WindowInsetsCompat onApplyWindowInsets(View v, WindowInsetsCompat insets) {
                            int ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom;
                            applyPadding(v, ime, lastPx);
                            /* 只把 IME 那一侧"吃掉"，其余（状态栏/导航栏）原样下发，
                               否则 env(safe-area-inset-*) 会一起归零，聊天页顶部会被状态栏压住。 */
                            return new WindowInsetsCompat.Builder(insets)
                                    .setInsets(WindowInsetsCompat.Type.ime(), Insets.NONE)
                                    .build();
                        }
                    });

            ViewCompat.setWindowInsetsAnimationCallback(parent,
                    new WindowInsetsAnimationCompat.Callback(
                            WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                        @Override public WindowInsetsCompat onProgress(WindowInsetsCompat insets,
                                                                       List<WindowInsetsAnimationCompat> running) {
                            for (WindowInsetsAnimationCompat a : running) {
                                if (a.getTypeMask() == WindowInsetsCompat.Type.ime()) {
                                    applyPadding(parent, insets.getInsets(WindowInsetsCompat.Type.ime()).bottom, lastPx);
                                    break;
                                }
                            }
                            return insets;
                        }

                        /* 动画收尾时以系统的最终值为准，避免累积误差留一条 1~2px 的缝 */
                        @Override public void onEnd(WindowInsetsAnimationCompat animation) {
                            if (animation.getTypeMask() == WindowInsetsCompat.Type.ime()) {
                                WindowInsetsCompat wi = ViewCompat.getRootWindowInsets(parent);
                                if (wi != null) {
                                    applyPadding(parent, wi.getInsets(WindowInsetsCompat.Type.ime()).bottom, lastPx);
                                }
                            }
                        }
                    });

            Log.i(TAG, "原生缩容器已接管键盘避让（API " + Build.VERSION.SDK_INT + "）"
                    + " parent=" + parent.getClass().getName()
                    + " " + parent.getWidth() + "x" + parent.getHeight()
                    + " wv=" + webView.getWidth() + "x" + webView.getHeight());
            return true;
        } catch (Throwable t) {
            Log.w(TAG, "install failed, 回退到老的 IME 高度桥", t);
            return false;
        }
    }

    /** 写 paddingBottom。值没变就跳过，动画每帧都会进来，去重能省掉大量无意义的 relayout。 */
    private static void applyPadding(View v, int px, int[] lastPx) {
        if (px == lastPx[0]) return;
        lastPx[0] = px;
        v.setPadding(v.getPaddingLeft(), v.getPaddingTop(), v.getPaddingRight(), px);
    }
}
