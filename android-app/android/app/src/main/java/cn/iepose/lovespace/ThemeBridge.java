package cn.iepose.lovespace;

import android.app.Activity;
import android.webkit.JavascriptInterface;

/**
 * 网页 → 原生的主题桥，挂在 {@code window.LoveTheme} 上。
 *
 * 只做一件事：告诉原生当前是不是深色主题，让原生切状态栏图标的深浅。
 * （状态栏底色不需要告诉原生 —— edge-to-edge 下它是透明的，网页自己画。）
 *
 * 走原生而不是 Capacitor 的 StatusBar 插件，是因为本应用远程加载页面，
 * 插件对象在页面里可能拿不到（详见 StatusBarTheme 的说明）。
 *
 * 安全性：只暴露一个布尔入参，不泄漏 Activity，不提供任意代码执行入口。
 */
final class ThemeBridge {

    private final Activity activity;

    ThemeBridge(Activity activity) {
        this.activity = activity;
    }

    /** @param dark 网页当前是否深色主题 */
    @JavascriptInterface
    public void setStatusBarMode(boolean dark) {
        StatusBarTheme.apply(activity, dark);
    }
}
