package cn.iepose.lovespace;

import android.app.Activity;
import android.webkit.JavascriptInterface;

/**
 * 网页 → 原生的主题桥，挂在 {@code window.LoveTheme} 上。
 *
 * 只做一件事：把状态栏染成网页当前主题的颜色。
 * 走这里而不是 Capacitor 的 StatusBar 插件，是因为本应用远程加载页面，
 * 插件对象可能在该页面里拿不到（详见 StatusBarTheme 的说明）。
 *
 * 安全性：只暴露两个入参的只读设置方法，不泄漏 Activity，不提供任意代码执行入口。
 * 页面来自自家的 https 站点。
 */
final class ThemeBridge {

    private final Activity activity;

    ThemeBridge(Activity activity) {
        this.activity = activity;
    }

    /**
     * @param hex        六位十六进制颜色，如 "#26322E"
     * @param lightIcons true = 浅色背景用深色图标
     * @return 是否确实生效
     */
    @JavascriptInterface
    public boolean setStatusBar(String hex, boolean lightIcons) {
        return StatusBarTheme.apply(activity, hex, lightIcons);
    }
}
