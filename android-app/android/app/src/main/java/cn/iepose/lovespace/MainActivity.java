package cn.iepose.lovespace;

import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;

import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.BridgeWebViewClient;

public class MainActivity extends BridgeActivity {
    private static final String TAG = "LoveSpace/Main";
    private static final String SPACE_URL = "https://love.yangyuhui.xyz/";
        private static final String SPACE_HOST = "love.yangyuhui.xyz";
        private static final String OFFLINE_PAGE = "file:///android_asset/lovespace-offline.html";
    private static final String PREFS = "lovespace_prefs";
    private static final String KEY_FIRST_LAUNCH = "first_launch_done";

    @Override
    protected void load() {
        super.load();
        // 保留 Capacitor 的所有 WebView 处理，只在主页面连不上时切到 APK 内置的恢复页。
        if (getBridge() != null) {
            getBridge().setWebViewClient(new RecoveryWebViewClient(getBridge()));
        }
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 注册 JS→原生桥（必须在 super.onCreate 之前，桥初始化时才会扫描）
        registerPlugin(PushBridge.class);
        super.onCreate(savedInstanceState);
        // ① 首次打开权限引导（通知权限等）
        requestFirstLaunchPermissions();
        // ② 启动原生 ntfy 长连接服务（topic 未写入时不启动，JS 登录后写入即生效）
        NtfyStreamService.start(this);
        // ③ WebView 下载支持：WebView 默认不处理二进制下载，APK 链接交给系统浏览器下载（应用内更新依赖）
        setupDownloadListener();
        // ④ 打开本地存储：聊天背景图按 media id 缓存进 IndexedDB，省得每次进聊天都重下一遍。
        //    WebSettings 的 database/domStorage 默认未必开启，不开的话 JS 侧 indexedDB.open 会直接失败。
        setupLocalStorage();
    }

    /**
     * 启用 WebView 的 DOM Storage 与数据库（IndexedDB）能力。
     * 失败只影响"背景图缓存"这一件事——app.js 里对 IndexedDB 不可用做了静默降级，不会崩。
     */
    private void setupLocalStorage() {
        try {
            if (getBridge() == null || getBridge().getWebView() == null) return;
            WebSettings settings = getBridge().getWebView().getSettings();
            settings.setDomStorageEnabled(true);
            settings.setDatabaseEnabled(true);
            settings.setAllowContentAccess(true);
            Log.i(TAG, "本地存储已启用（IndexedDB 可用）");
        } catch (Exception e) {
            Log.e(TAG, "启用本地存储失败", e);
        }
    }

    /**
     * 拦截 WebView 下载请求，转发系统浏览器。
     * 没有它点击 APK 链接会静默无反应（WebView 默认行为）。
     */
    private void setupDownloadListener() {
        try {
            if (getBridge() == null || getBridge().getWebView() == null) return;
            getBridge().getWebView().setDownloadListener((url, userAgent, contentDisposition, mimetype, contentLength) -> {
                try {
                    Intent i = new Intent(Intent.ACTION_VIEW);
                    i.setData(Uri.parse(url));
                    startActivity(i);
                    Log.i(TAG, "下载已转交系统浏览器: " + url);
                } catch (Exception e) {
                    Log.e(TAG, "无法打开下载链接", e);
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "设置下载监听失败", e);
        }
    }

    private String appVersion() {
        try {
            PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            return info.versionName == null ? "未知" : info.versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "未知";
        }
    }

    private String networkState() {
        ConnectivityManager manager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        if (manager == null) return "无法读取网络状态";
        Network network = manager.getActiveNetwork();
        if (network == null) return "未连接网络";
        NetworkCapabilities caps = manager.getNetworkCapabilities(network);
        if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            return "未检测到可用互联网";
        }
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            ? "网络可用，空间服务器暂时未响应"
            : "网络已连接，互联网连通性未确认";
    }

    private void showRecoveryPage(WebView view, String detail) {
        String url = OFFLINE_PAGE
            + "?version=" + Uri.encode(appVersion())
            + "&network=" + Uri.encode(networkState())
            + "&detail=" + Uri.encode(detail == null ? "连接失败" : detail);
        view.post(() -> view.loadUrl(url));
    }

    private final class RecoveryWebViewClient extends BridgeWebViewClient {
        RecoveryWebViewClient(Bridge bridge) {
            super(bridge);
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            return handleRecoveryAction(view, request.getUrl())
                || super.shouldOverrideUrlLoading(view, request);
        }

        @SuppressWarnings("deprecation")
        @Override
        public boolean shouldOverrideUrlLoading(WebView view, String url) {
            return handleRecoveryAction(view, Uri.parse(url))
                || super.shouldOverrideUrlLoading(view, url);
        }

        private boolean handleRecoveryAction(WebView view, Uri uri) {
            if (!"lovespace".equals(uri.getScheme())) return false;
            if ("retry".equals(uri.getHost())) {
                view.loadUrl(SPACE_URL);
                return true;
            }
            if ("browser".equals(uri.getHost())) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(SPACE_URL)));
                } catch (Exception e) {
                    Log.w(TAG, "没有可用的浏览器", e);
                }
                return true;
            }
            return false;
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            super.onReceivedError(view, request, error);
            if (request.isForMainFrame()) {
                CharSequence message = error == null ? null : error.getDescription();
                String description = message == null ? "无法连接服务器" : message.toString();
                showRecoveryPage(view, description);
            }
        }

        @Override
        public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
            super.onReceivedHttpError(view, request, response);
            if (request.isForMainFrame() && response.getStatusCode() >= 500) {
                showRecoveryPage(view, "服务器暂时不可用（HTTP " + response.getStatusCode() + "）");
            }
        }
    }

    /**
     * 返回键：优先在 WebView 历史里后退，实现二级页逐级返回；没有历史才退出应用。
     * Capacitor 的 BridgeActivity 未覆写返回键，默认行为是直接 finish()——
     * 这会导致在任意二级页按返回键直接退出 App（验收清单 F-1 判定为失败项）。
     */
    @Override
    public void onBackPressed() {
        try {
            WebView view = getBridge() == null ? null : getBridge().getWebView();
            if (view != null && view.canGoBack()) {
                view.goBack();
                return;
            }
        } catch (Exception e) {
            Log.w(TAG, "返回键处理异常，回落默认行为", e);
        }
        super.onBackPressed();
    }

    @Override
    public void onResume() {
        super.onResume();
        NtfyStreamService.appForeground = true;
    }

    @Override
    public void onPause() {
        super.onPause();
        NtfyStreamService.appForeground = false;
    }

    /**
     * 首次打开权限引导：请求通知权限（Android 13+），用 SharedPreferences 标记已引导。
     * 通知权限由 WebView 侧请求；后台权限由用户在提醒设置中主动开启。
     */
    private void requestFirstLaunchPermissions() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (prefs.getBoolean(KEY_FIRST_LAUNCH, false)) {
            return;
        }
        prefs.edit().putBoolean(KEY_FIRST_LAUNCH, true).apply();
        // 通知权限（Android 13+）：通过 Capacitor LocalNotifications 插件在 JS 层请求
        // 这里不做原生请求，由 app.js 的 initNotify() 在 boot 时调用
        Log.i(TAG, "首次启动，权限引导标记已设置（通知权限由 WebView 侧请求）");
    }
}
