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

import java.net.URL;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.HttpsURLConnection;

import com.getcapacitor.Bridge;
import com.getcapacitor.BridgeActivity;
import com.getcapacitor.BridgeWebViewClient;

public class MainActivity extends BridgeActivity {
    private static final String TAG = "LoveSpace/Main";
    // 多线路候选：均指向同一后端。不同域名的登录态(cookie)相互独立，
    // 故优先粘住上次可用线路，仅在它挂掉/明显过慢时才切换，避免频繁掉登录。
    private static final String[] SPACE_URLS = {
        "https://love.yangyuhui.xyz/",
        "https://love-space.iepose.cn/",
        "https://love.350921.xyz/",
        "https://love-space.yangyuhui.xyz:4019/",
        "https://fn.350921.xyz:1314/",
        "https://yangyuhui86.top:1314/"
    };
    private static final String SPACE_URL = SPACE_URLS[0];
    private static final String OFFLINE_PAGE = "file:///android_asset/lovespace-offline.html";
    private static final String PREFS = "lovespace_prefs";
    private static final String KEY_FIRST_LAUNCH = "first_launch_done";
    private static final String KEY_BEST_URL = "best_url";
    private static final int PROBE_TIMEOUT_MS = 3000;
    private volatile String currentUrl = SPACE_URL;
    private volatile boolean probing = false;
    private final Set<String> attemptedUrls = Collections.synchronizedSet(new HashSet<String>());

