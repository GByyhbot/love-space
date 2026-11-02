package cn.iepose.lovespace;

import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.webkit.CookieManager;
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
        "https://love-space.yangyuhui.xyz:4019/"
    };
    private static final String SPACE_URL = SPACE_URLS[0];
    /* 与 SPACE_URLS 一一对应的展示名，设置页「链路检测」用。 */
    private static final String[] ROUTE_NAMES = {
        "Cloudflare 隧道",
        "节点小宝",
        "腾讯云 CloudBase",
        "Lucky 直连"
    };
    private static final String OFFLINE_PAGE = "file:///android_asset/lovespace-offline.html";
    private static final String PREFS = "lovespace_prefs";
    private static final String KEY_FIRST_LAUNCH = "first_launch_done";
    private static final String KEY_BEST_URL = "best_url";
    private static final String KEY_SESSION = "session_token";
    private static final String SESSION_COOKIE = "love_session";
    // 公网链路（Cloudflare Tunnel 绕海外边缘）实测 /api/status 要 1.9~2.8s，
    // 3s 超时在手机 5G/VPN 下必然全部超时 → 「所有线路均无法连接」。放宽到 8s。
    private static final int PROBE_TIMEOUT_MS = 8000;
    /* 启动看门狗：正常线路 133ms~2.3s 就能把页面拉出来，超过 6 秒还没动静才算「慢」。
       在此之前一律不探测、不换线路 —— 从哪条链接进来就用哪条。 */
    private static final int SLOW_LOAD_MS = 6000;
    private final Handler sessionHandler = new Handler(Looper.getMainLooper());
    /* 页面迟迟没出来时的兜底：到点还没 pageLoaded，才去探测别的线路并择优切换。
       页面一旦加载成功就什么也不做——这条线路就是用户要用的那条。 */
    private final Runnable slowLoadWatchdog = new Runnable() {
        @Override public void run() {
            if (pageLoaded || probing) return;
            Log.i(TAG, "启动 " + SLOW_LOAD_MS + "ms 仍未加载出页面，转为探测并择优");
            startUrlProbe(true);
        }
    };
    private final Runnable sessionTick = new Runnable() {
        @Override public void run() {
            try {
                WebView wv = getBridge() == null ? null : getBridge().getWebView();
                if (wv != null) captureAndShareSession(wv.getUrl());
            } catch (Exception ignored) {}
            sessionHandler.postDelayed(this, 6000);
        }
    };
    private volatile String currentUrl = SPACE_URL;
    private volatile boolean probing = false;
    /* 主帧最近一次是否成功加载出应用页面。探测线程全超时（公网链路慢）时，
       只要页面已经加载成功就绝不能抢屏成离线页——浏览器无超时都能打开的线路，
       WebView 同样能打开，只是探测的 3~8 秒预算不够而已。 */
    private volatile boolean pageLoaded = false;
    private final Set<String> attemptedUrls = Collections.synchronizedSet(new HashSet<String>());
    /* 当前已绑定的物理网卡；null = 未绑定（走系统默认网络，可能被组网隧道接管） */
    private volatile Network tunnelBoundNetwork = null;
    /* 绑定物理网络后若所有线路反而全挂（存在「只有隧道能出网」的网络），
       解绑回退一次并置此标志，本次运行内不再尝试绑定。 */
    private volatile boolean tunnelBypassOff = false;

    @Override
    protected void load() {
        super.load();
        // 保留 Capacitor 的所有 WebView 处理，只在主页面连不上时切到 APK 内置的恢复页。
        if (getBridge() != null) {
            getBridge().setWebViewClient(new RecoveryWebViewClient(getBridge()));
            // 上次记住的最优线路：直接用它（保持登录态），首启用默认线路
            CookieManager.getInstance().setAcceptCookie(true);
            String remembered = prefs().getString(KEY_BEST_URL, null);
            if (remembered == null || remembered.isEmpty()) remembered = SPACE_URL;
            currentUrl = remembered;
            WebView wv = getBridge().getWebView();
            if (wv != null && !remembered.equals(SPACE_URL)) {
                // super.load() 已经把默认线路发了一发，这里先掐掉，别白等它。
                wv.stopLoading();
                seedSessionForHost(remembered); // 先把登录 cookie 种到这条线路
                wv.loadUrl(remembered); // 覆盖 super.load() 的默认地址
            }
            // 启动不再主动探测：从哪条线路进来（上次记住的那条）就用哪条。
            // 只有「迟迟加载不出来」或「加载失败」才值得花时间去测别的线路。
            sessionHandler.removeCallbacks(slowLoadWatchdog);
            sessionHandler.postDelayed(slowLoadWatchdog, SLOW_LOAD_MS);
            // 定期把登录 cookie 同步到全部线路，切域免重登
            sessionHandler.removeCallbacks(sessionTick);
            sessionHandler.postDelayed(sessionTick, 6000);
        }
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 注册 JS→原生桥（必须在 super.onCreate 之前，桥初始化时才会扫描）
        registerPlugin(PushBridge.class);
        registerPlugin(LinkBridge.class);
        // ⓪ 把本进程绑到物理网卡，绕开节点小宝一类的组网隧道。
        //    必须赶在 super.onCreate 之前：BridgeActivity.onCreate 内部就会调 load() 装载页面，
        //    等 super 返回再绑，首个页面请求已经走过隧道了。
        bypassTunnelNetwork();
        super.onCreate(savedInstanceState);
        // ⓪' 网络变化（切 WiFi/流量、隧道开关）时重新择优绑定
        watchNetworkChange();
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

    /* ── 隔绝组网隧道（节点小宝 / Tailscale / 任意 VpnService）───────────────
       节点小宝的「组网」底层就是 VpnService + Tailscale 那套路由与防火墙：
       它把 100.64.0.0/10 当成自己的私网，并在 ts-input 链里对「来源属于该段、
       却不是从本隧道进来的包」直接 DROP。而家里宽带正好在运营商 CGNAT
       （100.64.0.0/10）后面，于是 App 的请求、DNS 解析、回程都可能被它拦掉 ——
       表现就是「某条线路本该最快，却始终连不上」。
       这里不做任何对抗，只是把本进程绑定到物理网卡（WiFi / 蜂窝 / 有线），
       让网络请求不经过 VPN 转发。任何一步失败都静默降级，绝不影响正常使用。 */

    private void bypassTunnelNetwork() {
        if (tunnelBypassOff) return;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return; // bindProcessToNetwork 需 API 23
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            if (cm == null) return;
            // 没开组网隧道就别多事。1.6.3 是无条件绑定物理网卡，个别机型/网络下会
            // 影响分应用代理与 IPv6 出网，反而让部分线路探测不到 —— 现在先确认真的
            // 存在 VPN 传输，不存在就把进程还回系统默认。
            if (!hasVpnTransport(cm)) {
                if (tunnelBoundNetwork != null) {
                    cm.bindProcessToNetwork(null);
                    tunnelBoundNetwork = null;
                }
                return;
            }
            Network target = pickPhysicalNetwork(cm);
            if (target == null) return; // 只有隧道、没有物理网卡 → 保持系统默认行为
            if (target.equals(tunnelBoundNetwork)) return;
            if (cm.bindProcessToNetwork(target)) {
                tunnelBoundNetwork = target;
                Log.i(TAG, "本进程已绑定物理网络，绕过组网隧道");
            }
        } catch (Throwable e) {
            Log.w(TAG, "绑定物理网络失败（不影响使用）", e);
        }
    }

    /** 当前是否存在 VPN 类型的网络（节点小宝 / 任意 VpnService）。 */
    private boolean hasVpnTransport(ConnectivityManager cm) {
        for (Network n : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(n);
            if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return true;
        }
        return false;
    }

    /** 挑一张能上网的物理网卡：优先「已验证连通」，其次任意带 INTERNET 能力的物理网卡。 */
    private Network pickPhysicalNetwork(ConnectivityManager cm) {
        Network fallback = null;
        for (Network n : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(n);
            if (caps == null) continue;
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue; // 组网隧道，跳过
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
            boolean physical = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                || caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
            if (!physical) continue;
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return n;
            if (fallback == null) fallback = n;
        }
        return fallback;
    }

    /** 网络变化时重新择优，避免一直绑在一张已经消失的网卡上。 */
    private void watchNetworkChange() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return;
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            if (cm == null) return;
            NetworkRequest req = new NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build();
            cm.registerNetworkCallback(req, new ConnectivityManager.NetworkCallback() {
                @Override public void onAvailable(Network network) {
                    bypassTunnelNetwork();
                }
                @Override public void onLost(Network network) {
                    Network bound = tunnelBoundNetwork;
                    if (bound != null && bound.equals(network)) tunnelBoundNetwork = null;
                    bypassTunnelNetwork();
                }
                @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                    bypassTunnelNetwork();
                }
            });
        } catch (Throwable e) {
            Log.w(TAG, "注册网络监听失败（不影响使用）", e);
        }
    }

    /**
     * 解除物理网络绑定。仅在所有线路都探测失败时作为兜底调用：
     * 万一用户的网络环境「只有隧道能出网」，绑物理网卡反而更差，此时退回系统默认。
     */
    private boolean releaseTunnelBinding() {
        if (tunnelBoundNetwork == null) return false;
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false;
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            boolean ok = cm.bindProcessToNetwork(null);
            if (ok) {
                tunnelBoundNetwork = null;
                tunnelBypassOff = true;
                Log.w(TAG, "所有线路不通，已解除物理网络绑定并回退系统默认网络");
            }
            return ok;
        } catch (Throwable e) {
            Log.w(TAG, "解除物理网络绑定失败", e);
            return false;
        }
    }

    private void showRecoveryPage(WebView view, String detail) {
        pageLoaded = false;
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
                pageLoaded = false;
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
            // 真正的应用页面加载成功 → 重置已尝试线路，并抓取登录 cookie 同步到全部线路
            if (url != null && !url.startsWith("file:")) {
                pageLoaded = true;
                attemptedUrls.clear();
                // 页面出来了就不用再探测了，取消启动看门狗
                sessionHandler.removeCallbacks(slowLoadWatchdog);
                captureAndShareSession(url);
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

    @Override
    public void onDestroy() {
        try { sessionHandler.removeCallbacks(sessionTick); } catch (Exception ignored) {}
        try { sessionHandler.removeCallbacks(slowLoadWatchdog); } catch (Exception ignored) {}
        super.onDestroy();
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

    /* ── 供 LinkBridge（设置页「链路检测」）调用 ─────────────────────────── */

    /** 当前正在使用的线路地址。 */
    public String currentRoute() {
        return currentUrl;
    }

    /** 该地址是否属于内置候选线路（LinkBridge 用它拦截任意 URL）。 */
    public boolean isKnownRoute(String url) {
        return indexOf(SPACE_URLS, url) >= 0;
    }

    /**
     * 现场探测全部线路，供设置页展示。会阻塞至多约 16 秒，**必须在后台线程调用**。
     * 返回 [{name,url,ms,current,best}]，ms 为 -1 表示不可达。
     */
    public org.json.JSONArray probeRoutesForUi() {
        long[] lat = probeAll();
        String cur = currentUrl;
        int bestIdx = -1;
        long bestMs = Long.MAX_VALUE;
        for (int i = 0; i < lat.length; i++) {
            if (lat[i] >= 0 && lat[i] < bestMs) { bestMs = lat[i]; bestIdx = i; }
        }
        org.json.JSONArray arr = new org.json.JSONArray();
        for (int i = 0; i < SPACE_URLS.length; i++) {
            org.json.JSONObject o = new org.json.JSONObject();
            try {
                o.put("url", SPACE_URLS[i]);
                o.put("name", i < ROUTE_NAMES.length ? ROUTE_NAMES[i] : SPACE_URLS[i]);
                o.put("ms", lat[i]);
                o.put("current", SPACE_URLS[i].equals(cur));
                o.put("best", i == bestIdx);
            } catch (Exception ignored) {}
            arr.put(o);
        }
        return arr;
    }

    /** 手动切换到指定线路（设置页「链路检测」里点选），并立即重新加载页面。 */
    public void switchToRoute(final String url) {
        if (indexOf(SPACE_URLS, url) < 0) return;
        currentUrl = url;
        saveBest(url);
        final WebView wv = getBridge() == null ? null : getBridge().getWebView();
        if (wv == null) return;
        wv.post(new Runnable() {
            @Override public void run() {
                seedSessionForHost(url);
                attemptedUrls.clear();
                wv.loadUrl(url);
            }
        });
    }

    /**
     * 并行探测所有线路并按需择优切换。只由两处触发：
     * ① {@link #slowLoadWatchdog} —— 启动 6 秒还没把页面拉出来（线路慢或不通）；
     * ② 离线页「重试」。
     * 正常进入时不会走到这里：从哪条链接进来，就用哪条，不额外探测。
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
                    // 全部失败且之前绑过物理网卡：可能是「只有组网隧道能出网」的环境，
                    // 解绑退回系统默认网络再测一轮，仍然全挂才判定离线。
                    if (bestIdx < 0 && !pageLoaded && releaseTunnelBinding()) {
                        lat = probeAll();
                        bestIdx = -1;
                        bestMs = Long.MAX_VALUE;
                        for (int i = 0; i < lat.length; i++) {
                            if (lat[i] >= 0 && lat[i] < bestMs) { bestMs = lat[i]; bestIdx = i; }
                        }
                    }
                    if (bestIdx < 0) {
                        // 页面已经加载成功（只是探测预算不够）→ 别抢屏，保留当前页面
                        if (pageLoaded) return;
                        wv.post(new Runnable() { public void run() { showRecoveryPage(wv, "所有线路均无法连接"); } });
                        return;
                    }
                    final String best = SPACE_URLS[bestIdx];
                    int ci = indexOf(SPACE_URLS, currentUrl);
                    long curMs = ci >= 0 ? lat[ci] : -1;
                    // 页面已经加载成功 → 只要当前线路还能用就绝不换。
                    // 1.6.3 及以前这里是「curMs <= bestMs*2+400 才保留」，而实测最快 133ms、
                    // CF Tunnel 1781ms，这个条件永远不成立，于是每次冷启动都会在页面已经
                    // 加载完之后再整页重载一遍 —— 用户感知就是「进页面特别慢」；
                    // 而重载又会打断刚建立的连接与探测状态，看起来就像「链路检测失效」。
                    // 想换线路请走设置里的「链路检测」手动切换，或离线页的「重试」。
                    boolean keepCurrent = !force && curMs >= 0 && (pageLoaded || curMs <= bestMs * 2 + 400);
                    if (keepCurrent) {
                        saveBest(currentUrl);
                        return;
                    }
                    if (!best.equals(currentUrl)) {
                        currentUrl = best;
                        saveBest(best);
                        wv.post(new Runnable() { public void run() { seedSessionForHost(best); attemptedUrls.clear(); wv.loadUrl(best); } });
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
                    view.post(new Runnable() { public void run() { seedSessionForHost(next); attemptedUrls.clear(); view.loadUrl(next); } });
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
            // probe 内部 connect/read 各 PROBE_TIMEOUT_MS，满等只作兜底；正常线路 2~3s 内就绪
            latch.await(PROBE_TIMEOUT_MS * 2L + 2000L, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return lat;
    }

    /**
     * 对单条线路发一次 GET /api/status，返回耗时毫秒；不可达返回 -1。
     *
     * 两个坑都在这里踩过（1.6.6）：
     * ① HttpsURLConnection 默认 UA 是 `Java/1.8.0_392`，Cloudflare 对它的
     *    判定是恶意的，CF 隧道那条线路直接 403 —— 探测以为线路死了，其实
     *    WebView（UA=LoveSpaceApp/…）访问完全正常。必须显式带 App 的 UA。
     * ② 原来要求 2xx~3xx 才算通，于是 403/404 这种「TCP 通了、服务也应答了」
     *    的情况被判成不可达。改成 <500 即认为线路可达，只有 5xx 与网络异常算死。
     */
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
            // UA 必须是纯 ASCII：versionName 取不到时 appVersion() 会返回「未知」，
            // 非 ISO-8859-1 的值会让 HttpURLConnection 直接抛 IllegalArgumentException。
            String ver = appVersion();
            if (ver == null || !ver.matches("[0-9.]+")) ver = "1.0";
            conn.setRequestProperty("User-Agent", "LoveSpaceApp/" + ver + " (Android; LinkProbe)");
            conn.setRequestProperty("Accept", "application/json");
            conn.setRequestProperty("Cache-Control", "no-store");
            long t0 = System.nanoTime();
            int code = conn.getResponseCode();
            long ms = (System.nanoTime() - t0) / 1_000_000L;
            return (code > 0 && code < 500) ? ms : -1;
        } catch (Exception e) {
            Log.i(TAG, "探测 " + base + " 失败: " + e);
            return -1;
        } finally {
            if (conn != null) {
                try { conn.disconnect(); } catch (Exception ignored) {}
            }
        }
    }

    /** 读取当前页面的登录 cookie，并同步到全部线路，切域免重登。 */
    private void captureAndShareSession(String url) {
        if (url == null || url.startsWith("file:")) return;
        try {
            String token = extractCookie(CookieManager.getInstance().getCookie(url), SESSION_COOKIE);
            if (token == null || token.isEmpty()) {
                // 已登出（cookie 被清）→ 忘记保存的 token，并清掉其它线路的旧 cookie
                if (prefs().contains(KEY_SESSION)) {
                    prefs().edit().remove(KEY_SESSION).apply();
                    clearSessionOnAll();
                }
                return;
            }
            String prev = prefs().getString(KEY_SESSION, null);
            if (token.equals(prev)) return;
            prefs().edit().putString(KEY_SESSION, token).apply();
            shareSessionToAll(token);
            Log.i(TAG, "已同步登录态到全部线路");
        } catch (Exception e) {
            Log.w(TAG, "同步登录态失败", e);
        }
    }

    private void shareSessionToAll(String token) {
        CookieManager cm = CookieManager.getInstance();
        for (String u : SPACE_URLS) seedCookie(cm, u, token);
        cm.flush();
    }

    /** 切换线路前先给目标 host 种上已保存的登录 cookie。 */
    private void seedSessionForHost(String url) {
        try {
            String token = prefs().getString(KEY_SESSION, null);
            if (token == null || token.isEmpty()) return;
            CookieManager cm = CookieManager.getInstance();
            seedCookie(cm, url, token);
            cm.flush();
        } catch (Exception ignored) {}
    }

    private void clearSessionOnAll() {
        CookieManager cm = CookieManager.getInstance();
        for (String u : SPACE_URLS) {
            try {
                URL url = new URL(u);
                String base = "https://" + url.getHost() + (url.getPort() > 0 ? ":" + url.getPort() : "") + "/";
                cm.setCookie(base, SESSION_COOKIE + "=; Path=/; Max-Age=0; Secure");
            } catch (Exception ignored) {}
        }
        cm.flush();
    }

    private void seedCookie(CookieManager cm, String url, String token) {
        try {
            URL u = new URL(url);
            String base = "https://" + u.getHost() + (u.getPort() > 0 ? ":" + u.getPort() : "") + "/";
            cm.setCookie(base, SESSION_COOKIE + "=" + token + "; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax");
        } catch (Exception ignored) {}
    }

    private static String extractCookie(String header, String name) {
        if (header == null) return null;
        for (String part : header.split(";")) {
            String p = part.trim();
            int eq = p.indexOf('=');
            if (eq > 0 && p.substring(0, eq).equals(name)) return p.substring(eq + 1);
        }
        return null;
    }
}
