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

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Inet6Address;
import java.net.InetSocketAddress;
import java.net.HttpURLConnection;
import java.net.Socket;
import java.net.URL;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

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
        // 明文纯 IP，只在家里局域网可达。探测与 cookie 都按 scheme 走（不能对 http 用 TLS）。
        "http://192.168.31.95:1314/"
    };
    private static final String SPACE_URL = SPACE_URLS[0];
    /* 与 SPACE_URLS 一一对应的展示名，设置页「链路检测」用。 */
    private static final String[] ROUTE_NAMES = {
        "Cloudflare 隧道",
        "节点小宝",
        "腾讯云 CloudBase",
        "Lucky 直连",
        "内网直连"
    };
    private static final String OFFLINE_PAGE = "file:///android_asset/lovespace-offline.html";
    /* 内置贴图：打包时把仓库 static/stickers/ 拷进 assets/stickers/（CI 与本地出包各做一次，
       assets 被 Capacitor 的 .gitignore 排除，贴图不会因此重复进仓库）。 */
    private static final String STICKER_PREFIX = "/static/stickers/";
    /* 五条线路的域名集合：贴图拦截只对这些 host 生效，别的网站路径一律不碰。 */
    private static final Set<String> KNOWN_HOSTS = new HashSet<>();
    static {
        for (String u : SPACE_URLS) {
            try { KNOWN_HOSTS.add(new URL(u).getHost()); } catch (Exception ignored) {}
        }
    }
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
        // ⑤ 键盘兜底桥：Capacitor 8 / targetSdk 36 下，正常路径是 insets 流到 WebView、
        //    Chromium 自己缩视觉视口（网页走 A 类路径）。这一桥只在 insets 没到位时才用得上
        //    （旁路读取 ime() 高度喂给网页，原样下发不拦截），留着不碍事，删了就没退路。
        setupImeHeightBridge();
    }

    /**
     * 键盘高度桥：把 IME 高度实时写进网页的 CSS 变量 --kb-h。
     *
     * 三条硬约束（v1.6.12~v1.6.22 七轮试错换来的，别改）：
     *  ① 绝不改 WebView 的尺寸（height / margin / setFitInsetsTypes 全部走不通）：
     *     - setFitInsetsTypes 在非 translucent 主窗口上会被 AOSP 硬校验拒绝并抛
     *       IllegalArgumentException（真机 logcat 实证）；
     *     - 手动 resize/margin 是异步重排，Chromium 慢一帧渲染，新腾出的区域是黑帧。
     *  ② insets listener 必须挂在 WebView 的**父容器**上，不能挂 WebView 自身——
     *     挂上去会顶掉 Chromium 自己的 onApplyWindowInsets，env(safe-area-inset-*) 全部归零。
     *     返回值原样下发，让 WebView 继续收到真实 insets。
     *  ③ 这里是**物理像素**，网页端除以 devicePixelRatio 才是 CSS px。
     *     不做换算直接写，density 2.75 会放大近 3 倍。
     *
     * 用动画回调而不是普通 insets 分发：普通分发只在键盘动画首/尾给值，
     * 动画中间那 ~300ms 网页拿到的是旧值，输入条会滞后。
     */
    private void setupImeHeightBridge() {
        try {
            if (getBridge() == null || getBridge().getWebView() == null) return;
            final WebView wv = getBridge().getWebView();
            final android.view.View parent = (wv.getParent() instanceof android.view.View)
                    ? (android.view.View) wv.getParent() : null;
            if (parent == null) return;

            final int[] lastPx = { -1 };
            final android.view.View target = parent;

            androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(target,
                    new androidx.core.view.OnApplyWindowInsetsListener() {
                        @Override
                        public androidx.core.view.WindowInsetsCompat onApplyWindowInsets(
                                android.view.View v, androidx.core.view.WindowInsetsCompat insets) {
                            // 返回值必须是原 insets：只旁路读取，不拦截 Chromium 自己的处理
                            pushImeHeight(wv, insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime()).bottom, lastPx);
                            return insets;
                        }
                    });

            androidx.core.view.ViewCompat.setWindowInsetsAnimationCallback(target,
                    new androidx.core.view.WindowInsetsAnimationCompat.Callback(
                            androidx.core.view.WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                        @Override
                        public androidx.core.view.WindowInsetsCompat onProgress(
                                androidx.core.view.WindowInsetsCompat insets,
                                java.util.List<androidx.core.view.WindowInsetsAnimationCompat> runningAnimations) {
                            // 键盘动画每一帧都会进来，尺寸全程不动，只写变量
                            pushImeHeight(wv, insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime()).bottom, lastPx);
                            return insets;
                        }
                    });
        } catch (Throwable t) {
            // 桥不成立只影响"键盘顶不顶得起"，绝不允许它拖垮启动流程
            Log.w(TAG, "setupImeHeightBridge failed", t);
        }
    }

    /**
     * 把 IME 高度推进网页。值没变就不重复发（动画每帧都会调，去重能省掉大量 JS 调用）。
     * 网页端 __kbSetNative 由 static/chat.js 提供；老前端没有这个函数，桥直接跳过即可——
     * 老前端自己走 visualViewport 那套，写了反而可能双份位移。
     */
    private void pushImeHeight(final WebView wv, final int px, final int[] lastPx) {
        if (px == lastPx[0]) return;
        lastPx[0] = px;
        try {
            final int h = px;
            wv.post(new Runnable() {
                @Override public void run() {
                    try {
                        wv.evaluateJavascript(
                                "(function(){try{if(typeof window.__kbSetNative==='function')window.__kbSetNative("
                                        + h + ");}catch(e){}})()", null);
                    } catch (Exception ignored) {}
                }
            });
        } catch (Exception ignored) {}
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
            // 链路检测页备用通道：Capacitor 桥在远程加载模式下不保证注入，
            // JS 侧用 UA 识别出 App 后，通过自定义 scheme 求助原生端。
            if ("link-probe".equals(uri.getHost())) {
                final WebView wv = view;
                new Thread(new Runnable() {
                    @Override public void run() {
                        final String json = probeRoutesForUi().toString();
                        wv.post(new Runnable() {
                            @Override public void run() {
                                wv.evaluateJavascript(
                                    "window.__lovespaceLinkProbe&&window.__lovespaceLinkProbe({routes:" + json + "})", null);
                            }
                        });
                    }
                }, "link-probe-cb").start();
                return true;
            }
            if ("link-use".equals(uri.getHost())) {
                try {
                    String url = uri.getQueryParameter("url");
                    if (url != null && isKnownRoute(url)) switchToRoute(url);
                } catch (Exception e) {
                    Log.w(TAG, "切换线路失败", e);
                }
                return true;
            }
            return false;
        }

        /**
         * 内置贴图：/static/stickers/** 直接由 APK 内 assets/stickers 返回（v1.2.2 方案回归）。
         * 好处：打开表情面板秒出、断网可用、不占服务器带宽；
         * 资源缺失或损坏时自动回落网络（服务器仍有同一份文件）。
         */
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            WebResourceResponse local = localSticker(request.getUrl(), request.getRequestHeaders());
            return local != null ? local : super.shouldInterceptRequest(view, request);
        }

        private WebResourceResponse localSticker(Uri uri, java.util.Map<String, String> headers) {
            if (uri == null || !KNOWN_HOSTS.contains(uri.getHost())) return null;
            String path = uri.getPath();
            if (path == null || !path.startsWith(STICKER_PREFIX)) return null;
            String name = path.substring(STICKER_PREFIX.length());
            if (name.isEmpty() || name.contains("..") || name.contains("%")) return null;
            String asset = "stickers/" + name;
            String mime = name.endsWith(".webm") ? "video/webm"
                    : name.endsWith(".webp") ? "image/webp" : "application/octet-stream";
            try {
                // 优先 openFd（能拿到文件长度，支持视频贴图的 Range 请求）；
                // 若资源被压缩存储则 openFd 会失败，回落到普通 open()（整文件返回，不支持 Range）
                java.io.InputStream raw;
                long total = -1;
                try {
                    android.content.res.AssetFileDescriptor afd = getAssets().openFd(asset);
                    total = afd.getLength();
                    raw = afd.createInputStream();
                } catch (Exception compressed) {
                    raw = getAssets().open(asset);
                }
                long start = 0;
                boolean partial = false;
                if (headers != null) {
                    for (java.util.Map.Entry<String, String> entry : headers.entrySet()) {
                        if (entry.getKey() == null || !"Range".equalsIgnoreCase(entry.getKey())) continue;
                        String value = entry.getValue();
                        if (value == null || !value.startsWith("bytes=")) continue;
                        String spec = value.substring(6);
                        int dash = spec.indexOf('-');
                        if (dash <= 0) continue;
                        try {
                            start = Long.parseLong(spec.substring(0, dash).trim());
                        } catch (NumberFormatException ignore) {
                            continue;
                        }
                        // 只处理"从某处读到结尾"的区间请求；前缀区间按整文件返回
                        partial = total > 0 && start > 0 && start < total;
                        break;
                    }
                }
                java.util.Map<String, String> extra = new java.util.HashMap<>();
                extra.put("Cache-Control", "max-age=31536000");
                extra.put("Access-Control-Allow-Origin", "*");
                if (partial) {
                    long skipped = 0;
                    while (skipped < start) {
                        long n = raw.skip(start - skipped);
                        if (n <= 0) break;
                        skipped += n;
                    }
                    extra.put("Accept-Ranges", "bytes");
                    extra.put("Content-Range", "bytes " + start + "-" + (total - 1) + "/" + total);
                    return new WebResourceResponse(mime, null, 206, "Partial Content", extra, raw);
                }
                return new WebResourceResponse(mime, null, 200, "OK", extra, raw);
            } catch (Exception e) {
                Log.d(TAG, "贴图未命中本地资源，回网络: " + asset);
                return null;
            }
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
        // 先在**当前线程**把各条线路的域名/IP 解析完（IPv6 优先排序），再交给各探测线程。
        // 解析时临时切换 java.net.preferIPv6Addresses：Java 默认 IPv4 优先且**失败不
        // 回退**，Lucky 直连是纯 IPv6 线路（A 记录指向运营商 CGNAT 共享地址，公网
        // 无法入站），于是一直连那个永远不通的 IPv4 地址 → 判定「不可达」；而
        // WebView/手机浏览器用 Happy Eyeballs（v4 超时立刻切 v6）所以能打开。
        // 这里解析一次拿到「v6 在前、v4 在后」的地址列表，探测时按列表逐个尝试，
        // 效果等同浏览器。解析只在这一个线程发生，不存在属性切换竞态。
        final InetAddress[][] resolved = new InetAddress[SPACE_URLS.length][];
        // 用稳定排序把 IPv6 排到 IPv4 前面，不去动 java.net.preferIPv6Addresses
        // 这种 JVM 全局属性（它影响所有线程，WebView 内部也在用网络）。
        for (int i = 0; i < SPACE_URLS.length; i++) {
            try {
                InetAddress[] addrs = InetAddress.getAllByName(new URL(SPACE_URLS[i]).getHost());
                Arrays.sort(addrs, new Comparator<InetAddress>() {
                    @Override public int compare(InetAddress a, InetAddress b) {
                        return (a instanceof Inet6Address ? 0 : 1) - (b instanceof Inet6Address ? 0 : 1);
                    }
                });
                resolved[i] = addrs;
            } catch (Exception e) {
                Log.i(TAG, "解析 " + SPACE_URLS[i] + " 失败: " + e);
                resolved[i] = new InetAddress[0];
            }
        }
        final long[] lat = new long[SPACE_URLS.length];
        Arrays.fill(lat, -1);
        final CountDownLatch latch = new CountDownLatch(SPACE_URLS.length);
        for (int i = 0; i < SPACE_URLS.length; i++) {
            final int idx = i;
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        lat[idx] = probeLatency(SPACE_URLS[idx], resolved[idx]);
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
     * 四个坑都在这里踩过：
     * ① URLConnection 默认 UA 是 `Java/1.8.0_392`，Cloudflare 对它的判定是恶意的，
     *    CF 隧道那条线路直接 403 —— 探测以为线路死了，其实 WebView（UA=LoveSpaceApp/…）
     *    访问完全正常。必须显式带 App 的 UA。
     * ② 原来要求 2xx~3xx 才算通，403/404 这种「TCP 通了、服务也应答了」被判成不可达。
     *    改成 &lt;500 即认为线路可达，只有 5xx 与网络异常算死。
     * ③ Java 连地址失败**不会回退**下一个地址：Lucky 直连是纯 IPv6 线路（A 记录指向
     *    运营商 CGNAT 共享地址，公网无法入站），默认行为会一直连那个永远不通的 IPv4 →
     *    判定「不可达」。这里按地址列表**逐个尝试**：IPv6 优先，不通就换 IPv4，
     *    与手机浏览器的 Happy Eyeballs 等效。
     * ④ HttpURLConnection 无法指定「连接哪个地址」（connect(InetAddress) 不存在），
     *    所以改为原始 Socket + 手动 TLS：SNI 用真实域名（Lucky 只认域名 Host，
     *    是 IP 会 307）、证书校验开启 endpoint identification，Host 头也用域名。
     *
     * @param addrs 预解析的地址列表（IPv6 在前），为空时回退到默认 DNS 行为。
     */
    private long probeLatency(String base, InetAddress[] addrs) {
        final String host;
        final int portNum;
        final String path;
        final boolean secure;
        try {
            URL u = new URL(base);
            host = u.getHost();
            secure = "https".equalsIgnoreCase(u.getProtocol());
            // 默认端口按协议取：http=80、https=443。以前一律写 443，
            // 内网明文线路（:1314 已显式带端口）以外的 http 地址会连错端口。
            portNum = u.getPort() > 0 ? u.getPort() : (secure ? 443 : 80);
            path = new URL(u, "api/status").getFile();
        } catch (Exception e) {
            Log.i(TAG, "线路地址无效: " + base);
            return -1;
        }
        // UA 必须是纯 ASCII：versionName 取不到时 appVersion() 会返回「未知」，
        // 非 ISO-8859-1 的值会让请求行写出非法字节。
        String ver = appVersion();
        if (ver == null || !ver.matches("[0-9.]+")) ver = "1.0";
        final String userAgent = "LoveSpaceApp/" + ver + " (Android; LinkProbe)";

        for (InetAddress addr : addrs) {
            long ms = probeOnce(host, portNum, path, userAgent, addr, secure);
            if (ms >= 0) return ms;
        }
        // 地址列表为空（解析失败）：按默认 DNS 行为试最后一次，尽量不误判
        if (addrs.length == 0) {
            HttpURLConnection conn = null;
            try {
                URL url = new URL(new URL(base), "api/status");
                conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(PROBE_TIMEOUT_MS);
                conn.setReadTimeout(PROBE_TIMEOUT_MS);
                conn.setUseCaches(false);
                conn.setRequestMethod("GET");
                conn.setInstanceFollowRedirects(true);
                conn.setRequestProperty("User-Agent", userAgent);
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
        return -1;
    }

    /** 对单个地址做一次（可选 TLS）+ HTTP/1.1 GET，成功返回耗时毫秒，任何失败返回 -1。
     *  http 的明文线路（内网直连）不能套 SSLSocket，否则握手直接失败、被判成不可达。 */
    private long probeOnce(String host, int port, String path, String userAgent,
                           InetAddress addr, boolean secure) {
        Socket sock = null;
        try {
            Socket raw = new Socket();
            raw.connect(new InetSocketAddress(addr, port), PROBE_TIMEOUT_MS);
            sock = raw;
            if (secure) {
                SSLSocket ssl = (SSLSocket) ((SSLSocketFactory) SSLSocketFactory.getDefault())
                    .createSocket(raw, host, port, true);
                SSLParameters params = ssl.getSSLParameters();
                params.setEndpointIdentificationAlgorithm("HTTPS"); // 证书主机名校验
                ssl.setSSLParameters(params);
                applySni(ssl, host); // SNIHostName 是 API 24+，低版本用反射，失败就无 SNI 直连
                ssl.setSoTimeout(PROBE_TIMEOUT_MS);
                ssl.startHandshake();
                sock = ssl;
            } else {
                raw.setSoTimeout(PROBE_TIMEOUT_MS);
            }
            StringBuilder req = new StringBuilder();
            req.append("GET ").append(path).append(" HTTP/1.1\r\n")
               .append("Host: ").append(host).append(':').append(port).append("\r\n")
               .append("User-Agent: ").append(userAgent).append("\r\n")
               .append("Accept: application/json\r\n")
               .append("Connection: close\r\n\r\n");
            OutputStream os = sock.getOutputStream();
            os.write(req.toString().getBytes("ISO-8859-1"));
            os.flush();
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(sock.getInputStream(), "ISO-8859-1"));
            long t0 = System.nanoTime();
            String status = reader.readLine();
            long ms = (System.nanoTime() - t0) / 1_000_000L;
            if (status != null) {
                String[] parts = status.split(" ");
                if (parts.length >= 2) {
                    int code;
                    try { code = Integer.parseInt(parts[1].trim()); }
                    catch (NumberFormatException nfe) { code = -1; }
                    if (code > 0 && code < 500) return ms;
                    Log.i(TAG, "探测 " + host + "@" + addr.getHostAddress() + " 返回 " + code);
                }
            }
            return -1;
        } catch (Exception e) {
            Log.i(TAG, "探测 " + host + "@" + addr.getHostAddress() + " 失败: " + e);
            return -1;
        } finally {
            if (sock != null) {
                try { sock.close(); } catch (Exception ignored) {}
            }
        }
    }

    /** 给 TLS 加上 SNI。SNIHostName / setServerNames 是 API 24+ 才有，低版本走反射。 */
    private static void applySni(SSLSocket socket, String host) {
        try {
            Class<?> sniClass = Class.forName("javax.net.ssl.SNIHostName");
            Object name = sniClass.getConstructor(String.class).newInstance(host);
            Class<?> nameClass = Class.forName("javax.net.ssl.SNIServerName");
            SSLParameters params = socket.getSSLParameters();
            params.getClass().getMethod("setServerNames", nameClass)
                .invoke(params, Collections.singletonList(name));
            socket.setSSLParameters(params);
        } catch (Throwable ignored) {
            // 无 SNI 直连：服务器默认 vhost 仍是该证书，不影响可达性判定
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
                boolean secure = "https".equalsIgnoreCase(url.getProtocol());
                String base = url.getProtocol() + "://" + url.getHost()
                    + (url.getPort() > 0 ? ":" + url.getPort() : "") + "/";
                cm.setCookie(base, SESSION_COOKIE + "=; Path=/; Max-Age=0"
                    + (secure ? "; Secure" : ""));
            } catch (Exception ignored) {}
        }
        cm.flush();
    }

    private void seedCookie(CookieManager cm, String url, String token) {
        try {
            URL u = new URL(url);
            // 明文内网线路不能写死 https:// + Secure：CookieManager 会把它种到
            // 另一个域，切过去照样是未登录。http 线路也不该带 Secure 属性。
            boolean secure = "https".equalsIgnoreCase(u.getProtocol());
            String base = u.getProtocol() + "://" + u.getHost()
                + (u.getPort() > 0 ? ":" + u.getPort() : "") + "/";
            cm.setCookie(base, SESSION_COOKIE + "=" + token + "; Path=/; Max-Age=2592000"
                + (secure ? "; Secure" : "") + "; HttpOnly; SameSite=Lax");
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