    @Override
    protected void load() {
        super.load();
        // 保留 Capacitor 的所有 WebView 处理，只在主页面连不上时切到 APK 内置的恢复页。
        if (getBridge() != null) {
            getBridge().setWebViewClient(new RecoveryWebViewClient(getBridge()));
            // 上次记住的最优线路：直接用它（保持登录态），首启用默认线路
            String remembered = prefs().getString(KEY_BEST_URL, null);
            if (remembered == null || remembered.isEmpty()) remembered = SPACE_URL;
            currentUrl = remembered;
            WebView wv = getBridge().getWebView();
            if (wv != null && !remembered.equals(SPACE_URL)) {
                wv.loadUrl(remembered); // 覆盖 super.load() 的默认地址
            }
            // 后台并行探测各线路，按需切到最快可用线路
            startUrlProbe(false);
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
                attemptedUrls.clear();
                startUrlProbe(true);
                return true;
            }
            if ("browser".equals(uri.getHost())) {
                try {
                    String target = currentUrl != null ? currentUrl : SPACE_URL;
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(target)));
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
                failover(view, description);
            }
        }

        @Override
        public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
            super.onReceivedHttpError(view, request, response);
            if (request.isForMainFrame() && response.getStatusCode() >= 500) {
                failover(view, "服务器暂时不可用（HTTP " + response.getStatusCode() + "）");
            }
        }

        @Override
        public void onPageFinished(WebView view, String url) {
            super.onPageFinished(view, url);
            // 真正的应用页面加载成功 → 重置已尝试线路，供下次导航重新择优
            if (url != null && !url.startsWith("file:")) attemptedUrls.clear();
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

    private SharedPreferences prefs() {
        return getSharedPreferences(PREFS, MODE_PRIVATE);
    }

    private void saveBest(String url) {
        try {
            prefs().edit().putString(KEY_BEST_URL, url).apply();
        } catch (Exception e) {
            Log.w(TAG, "保存最优线路失败", e);
        }
    }

    private static int indexOf(String[] arr, String v) {
        if (v == null) return -1;
        for (int i = 0; i < arr.length; i++) if (arr[i].equals(v)) return i;
        return -1;
    }

    /**
     * 后台并行探测所有线路，按需切换到最快可用线路。
     * force=true（离线页「重试」）时强制重新择优；否则保留上次线路（免重登），
     * 仅当它不可达或明显过慢时才切换。
     */
    private void startUrlProbe(final boolean force) {
        if (probing) return;
        probing = true;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    long[] lat = probeAll();
                    WebView wv = getBridge() == null ? null : getBridge().getWebView();
                    if (wv == null) return;
                    int bestIdx = -1;
                    long bestMs = Long.MAX_VALUE;
                    for (int i = 0; i < lat.length; i++) {
                        if (lat[i] >= 0 && lat[i] < bestMs) { bestMs = lat[i]; bestIdx = i; }
                    }
                    if (bestIdx < 0) {
                        wv.post(new Runnable() { public void run() { showRecoveryPage(wv, "所有线路均无法连接"); } });
                        return;
                    }
                    final String best = SPACE_URLS[bestIdx];
                    int ci = indexOf(SPACE_URLS, currentUrl);
                    long curMs = ci >= 0 ? lat[ci] : -1;
                    // 上次线路可用且不算太慢（<= 最优*2+400ms）→ 保留，避免换域重登
                    boolean keepCurrent = !force && curMs >= 0 && curMs <= bestMs * 2 + 400;
                    if (keepCurrent) {
                        saveBest(currentUrl);
                        return;
                    }
                    if (!best.equals(currentUrl)) {
                        currentUrl = best;
                        saveBest(best);
                        wv.post(new Runnable() { public void run() { attemptedUrls.clear(); wv.loadUrl(best); } });
                    } else {
                        saveBest(best);
                    }
                } catch (Exception e) {
                    Log.w(TAG, "线路探测异常", e);
                } finally {
                    probing = false;
                }
            }
        }, "url-probe").start();
    }

    /** 主页面加载失败时，自动切到「未尝试过且最快可达」的线路；全部试完才显示离线页。 */
    private void failover(WebView view, String reason) {
        if (currentUrl != null) attemptedUrls.add(currentUrl);
        if (probing) return; // 探测进行中，交给探测结果处理
        final String why = reason == null ? "连接失败" : reason;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    long[] lat = probeAll();
                    int bestIdx = -1;
                    long bestMs = Long.MAX_VALUE;
                    for (int i = 0; i < lat.length; i++) {
                        String u = SPACE_URLS[i];
                        if (lat[i] >= 0 && !attemptedUrls.contains(u) && lat[i] < bestMs) { bestMs = lat[i]; bestIdx = i; }
                    }
                    if (bestIdx < 0) {
                        view.post(new Runnable() { public void run() { showRecoveryPage(view, "所有线路均无法连接（" + why + "）"); } });
                        return;
                    }
                    final String next = SPACE_URLS[bestIdx];
                    currentUrl = next;
                    saveBest(next);
                    view.post(new Runnable() { public void run() { attemptedUrls.clear(); view.loadUrl(next); } });
                } catch (Exception e) {
                    Log.w(TAG, "线路切换异常", e);
                }
            }
        }, "url-failover").start();
    }

    /** 并行探测全部线路，返回与 SPACE_URLS 对齐的延迟数组（不可达为 -1）。 */
    private long[] probeAll() {
        final long[] lat = new long[SPACE_URLS.length];
        Arrays.fill(lat, -1);
        final CountDownLatch latch = new CountDownLatch(SPACE_URLS.length);
        for (int i = 0; i < SPACE_URLS.length; i++) {
            final int idx = i;
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        lat[idx] = probeLatency(SPACE_URLS[idx]);
                    } catch (Throwable ignored) {
                    } finally {
                        latch.countDown();
                    }
                }
            }, "probe-" + idx);
            t.setDaemon(true);
            t.start();
        }
        try {
            latch.await(PROBE_TIMEOUT_MS + 1500L, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return lat;
    }

    /** 对单条线路发一次 GET /api/status，返回耗时毫秒；不可达/非 2xx-3xx 返回 -1。 */
    private long probeLatency(String base) {
        HttpsURLConnection conn = null;
        try {
            URL url = new URL(new URL(base), "api/status");
            conn = (HttpsURLConnection) url.openConnection();
            conn.setConnectTimeout(PROBE_TIMEOUT_MS);
            conn.setReadTimeout(PROBE_TIMEOUT_MS);
            conn.setUseCaches(false);
            conn.setRequestMethod("GET");
            conn.setInstanceFollowRedirects(true);
            long t0 = System.nanoTime();
            int code = conn.getResponseCode();
            long ms = (System.nanoTime() - t0) / 1_000_000L;
            return (code >= 200 && code < 400) ? ms : -1;
        } catch (Exception e) {
            return -1;
        } finally {
            if (conn != null) {
                try { conn.disconnect(); } catch (Exception ignored) {}
            }
        }
    }
}
