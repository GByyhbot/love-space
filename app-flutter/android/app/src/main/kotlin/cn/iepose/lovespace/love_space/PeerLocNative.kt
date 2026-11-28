package cn.iepose.lovespace.love_space

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.lang.ref.WeakReference
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.atan2
import kotlin.math.PI

/**
 * 2.8.0 定位守护第 0 步 · 路线 B：原生 LocationManager 三 provider 采集 +
 * 端上 GCJ-02 转换 + 原生自足批量上报（全链路在 FGS 进程内，不依赖任何
 * Flutter isolate——flutter_foreground_task 的服务 isolate 是独立 engine，
 * 主 engine 的 channel 服务侧收不到，故采集/上报全在原生层，Dart 只发
 * start(token, baseUrl) / stop 指令）。
 *
 * 🔴 红线依据：国产小米机无 GMS，FusedLocationProvider 回调永不触发
 * （开源实证）。🔴 couple-tracker 无 LICENSE：只借鉴设计与参数，本文件自研。
 *
 * 采样口径（提示词主体二，参数集中此处便于二期调参）：
 * · 位移触发 25 m（GPS/NETWORK，硬件级系统判断）；minTime 15 s；
 * · PASSIVE 零耗电补点（复用其他 App 的定位结果）；
 * · 静止判定：连续 3 次位移 <25 m → 降 5 min 心跳（附带状态字段）；
 *   恢复有效位移即回行进节奏；
 * · 精度过滤：acc>100 m 丢弃；50<acc≤100 m 只更新 latest 不入轨迹；
 * · 批量上报：攒满 5 条或距上次成功超 3 min；队列上限 50 条溢出丢最旧；
 *   失败保留队列网络恢复补传（置 backfilled 标记）；
 * · 坐标：端上 WGS-84→GCJ-02 转换后上报（后端入库统一 GCJ-02，不二次转换）。
 *
 * ── 2.8.0 fix7：静止心跳改真定时器（24h 复盘实证的断档根因）───────────
 * 旧实现把「静止 5 min 心跳」写成 onLocation() 内部的**门控**：静止时
 * GPS/NETWORK 不产回调、PASSIVE 依赖别的 App，回调不来 → 心跳永不触发，
 * 整夜 0 轨迹点（复盘 5 段 >60min 断档，backfill 全 0＝压根没产点）。
 * 现在：
 * 1. **AlarmManager 真定时器**（`ELAPSED_REALTIME_WAKEUP` +
 *    `setAndAllowWhileIdle`）。不用 `Handler.postDelayed`：Doze 下会停表。
 *    注：本 App 的 FGS 是 `specialUse`（flutter_foreground_task，
 *    `allowWakeLock: true` 持部分唤醒锁），理论上持有唤醒锁时 Handler 也能
 *    跑，但那是插件配置的副作用、改一行配置就静默失效，不能当契约；
 *    且 Doze 下闹钟本身也是被推迟的对象，`setAndAllowWhileIdle` 是最小
 *    可行集（深度 idle 会被节流到约 9–15 min 一次，仍满足验收口径）。
 * 2. **时钟统一 `SystemClock.elapsedRealtime()`**：`lastSentAt` /
 *    `lastFlushAt` 全改 elapsed 口径，不再与墙钟混用（墙钟可被用户改，
 *    且跨时区/校时会出现负间隔）。上报载荷里的 `ts` 仍是墙钟（服务端要
 *    epoch），两码事。
 * 3. **去重豁免**：心跳点（定时器路径 + 回调路径 heartbeat=true）跳过
 *    <10 m 的 lastEnqueued 去重——静止点与上一点必然 <10 m，旧实现即使
 *    偶有回调触发心跳也会被去重丢弃（`heartbeat` 变量当时置后无人消费）。
 * 4. **acc 口径防坑**：心跳点只沿用**最后一次 acc ≤ 50 的入点定位**
 *    （[lastAccepted]），不拿 lastSent/latest 快照冒充（快照可能来自
 *    50–100 的精度层，拿它造点等于给轨迹注水）。无 acc ≤ 50 历史点时
 *    退化为只保鲜 latest。冷启动即静止且无任何历史点 → 跳过不造假点。
 * 5. **latest 保鲜**：tick 即使不产轨迹点也刷新 lastSent 并 flush，
 *    使对方端「最后在线」不冻结。
 * 6. **防双发**：两条路径共用 [lastSentAt] 门控，同一 5 min 窗口只出一点
 *    （先到者为准），tick 被门控时只续挂下一次闹钟、不补点。
 *
 * ── 2.8.0 fix8：flush 单飞 + accepted 计数 + 无回调兜底心跳 ────────────
 * fix7 回执附带的诊断实证了两处原生缺陷，本批收口：
 * 1. **flush 单飞锁**：原实现每次入队 ≥5 条就 spawn 一个上报线程，请求在途
 *    期间队列未消费，下一次入队再 spawn → 多个线程取到**同一批**，各自 2xx
 *    后都按本地批次长度累加 `reportedCount`，同一批被重复计数（卡面「已报」
 *    虚高、服务端按 id 幂等挡掉所以落点数不涨）。现在 `flushing` 单飞 +
 *    `flushPending` 尾随标志，在途请求只允许一个。
 * 2. **队列线程安全**：`queue`（ArrayDeque）原来被主线程写、上报线程读，
 *    无锁。现在上报前在 **main** 线程切片成不可变快照（id 列表 + payload
 *    字符串），后台线程只持快照；2xx 回 main 线程按快照 id 从队头移除。
 * 3. **reportedCount 按服务端 `accepted` 累加**：后端
 *    `POST /api/peer/location` 返回 `{'ok': True, 'accepted': <int>}`
 *    （`app/main.py:1852`，`accepted` 只统计真正落库条数，幂等 dup/非法行
 *    不计）。解析失败/旧服务端缺字段一律按 0，不抛异常；空 points 只保鲜
 *    latest 的响应恒为 0，不再虚增。
 * 4. **无回调兜底心跳**：fix7 只在 `stillMode` 置位时挂表，覆盖不到「刚移动
 *    完就熄屏、静止回调不足 3 次」的整夜空窗。现在只要**采集中且已有历史
 *    定位**就一直维持一根 5 min 闹钟，锚点恒为 `lastSentAt + HEARTBEAT_MS`
 *    （不以 tick 时刻漂移累加）；tick 时距上次上报不足一个窗口说明期间正常
 *    运动出了回调 → 不补点，只按新锚点续挂。
 *
 * [peer-loc] 前缀调试日志（采样切换/上报成败/补传量），本段保留不删。
 */
object PeerLocNative {
    private const val CHANNEL = "peer_loc/native"
    const val TAG = "peer-loc"

    // ── 参数集中（二期调参）────────────────────────────────────────────
    private const val MIN_DISTANCE_M = 25f
    private const val MIN_TIME_MS = 15_000L
    // fix8：静止判定门槛仍在 HeartbeatGate（shouldEnterStill 的默认参数），
    // 这里不再复制一份常量，避免两处口径漂移
    private const val STILL_HEARTBEAT_MS = HeartbeatGate.HEARTBEAT_MS
    private const val ACC_DROP_M = 100.0        // >100 m 丢弃
    private const val ACC_LATEST_ONLY_M = 50.0  // >50 m 只更新 latest
    private const val BATCH_MAX = 5
    private const val BATCH_FLUSH_MS = 3 * 60_000L
    private const val QUEUE_MAX = 50
    private const val POINT_RETENTION_HINT = 15 // 仅注释口径，清理在后端

    /** 静止心跳 tick 的私有广播 action（仅进程内动态注册，RECEIVER_NOT_EXPORTED）。 */
    private const val HEARTBEAT_ACTION = "cn.iepose.lovespace.love_space.PEER_HEARTBEAT"
    private const val HEARTBEAT_REQUEST_CODE = 0x4842 // 'HB'，固定即可（单闹钟）

    private var lm: LocationManager? = null
    private val listeners = mutableListOf<LocationListener>()
    private val handler = Handler(Looper.getMainLooper())

    /** 状态事件回传 Dart 用的 messenger（register 时存，emit 时建通道）。 */
    private var stateMessenger: io.flutter.plugin.common.BinaryMessenger? = null

    // 会话凭据（Dart 端 start 注入；进程内保存，服务被杀随进程消失）
    private var sessionCookie: String? = null
    private var baseUrl: String? = null
    private var appContext: Context? = null

    // 采集态
    private val debouncer = LocationDebouncer()
    private var adaptiveStationaryActive = false
    private var nextFlushAllowedAtElapsed = 0L
    private val queue = ArrayDeque<JSONObject>()
    private var lastSent: JSONObject? = null
    private var lastEnqueued: JSONObject? = null

    /** 最后一次 **acc ≤ 50 且已入轨迹点** 的定位（GCJ 坐标 + acc），心跳点唯一来源。 */
    private var lastAccepted: JSONObject? = null
    private var lastSentAt = 0L      // elapsedRealtime 口径（fix7 统一时钟）
    private var stillCount = 0
    private var stillMode = false
    private var lastFlushAt = 0L     // elapsedRealtime 口径
    private var reportedCount = 0
    private var droppedCount = 0
    private var lastError: String? = null
    private var receivedCount = 0
    private var lastReceivedAt = 0L
    private var lastFlushWallMs = 0L

    // Diagnostics & activity reference
    private var activityRef: WeakReference<Activity>? = null
    private var lastStateEmitMs = 0L
    private var lastUsagePullMs = 0L
    private var lastUsageEmitMs = 0L
    private var lastUsageRawCount = 0
    private var lastPolicySummary = ""
    private var appOff = false

    // System Geocoder cache (Android OS Geocoder only; WGS84 inputs, throttled)
    private val geocodeExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var cachedPlaceName = ""
    @Volatile private var lastGeocodeLat: Double? = null
    @Volatile private var lastGeocodeLng: Double? = null
    @Volatile private var lastGeocodeAtMs = 0L
    @Volatile private var geocodeInFlight = false

    // fix7 心跳定时器态
    private var heartbeatReceiver: BroadcastReceiver? = null
    private var heartbeatArmed = false
    private var heartbeatTicks = 0   // 诊断：tick 实际触发次数（真机复验看此值）
    private var armedTarget = 0L     // 已挂闹钟的目标时刻（elapsed），避免重复 set

    // fix8 上报单飞态（全部只在 main 线程读写）
    private var flushing = false
    private var flushPending = false

    private fun log(msg: String) = android.util.Log.d(TAG, msg)

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        stateMessenger = messenger
        if (context is Activity) {
            activityRef = WeakReference(context)
        }
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // ── 2.8.0 fix4 胶水重做：单一原生入口（一口价）──────────
                // Dart 只搬运 {enable, cookie, baseUrl}（凭据从 secure_storage
                // 正本读出后下传，Dart 只做渲染），一切权限判定/启停/状态
                // 都在本原生层收口，返回 {ok, reason, detail}。
                "toggle" -> {
                    val args = call.arguments() as? Map<*, *>
                    val enable = args?.get("enable") == true
                    sessionCookie = args?.get("cookie") as? String
                    baseUrl = args?.get("baseUrl") as? String
                    result.success(toggle(context, enable))
                }
                // ── 2.8.7 自动报备：设备状态采集开关（独立于定位）────────
                // 为什么不挂在 toggle 里：验收要求「只开 events、关 location
                // 也要状态新鲜」，而 toggle 受定位权限硬门槛约束。状态采样
                // 只需要动态广播 + NetworkCallback（SSID 缺定位权限时降级
                // type-only），因此单开一个入口，不动定位的既有判定。
                "toggleState" -> {
                    val args = call.arguments() as? Map<*, *>
                    result.success(toggleState(context, args?.get("enable") == true))
                }
                "stateStatus" -> result.success(stateStatus())
                // ── 2.8.7 全量：应用使用采集（UsageStats）＋ 分档策略执行 ──
                // 采集同样不新建服务：queryEvents 骑既有唤醒点（心跳 tick /
                // 熄屏 / Dart 回前台拉一次），只把会话投给 Dart 入队。
                "toggleUsage" -> {
                    val args = call.arguments() as? Map<*, *>
                    result.success(toggleUsage(context, args?.get("enable") == true))
                }
                "usageStatus" -> result.success(usageStatus(context))
                "openUsageSettings" -> result.success(openUsageSettings(context))
                "pullUsage" -> result.success(pullUsage(context))
                "installedApps" -> result.success(installedApps(context))
                "applyPolicy" -> {
                    val args = call.arguments() as? Map<*, *>
                    @Suppress("UNCHECKED_CAST")
                    val policy = (args?.get("policy") as? Map<*, *>)
                        ?.entries?.associate { it.key.toString() to it.value }
                    result.success(applyPolicy(context, policy ?: emptyMap()))
                }
                "status" -> result.success(status())
                "exportFatal" -> result.success(exportFatalLog())
                "exportShadowLog" -> result.success(AmapShadowEvaluator.exportLog(context))
                // ── 2.8.0 fix6 B3：电池优化豁免（设置卡入口）──────────
                // 状态查询走平台 API（PowerManager），不做任何推断；
                // 申请走系统对话框（ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS），
                // 是否真的豁免由系统决定，本层只回传「意图是否送出」。
                "batteryIgnored" -> result.success(batteryIgnored(context))
                "requestIgnoreBattery" -> result.success(requestIgnoreBattery(context))
                "permissions" -> result.success(permissions(context))
                "openAppSettings" -> result.success(openAppSettings(context))
                "openNotificationSettings" -> result.success(openNotificationSettings(context))
                "openAutoStartSettings" -> result.success(openAutoStartSettings(context))
                "requestLocationPermission" -> {
                    val args = call.arguments() as? Map<*, *>
                    result.success(requestLocationPermission(context, args?.get("background") == true))
                }
                "requestNotificationPermission" -> result.success(requestNotificationPermission(context))
                "diagnostics" -> result.success(diagnostics(context))
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 2.8.0 fix4：FINE 硬门槛判定（toggle 内部分别回报 fine/background 两值，
     * 缺后台走对应引导；background 是否真生效再由回调探针实证）。
     */
    fun hasPermission(context: Context): Boolean = fineGranted(context)

    /** FINE 定位：checkSelfPermission 硬门槛（各 ROM 口径一致）。 */
    fun fineGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * BACKGROUND 定位（Android 11+ / MIUI 兼容口径）：
     * 权限 API（checkSelfPermission/geolocator 枚举）在部分 ROM 上
     * 「已授仍报 denied」不可作事实源（真机实证）——background 是否真生效
     * 以**回调实证探针**为准：start 后统计真实 location 回调数（received），
     * Dart 侧轮询 stats，3 min 内 0 回调即判定后台定位未生效并给用户可见
     * 说明（权限 API 只做 FINE 硬门槛与引导）。
     */
    fun backgroundGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** 启用前置检查：逐项给出缺失原因（FINE 硬门槛；background 走探针实证）。 */
    fun startReason(context: Context): String? = when {
        !fineGranted(context) -> "需要定位权限（使用期间/始终允许）"
        else -> null
    }

    /** 权限两值 detail（fix4 分开回报口径）。 */
    private fun detailMap(context: Context): Map<String, String> = mapOf(
        "fine" to (if (fineGranted(context)) "granted" else "denied"),
        "background" to (if (backgroundGranted(context)) "granted" else "denied"))

    /** 胶水一口价：开/关。返回 {ok, reason, detail}（Dart 只渲染）。 */
    @Synchronized
    fun toggle(context: Context, enable: Boolean): Map<String, Any?> {
        if (!enable) {
            stop()
            return mapOf("ok" to true, "reason" to "", "detail" to detailMap(context))
        }
        // 权限系统真实状态分开回报（缺前台/缺后台两种 reason，Dart 对应引导）
        val fine = fineGranted(context)
        val bg = backgroundGranted(context)
        val detail = mapOf("fine" to (if (fine) "granted" else "denied"),
                           "background" to (if (bg) "granted" else "denied"))
        if (!fine) {
            val reason = "需要定位权限（使用期间），请在系统设置中授予"
            log("toggle-on rejected: fine=$fine bg=$bg")
            fatal(context, "toggle-on rejected fine=${fine} bg=${bg}")
            return mapOf("ok" to false, "reason" to reason, "detail" to detail)
        }
        if (!bg) {
            val reason = "定位权限已授「使用期间」，还需要「始终允许」：" +
                "系统设置 → 应用 → 恋爱空间 → 位置 → 选择「始终允许」后重试"
            log("toggle-on rejected: fine=$fine bg=$bg")
            fatal(context, "toggle-on rejected fine=${fine} bg=${bg}")
            return mapOf("ok" to false, "reason" to reason, "detail" to detail)
        }
        stillMode = false; stillCount = 0; queue.clear()
        debouncer.reset()
        adaptiveStationaryActive = false
        nextFlushAllowedAtElapsed = 0L
        reportedCount = 0; droppedCount = 0; lastError = null
        receivedCount = 0; lastReceivedAt = 0
        // fix7：重开前先清掉可能残留的旧闹钟（上一会话的 stillMode 已归零，
        // 闹钟若还在会在 5 min 后空转一跳）
        cancelHeartbeat(context)
        heartbeatTicks = 0
        lastAccepted = null
        start(context)
        val running = listeners.isNotEmpty()
        val reason = if (running) "" else "采集启动失败（前台服务未运行或被系统拒绝），请重启 App 后重试"
        log("toggle-on: running=$running")
        if (!running) fatal(context, "toggle-on start failed (listeners empty)")
        return mapOf("ok" to running, "reason" to reason, "detail" to detail)
    }

    /** 开关态单一事实源查询：服务在跑 + 最近回调计数（页面进入/toggle 后回填）。 */
    fun status(): Map<String, Any?> {
        val db = debouncer.diagnostics()
        return mapOf(
            "running" to listeners.isNotEmpty(),
            "received" to receivedCount,
            "lastReceivedAt" to lastReceivedAt,
            "queue" to queue.size,
            "reported" to reportedCount,
            "dropped" to droppedCount,
            "still" to stillMode,
            // fix7 诊断：定时器是否挂着 / 实际 tick 次数（真机复验看这两个值，
            // 比只看落库点数更早暴露「闹钟没挂上」）
            "heartbeatArmed" to heartbeatArmed,
            "heartbeatTicks" to heartbeatTicks,
            "debounceState" to db.state.name,
            "anchorLockCount" to db.anchorLockCount,
            "activeLockRadiusM" to db.activeLockRadiusM,
            "activeUnlockRadiusM" to db.activeUnlockRadiusM,
            "droppedAccuracy" to db.droppedAccuracy,
            "droppedSpike" to db.droppedSpike,
            "droppedBounce" to db.droppedBounce,
            "droppedStationary" to db.droppedStationary,
            "backoffStep" to db.backoffStep,
            "error" to lastError,
        )
    }

    /** fatal 日志导出（验证卡导出/分享入口——机主拿得出来才算落盘完成）。 */
    fun exportFatalLog(): Map<String, Any?> {
        val ctx = appContext
        val f = java.io.File(
            (ctx?.getExternalFilesDir(null) ?: ctx?.filesDir), "peer-loc${java.io.File.separator}fatal-native.txt")
        val fatalText = if (f.exists()) f.readText() else ""
        val shadowSummary = AmapShadowEvaluator.summaryLine(ctx)
        val content = if (shadowSummary.isEmpty()) {
            fatalText
        } else if (fatalText.isEmpty()) {
            "[shadow-eval] $shadowSummary\n"
        } else {
            "$fatalText\n[shadow-eval] $shadowSummary\n"
        }
        return mapOf("path" to (if (f.exists()) f.absolutePath else ""),
                     "content" to content)
    }

    /**
     * 2.8.0 fix6 B3：电池优化豁免状态（平台 API 读取，不做任何推断）。
     * 设置卡显示「已豁免/未豁免」即读此值；true = 系统已把本 App 列入
     * Doze 白名单（isIgnoringBatteryOptimizations）。
     */
    fun batteryIgnored(context: Context): Boolean = try {
        val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        pm.isIgnoringBatteryOptimizations(context.packageName)
    } catch (_: Exception) {
        false
    }

    /**
     * 2.8.0 fix6 B3：拉起系统「忽略电池优化」对话框。
     * 返回 true 只代表**意图已送出**，是否豁免由用户在系统弹窗里决定，
     * 真实状态仍以 batteryIgnored() 复读为准（不许用返回值当结论）。
     * 依赖清单权限 REQUEST_IGNORE_BATTERY_OPTIMIZATIONS（普通权限）。
     */
    fun requestIgnoreBattery(context: Context): Boolean = try {
        val intent = android.content.Intent(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            android.net.Uri.parse("package:${context.packageName}"))
        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    private fun notificationsEnabled(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.areNotificationsEnabled() ?: true
        } else {
            true
        }
    } catch (_: Exception) {
        true
    }

    private fun findAutoStartIntent(context: Context): Intent? {
        val candidates = listOf(
            ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManagerActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
        )
        val pm = context.packageManager
        for (cn in candidates) {
            val intent = Intent().setComponent(cn).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                if (pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    return intent
                }
            } catch (_: Exception) {}
        }
        return null
    }

    fun permissions(context: Context): Map<String, Any?> {
        val ctx = context.applicationContext ?: context
        val mfg = (Build.MANUFACTURER ?: "").lowercase(Locale.ROOT)
        return mapOf(
            "fine" to fineGranted(ctx),
            "background" to backgroundGranted(ctx),
            "usage" to hasUsageAccess(ctx),
            "notification" to notificationsEnabled(ctx),
            "batteryIgnored" to batteryIgnored(ctx),
            "manufacturer" to mfg,
            "autoStartIntentSupported" to (findAutoStartIntent(ctx) != null),
        )
    }

    fun openAppSettings(context: Context): Boolean = try {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    fun openNotificationSettings(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } else {
            openAppSettings(context)
        }
    } catch (_: Exception) {
        openAppSettings(context)
    }

    fun openAutoStartSettings(context: Context): Boolean {
        val intent = findAutoStartIntent(context) ?: return false
        return try {
            context.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun requestLocationPermission(context: Context, background: Boolean): Boolean {
        val act = activityRef?.get() ?: return false
        return try {
            if (!background) {
                ActivityCompat.requestPermissions(
                    act,
                    arrayOf(
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ),
                    2871,
                )
                true
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ActivityCompat.requestPermissions(
                    act,
                    arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                    2872,
                )
                true
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    fun requestNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val act = activityRef?.get()
            if (act != null) {
                return try {
                    ActivityCompat.requestPermissions(
                        act,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        2873,
                    )
                    true
                } catch (_: Exception) {
                    openNotificationSettings(context)
                }
            }
        }
        return openNotificationSettings(context)
    }

    fun diagnostics(context: Context): Map<String, Any?> {
        val ctx = context.applicationContext ?: context
        return mapOf(
            "location" to status(),
            "state" to stateStatus(),
            "usage" to usageStatus(ctx),
            "permissions" to permissions(ctx),
            "map" to AmapDiagnostics.snapshot(),
            "amapShadow" to AmapShadowEvaluator.diagnostics(ctx),
            "lastFlushAt" to lastFlushWallMs,
            "lastStateEmitAt" to lastStateEmitMs,
            "lastUsagePullAt" to lastUsagePullMs,
            "lastUsageEmitAt" to lastUsageEmitMs,
            "lastUsageRawCount" to lastUsageRawCount,
            "policySummary" to lastPolicySummary,
            "policyHalted" to policyHalted,
        )
    }

    /** 原生侧 fatal 落盘（注册类/采集类问题堆栈原文，logcat 截断兜底）。 */
    private fun fatal(context: Context, msg: String) {
        try {
            val dir = java.io.File(context.getExternalFilesDir(null), "peer-loc")
            if (!dir.exists()) dir.mkdirs()
            java.io.File(dir, "fatal-native.txt").appendText(
                "[${System.currentTimeMillis()}] $msg\n")
        } catch (_: Exception) {}
    }

    @Synchronized
    fun start(context: Context) {
        appContext = context.applicationContext
        if (listeners.isNotEmpty()) return
        val reason = startReason(context)
        if (reason != null) {
            log("start denied: $reason")
            return
        }
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        lm = manager
        val listener = LocationListener { onLocation(it) }
        listeners.add(listener)
        // fix7：心跳广播接收器随采集会话注册/注销（不写清单——本仓库约定
        // 只动这一处原生文件；进程由 FGS 保活，动态接收器足够）
        ensureHeartbeatReceiver(context)
        AmapShadowEvaluator.start(context)
        try {
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER,
                LocationDebounceConfig.MOVING_MIN_TIME_MS,
                LocationDebounceConfig.MOVING_MIN_DISTANCE_M,
                listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER,
                LocationDebounceConfig.MOVING_MIN_TIME_MS,
                LocationDebounceConfig.MOVING_MIN_DISTANCE_M,
                listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.PASSIVE_PROVIDER, 0L, 0f, listener, Looper.getMainLooper())
            adaptiveStationaryActive = false
            log("started: gps+network+passive (30m/30s adaptive; passive 0/0)")
        } catch (e: Exception) {
            log("start partial-error: ${e.message}") // provider 被系统关闭不整体失败
        }
    }

    /** 乙·自适应采样切换：STATIONARY_LOCKED 停 GPS 省电，仅留 NETWORK+PASSIVE 唤醒；MOVING 恢复 GPS。 */
    private fun updateAdaptiveSampling(target: DebounceState) {
        val manager = lm ?: return
        val listener = listeners.firstOrNull() ?: return
        if (target == DebounceState.STATIONARY_LOCKED && !adaptiveStationaryActive) {
            try {
                manager.removeUpdates(listener)
                manager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    LocationDebounceConfig.MOVING_MIN_TIME_MS,
                    LocationDebounceConfig.MOVING_MIN_DISTANCE_M,
                    listener,
                    Looper.getMainLooper())
                manager.requestLocationUpdates(
                    LocationManager.PASSIVE_PROVIDER, 0L, 0f, listener, Looper.getMainLooper())
                adaptiveStationaryActive = true
                log("adaptive -> STATIONARY_LOCKED (gps off, network+passive wakeup)")
            } catch (e: Exception) {
                log("adaptive stationary switch failed: ${e.message}")
            }
        } else if (target == DebounceState.MOVING && adaptiveStationaryActive) {
            try {
                manager.removeUpdates(listener)
                manager.requestLocationUpdates(
                    LocationManager.GPS_PROVIDER,
                    LocationDebounceConfig.MOVING_MIN_TIME_MS,
                    LocationDebounceConfig.MOVING_MIN_DISTANCE_M,
                    listener,
                    Looper.getMainLooper())
                manager.requestLocationUpdates(
                    LocationManager.NETWORK_PROVIDER,
                    LocationDebounceConfig.MOVING_MIN_TIME_MS,
                    LocationDebounceConfig.MOVING_MIN_DISTANCE_M,
                    listener,
                    Looper.getMainLooper())
                manager.requestLocationUpdates(
                    LocationManager.PASSIVE_PROVIDER, 0L, 0f, listener, Looper.getMainLooper())
                adaptiveStationaryActive = false
                log("adaptive -> MOVING (gps+network+passive restored)")
            } catch (e: Exception) {
                log("adaptive moving switch failed: ${e.message}")
            }
        }
    }

    @Synchronized
    fun stop() {
        // fix7：先摘闹钟与接收器（任何一条退出路径都必须取消，防泄漏/空转）
        cancelHeartbeat(appContext)
        unregisterHeartbeatReceiver()
        AmapShadowEvaluator.stop()
        // 原实现是 `val manager = lm ?: return` 提前返回，导致 lm 为空时
        // 不清理状态；这里改成「有就摘监听、无论如何清状态」
        val manager = lm
        if (manager != null) {
            for (l in listeners) { try { manager.removeUpdates(l) } catch (_: Exception) {} }
        }
        listeners.clear(); lm = null; queue.clear(); lastSent = null
        lastEnqueued = null; lastAccepted = null; lastSentAt = 0; lastFlushAt = 0
        debouncer.reset()
        adaptiveStationaryActive = false
        nextFlushAllowedAtElapsed = 0L
        stillMode = false; stillCount = 0; heartbeatTicks = 0
        flushing = false; flushPending = false
        log("stopped (queue cleared, heartbeat alarm cancelled)")
    }

    // ── 2.8.7 自动报备：设备状态采集（电量/网络/解锁/亮屏）─────────────
    //
    // 设计约束（详见 docs/auto-report-stage1-design.md §4）：
    // · 不新增任何 timer / 不建前台服务：全部挂在系统广播与 NetworkCallback 上；
    // · 采到的样本按阈值/窗口筛完后**只通过 MethodChannel 交给 Dart**，
    //   由既有文件队列做去重/毒丸/整批保留（不在这里另造一套上行）；
    // · toggleState(false) 注销全部接收器并清空窗口，**不 flush**（停采就停干净）。

    private var stateReceiver: BroadcastReceiver? = null
    private var stateNetCallback: ConnectivityManager.NetworkCallback? = null
    private var stateEnabled = false

    private var batEmittedLevel = -1
    private var batSeenCharging = -1
    private var batLastEmitMs = 0L
    private var netLastType = ""
    private var netLastSsid = ""
    private var netLastEmitMs = 0L
    private var ssidLastEmitMs = 0L
    private var unlockWindowStartMs = 0L
    private var unlockCount = 0
    private var screenOnAtMs = 0L
    private var stateEmitted = 0

    private fun nowMs(): Long = System.currentTimeMillis()

    /** 状态事件投递给 Dart（入队与冲刷都在 Dart 侧，原生不碰网络）。 */
    private fun emitState(kind: String, payload: Map<String, Any?>) {
        val messenger = stateMessenger ?: return
        val invoke = Runnable {
            try {
                MethodChannel(messenger, CHANNEL)
                    .invokeMethod("onStateSample", mapOf("kind" to kind, "payload" to payload))
                stateEmitted += 1
                lastStateEmitMs = nowMs()
            } catch (e: Exception) {
                log("emitState failed: ${e.message}") // 投递失败只记日志，不阻断采集
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            invoke.run()
        } else {
            handler.post(invoke)
        }
    }

    @Synchronized
    fun toggleState(context: Context, enable: Boolean): Map<String, Any?> {
        val ctx = context.applicationContext ?: context.applicationContext
        stateRequested = enable
        if (!enable) {
            stopStateCollection()
            return mapOf("ok" to true, "detail" to stateStatus())
        }
        // 停用期间开关想开也不采（恢复由 applyPolicy 统一拉起）
        if (policyHalted) {
            return mapOf("ok" to false, "reason" to "halted",
                "detail" to stateStatus())
        }
        startStateCollection(ctx)
        return mapOf("ok" to (stateReceiver != null), "detail" to stateStatus())
    }

    fun stateStatus(): Map<String, Any?> = mapOf(
        "enabled" to stateEnabled,
        "emitted" to stateEmitted,
        "unlockPending" to unlockCount,
        "inScreenSession" to (screenOnAtMs > 0L))

    @Synchronized
    private fun startStateCollection(ctx: Context) {
        if (stateReceiver != null) return
        stateEnabled = true
        // 新建会话：清闸门基线（否则上次会话的旧值会让首次变化被判成"没变"）
        batEmittedLevel = -1
        batSeenCharging = -1
        batLastEmitMs = 0L
        netLastType = ""
        netLastSsid = ""
        netLastEmitMs = 0L
        ssidLastEmitMs = 0L
        unlockWindowStartMs = 0L
        unlockCount = 0
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        screenOnAtMs = if (pm?.isInteractive == true) nowMs() else 0L

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_BATTERY_CHANGED -> onBattery(intent)
                    Intent.ACTION_USER_PRESENT -> onUnlock()
                    Intent.ACTION_SCREEN_ON -> if (screenOnAtMs == 0L) screenOnAtMs = nowMs()
                    Intent.ACTION_SCREEN_OFF -> onScreenOff()
                }
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                ctx.registerReceiver(receiver, filter)
            }
            stateReceiver = receiver
            log("state receiver registered")
        } catch (e: Exception) {
            log("state receiver register failed: ${e.message}")
            fatal(ctx, "state receiver register failed: ${e.message}")
            stateEnabled = false
            return
        }
        // 网络回调：注册后系统会立刻回调一次当前网络 → 首次采样不丢
        try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    onNetwork(caps)
                }
                override fun onLost(network: Network) {
                    onNetworkType("none", "")
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            stateNetCallback = cb
            log("state network callback registered")
        } catch (e: Exception) {
            log("network callback register failed: ${e.message}")
            fatal(ctx, "network callback register failed: ${e.message}")
        }
    }

    @Synchronized
    private fun stopStateCollection() {
        stateEnabled = false
        stateReceiver?.let { try { appContext?.unregisterReceiver(it) } catch (_: Exception) {} }
        stateReceiver = null
        stateNetCallback?.let {
            try {
                val ctx = appContext
                val cm = ctx?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                cm?.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        stateNetCallback = null
        // 停采清窗口：**不 flush**——不把"停用瞬间"的残值发出去
        unlockCount = 0
        unlockWindowStartMs = 0L
        screenOnAtMs = 0L
        log("state collection stopped (windows cleared, not flushed)")
    }

    // ── 应用使用采集（2.8.7 全量）──────────────────────────────────────
    // 形态：queryEvents 增量游标 + 跨调用保留的「进行中会话」；拉取只发生在
    // 既有唤醒点（心跳 tick / 熄屏 / Dart 回前台），**没有新定时器、没有 FGS**。
    // 脱敏在入队之前：命中 policy 的敏感包名 → 哨兵 masked.other。

    private var usageEnabled = false
    private var usageEmitted = 0
    private var usageCursorMs = 0L
    private var usageOpenPkg = ""
    private var usageOpenStart = 0L
    private var maskedPkgs: Set<String> = emptySet()
    private var foldShort = true
    private var usageFull = true     // usage_level == full/...（非 off）
    private var appStream = true     // app_level == stream（只有这档发「正在使用」）
    private var policyHalted = false
    private var stateRequested = false
    private var lastNowPkg = ""
    private var lastNowEmitMs = 0L
    private var launcherPkg: String? = null

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences("peer_usage", Context.MODE_PRIVATE)

    private fun loadUsageState(ctx: Context) {
        val p = prefs(ctx)
        usageCursorMs = p.getLong("cursor", 0L)
        usageOpenPkg = p.getString("open_pkg", "") ?: ""
        usageOpenStart = p.getLong("open_start", 0L)
        lastNowPkg = p.getString("now_pkg", "") ?: ""
        lastNowEmitMs = p.getLong("now_ms", 0L)
    }

    private fun saveUsageState(ctx: Context) {
        prefs(ctx).edit()
            .putLong("cursor", usageCursorMs)
            .putString("open_pkg", usageOpenPkg)
            .putLong("open_start", usageOpenStart)
            .putString("now_pkg", lastNowPkg)
            .putLong("now_ms", lastNowEmitMs)
            .apply()
    }

    /** `PACKAGE_USAGE_STATS` 是否已授权（AppOps 口径，各 ROM 一致）。 */
    fun hasUsageAccess(ctx: Context): Boolean = try {
        val appOps = ctx.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(), ctx.packageName)
        }
        mode == AppOpsManager.MODE_ALLOWED
    } catch (e: Exception) {
        log("usage access check failed: ${e.message}")
        false
    }

    fun usageStatus(ctx: Context): Map<String, Any?> = mapOf(
        "granted" to hasUsageAccess(ctx),
        "enabled" to usageEnabled,
        "emitted" to usageEmitted,
        "cursor" to usageCursorMs)

    /**
     * 已安装应用清单（敏感清单多选用）：包名 + 名称，只取有启动器入口的应用，
     * 排除本 App 自己；上限 200 条（够用，且不把通道撑爆）。
     */
    fun installedApps(ctx: Context): Map<String, Any?> {
        val pm = ctx.packageManager
        val out = mutableListOf<Map<String, String>>()
        try {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val list = pm.queryIntentActivities(intent, 0)
                .map { it.activityInfo.packageName }
                .distinct()
                .filter { it != ctx.packageName }
                .sorted()
            for (pkg in list.take(200)) {
                val label = try {
                    pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                } catch (e: Exception) {
                    pkg
                }
                out.add(mapOf("pkg" to pkg, "label" to label))
            }
        } catch (e: Exception) {
            log("installedApps failed: ${e.message}")
        }
        return mapOf("apps" to out)
    }

    /** 跳系统「使用情况访问」页（授权只能用户自己在系统页点）。 */
    fun openUsageSettings(ctx: Context): Boolean = try {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        true
    } catch (e: Exception) {
        log("open usage settings failed: ${e.message}")
        false
    }

    @Synchronized
    fun toggleUsage(ctx: Context, enable: Boolean): Map<String, Any?> {
        val c = ctx.applicationContext ?: ctx
        if (!enable) {
            usageEnabled = false
            log("usage collection stopped")
            return mapOf("ok" to true, "detail" to usageStatus(c))
        }
        if (policyHalted) {
            return mapOf("ok" to false, "reason" to "halted",
                "detail" to usageStatus(c))
        }
        if (!hasUsageAccess(c)) {
            // 未授权不报错、不弹窗：状态里如实说「未授权」，采集不启动
            return mapOf("ok" to false, "reason" to "no_permission",
                "detail" to usageStatus(c))
        }
        loadUsageState(c)
        usageEnabled = true
        log("usage collection started, cursor=$usageCursorMs")
        return mapOf("ok" to true, "detail" to usageStatus(c))
    }

    /** 手动拉一次（Dart 在 App 回前台/进页面时调用）。返回本次投递的会话数。 */
    fun pullUsage(ctx: Context): Map<String, Any?> {
        val c = ctx.applicationContext ?: ctx
        lastUsagePullMs = nowMs()
        if (!usageEnabled && !policyHalted && usageFull && !appOff && hasUsageAccess(c)) {
            loadUsageState(c)
            usageEnabled = true
        }
        val n = drainUsage(c)
        return mapOf("sessions" to n, "detail" to usageStatus(c))
    }

    /**
     * 分档策略下发：启停采集 + 脱敏清单 + 折叠开关 + 定位网格化。
     *
     * 停用（global_off / 暂停未到期）→ 停状态与使用采集（**不 flush**）。
     */
    @Synchronized
    fun applyPolicy(ctx: Context, policy: Map<String, Any?>): Map<String, Any?> {
        val c = ctx.applicationContext ?: ctx
        val globalOff = policy["global_off"] == true
        val until = (policy["paused_until"] as? Number)?.toDouble() ?: 0.0
        val pausedNow = until > System.currentTimeMillis() / 1000.0
        policyHalted = globalOff || pausedNow

        @Suppress("UNCHECKED_CAST")
        val pkgs = (policy["sensitive_pkgs"] as? List<*>) ?: emptyList<Any?>()
        maskedPkgs = pkgs.mapNotNull { it?.toString() }.filter { it.isNotEmpty() }.toSet()
        foldShort = policy["fold_short"] != false
        usageFull = (policy["usage_level"] ?: "full") != "off"
        appStream = (policy["app_level"] ?: "stream") == "stream"
        appOff = (policy["app_level"] ?: "stream") == "off"
        val locLevel = (policy["location_level"] ?: "exact").toString()
        val netLevel = (policy["network_level"] ?: "ssid").toString()
        gridStreet = locLevel == "street"
        lastPolicySummary =
            "halted=$policyHalted usage=${policy["usage_level"] ?: "full"} app=${policy["app_level"] ?: "stream"} loc=$locLevel net=$netLevel"

        if (policyHalted) {
            stopStateCollection()
            usageEnabled = false
        } else {
            if (stateRequested) startStateCollection(c)
            if (usageFull && !appOff && hasUsageAccess(c)) {
                loadUsageState(c)
                usageEnabled = true
            } else {
                usageEnabled = false
            }
        }
        log("policy applied: halted=$policyHalted masked=${maskedPkgs.size} " +
            "fold=$foldShort usage=$usageEnabled street=$gridStreet")
        return mapOf("ok" to true, "halted" to policyHalted,
            "usage" to usageEnabled, "street" to gridStreet)
    }

    /** 定位是否处于「仅街区」档（落点前圆整，服务端还会再兜一次）。 */
    private var gridStreet = false

    /**
     * 拉一次增量使用事件并投递。
     *
     * 只投**已闭合**的会话（`usage.session`）与「正在使用」（`usage.now`）。
     * 进行中的会话不按「end=now」反复上报：服务端 client_id 幂等是「已存在即
     * 忽略」，改不了数（反而可能双计），当前应用由 usage.now 表达。
     */
    private fun drainUsage(ctx: Context): Int {
        if (!usageEnabled || policyHalted) return 0
        val now = System.currentTimeMillis()
        val from = if (usageCursorMs > 0) usageCursorMs else now - 6 * 3600_000L
        val usm = ctx.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return 0
        // 注意写法：catch 分支给 null，再统一 `?: return 0`。
        // 把 `return 0` 塞进 try 表达式后面接 elvis 会让 Kotlin 推断成非目标类型
        // （CI 实测 Unresolved reference 'hasNext'）。
        val events = try {
            usm.queryEvents(from, now)
        } catch (e: Exception) {
            log("queryEvents failed: ${e.message}")
            null
        } ?: return 0

        // UsageEvents 的游标 API 是 hasNextEvent() / getNextEvent(out)——
        // 不是 Cursor 的 hasNext()/nextEvent()（CI 实测 unresolved）。
        val raw = ArrayList<UsageGates.Raw>()
        val ev = UsageEvents.Event()
        while (events.hasNextEvent()) {
            if (!events.getNextEvent(ev)) break
            val kind = ev.eventType
            if (kind != UsageGates.EVENT_RESUMED && kind != UsageGates.EVENT_PAUSED) continue
            val pkg = ev.packageName ?: continue
            if (isExcluded(ctx, pkg)) continue
            raw.add(UsageGates.Raw(pkg, ev.timeStamp,
                kind == UsageGates.EVENT_RESUMED))
        }
        raw.sortBy { it.ts }
        lastUsageRawCount = raw.size

        val open = UsageGates.sanitizeOpen(
            if (usageOpenPkg.isNotEmpty() && usageOpenStart > 0)
                UsageGates.Open(usageOpenPkg, usageOpenStart) else null, now)
        val paired = UsageGates.pairIncremental(open, raw)

        var emitted = 0
        for (s in paired.sessions) {
            val sec = s.durSec
            if (sec <= 0) continue
            if (UsageGates.shouldDrop(sec, foldShort)) continue // 端侧折叠：不入队
            val (pkg, masked) = UsageGates.mask(s.pkg, maskedPkgs)
            emitUsage("usage.session", mapOf(
                "pkg" to pkg,
                "app" to if (masked) UsageGates.MASK_APP else labelOf(ctx, s.pkg),
                "masked" to masked,
                "start" to s.start / 1000.0,
                "end" to s.end / 1000.0,
                "dur" to sec))
            emitted += 1
        }

        val running = paired.open
        if (running != null && appStream) {
            val (pkg, masked) = UsageGates.mask(running.pkg, maskedPkgs)
            if (UsageGates.shouldEmitNow(lastNowPkg, lastNowEmitMs, pkg, now)) {
                emitUsage("usage.now", mapOf(
                    "pkg" to pkg,
                    "app" to if (masked) UsageGates.MASK_APP else labelOf(ctx, running.pkg),
                    "masked" to masked,
                    "since" to running.start / 1000.0))
                lastNowPkg = pkg
                lastNowEmitMs = now
                emitted += 1
            }
        }

        usageOpenPkg = paired.open?.pkg ?: ""
        usageOpenStart = paired.open?.start ?: 0L
        usageCursorMs = UsageGates.advanceCursor(usageCursorMs, paired.maxTs, now)
        saveUsageState(ctx)
        if (emitted > 0) log("usage drained: $emitted, cursor=$usageCursorMs")
        return emitted
    }

    /** 自身 / 桌面 launcher / SystemUI 不记（照令文 §2.2 排除项）。 */
    private fun isExcluded(ctx: Context, pkg: String): Boolean {
        if (pkg == ctx.packageName) return true
        if (pkg == "com.android.systemui") return true
        val home = launcherPkg ?: try {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            val ri = ctx.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            ri?.activityInfo?.packageName
        } catch (_: Exception) {
            null
        }?.also { launcherPkg = it }
        return home != null && pkg == home
    }

    /** 应用名（解析不到就用包名，不编名字）。 */
    private fun labelOf(ctx: Context, pkg: String): String = try {
        val pm = ctx.packageManager
        val info = pm.getApplicationInfo(pkg, 0)
        pm.getApplicationLabel(info).toString()
    } catch (e: Exception) {
        pkg
    }

    private fun emitUsage(kind: String, payload: Map<String, Any?>) {
        val messenger = stateMessenger ?: return
        val invoke = Runnable {
            try {
                MethodChannel(messenger, CHANNEL)
                    .invokeMethod("onUsageSample", mapOf("kind" to kind, "payload" to payload))
                usageEmitted += 1
                lastUsageEmitMs = nowMs()
            } catch (e: Exception) {
                log("emitUsage failed: ${e.message}")
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            invoke.run()
        } else {
            handler.post(invoke)
        }
    }

    /** 电量：Δ≥2%（与**上次已报值**比）或充电翻转才报，60s 防抖。 */
    private fun onBattery(intent: Intent) {
        val level = intent.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
        val status = intent.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
        val charging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
        if (level < 0 || level > 100) return

        val now = nowMs()
        val chargingFlag = if (charging) 1 else 0
        val decision = StateGates.battery(
            level = level, chargingFlag = chargingFlag,
            emittedLevel = batEmittedLevel, seenCharging = batSeenCharging,
            lastEmitMs = batLastEmitMs, nowMs = now)
        batSeenCharging = chargingFlag // 看到即算（翻转判定基线）
        if (!decision) return
        batLastEmitMs = now
        batEmittedLevel = level
        emitState("state.battery", mapOf("level" to level, "charging" to charging))
    }

    private fun onNetwork(caps: NetworkCapabilities) {
        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            else -> "none"
        }
        val ssid = if (type == "wifi") readWifi() else ""
        onNetworkType(type, ssid)
    }

    /** 网络：类型变化即报（30s 防抖），SSID 抖动 5min 冷却。 */
    private fun onNetworkType(type: String, ssid: String) {
        val now = nowMs()
        val decision = StateGates.net(
            type = type, ssid = ssid,
            lastType = netLastType, lastSsid = netLastSsid,
            lastEmitMs = netLastEmitMs, ssidLastEmitMs = ssidLastEmitMs, nowMs = now)
        netLastType = type
        netLastSsid = ssid
        if (!decision) return
        netLastEmitMs = now
        if (type == "wifi") ssidLastEmitMs = now
        emitState("state.net", mapOf("net" to type, "ssid" to ssid))
    }

    private fun onUnlock() {
        if (unlockCount == 0) unlockWindowStartMs = nowMs()
        unlockCount += 1
        drainUnlockIfDue()
    }

    private fun onScreenOff() {
        val started = screenOnAtMs
        screenOnAtMs = 0L
        if (started > 0L) {
            val sec = StateGates.screenSessionSec(started, nowMs())
            if (sec > 0) emitState("state.screen", mapOf("session_sec" to sec, "on" to false))
        }
        drainUnlockIfDue()
        // 使用会话的唤醒点之一（令文 §2.2：骑既有唤醒点，不新增定时器）
        appContext?.let { drainUsage(it) }
    }

    /** 10 分钟窗口聚合：借解锁/熄屏事件自然触发，不新增定时器。 */
    private fun drainUnlockIfDue() {
        if (unlockCount == 0 || unlockWindowStartMs == 0L) return
        val now = nowMs()
        if (!StateGates.unlockDue(unlockCount, unlockWindowStartMs, now)) return
        emitState("state.unlock", mapOf(
            "count" to unlockCount,
            "window_sec" to ((now - unlockWindowStartMs) / 1000).toInt()))
        unlockCount = 0
        unlockWindowStartMs = 0L
    }

    // ── fix7：静止心跳真定时器（AlarmManager + 动态接收器）──────────────

    private fun heartbeatIntent(ctx: Context): PendingIntent {
        val intent = Intent(HEARTBEAT_ACTION).setPackage(ctx.packageName)
        return PendingIntent.getBroadcast(
            ctx, HEARTBEAT_REQUEST_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun ensureHeartbeatReceiver(ctx: Context) {
        if (heartbeatReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                if (intent?.action == HEARTBEAT_ACTION) onHeartbeatTick()
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.registerReceiver(r, IntentFilter(HEARTBEAT_ACTION),
                    Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                ctx.registerReceiver(r, IntentFilter(HEARTBEAT_ACTION))
            }
            heartbeatReceiver = r
            log("heartbeat receiver registered")
        } catch (e: Exception) {
            log("heartbeat receiver register failed: ${e.message}")
            fatal(ctx, "heartbeat receiver register failed: ${e.message}")
        }
    }

    private fun unregisterHeartbeatReceiver() {
        val r = heartbeatReceiver ?: return
        heartbeatReceiver = null
        try { appContext?.unregisterReceiver(r) } catch (_: Exception) {}
        log("heartbeat receiver unregistered")
    }

    /**
     * 挂下一次心跳。`ELAPSED_REALTIME_WAKEUP` 不受用户改时间影响；
     * `setAndAllowWhileIdle` 是 Doze 下唯一能穿透的闹钟档（深度 idle 会被
     * 节流到约 9–15 min 一次，验收口径 ≤30 min 仍满足）。
     *
     * fix8：锚点恒为 `lastSentAt + HEARTBEAT_MS`（不按 tick 时刻累加，避免
     * 漂移）；锚点已过则最早 1 s 后触发。同目标时刻重复调用只 set 一次。
     */
    private fun activeHeartbeatWindowMs(): Long =
        if (debouncer.state == DebounceState.STATIONARY_LOCKED) {
            LocationDebounceConfig.STATIONARY_HEARTBEAT_MS
        } else {
            STILL_HEARTBEAT_MS
        }

    private fun scheduleHeartbeat(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val now = SystemClock.elapsedRealtime()
        val at = HeartbeatGate.nextArmAt(now, lastSentAt, windowMs = activeHeartbeatWindowMs())
        if (heartbeatArmed && armedTarget == at) return
        try {
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, heartbeatIntent(ctx))
            heartbeatArmed = true
            armedTarget = at
            log("heartbeat alarm armed (in ${(at - now) / 1000}s)")
        } catch (e: Exception) {
            heartbeatArmed = false
            log("heartbeat alarm arm failed: ${e.message}")
        }
    }

    private fun cancelHeartbeat(ctx: Context?) {
        heartbeatArmed = false
        armedTarget = 0
        val c = ctx ?: appContext ?: return
        val am = c.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        try {
            am.cancel(heartbeatIntent(c))
            log("heartbeat alarm cancelled")
        } catch (_: Exception) {
        }
    }

    /** 采集中且有历史定位就维持闹钟（fix8 无回调兜底：不再要求 stillMode）。 */
    private fun maybeArmHeartbeat() {
        val ctx = appContext ?: return
        val running = listeners.isNotEmpty()
        val hasHistory = HeartbeatGate.hasHistory(lastAccepted != null, lastSent != null)
        if (!HeartbeatGate.shouldArm(running, hasHistory)) return
        scheduleHeartbeat(ctx)
    }

    /**
     * 闹钟 tick（主线程 = BroadcastReceiver.onReceive，与 onLocation 同线程，
     * 故 lastSentAt/stillMode/lastAccepted 无需加锁，天然串行）。
     *
     * fix8：不再要求 stillMode——只要**距上次上报满一个窗口**就产心跳点，
     * 这样「刚移动完立刻息屏」也能靠闹钟续上；窗口未满说明期间有正常回调，
     * 不补点、只按 `lastSentAt + HEARTBEAT_MS` 续挂。
     */
    @Synchronized
    private fun onHeartbeatTick() {
        heartbeatArmed = false
        heartbeatTicks++
        // 使用会话的唤醒点之二：心跳 tick（既有静止心跳，不新增定时器）
        appContext?.let { runCatching { drainUsage(it) } }
        val ctx = appContext
        val running = listeners.isNotEmpty()
        val hasHistory = HeartbeatGate.hasHistory(lastAccepted != null, lastSent != null)
        val now = SystemClock.elapsedRealtime()
        // 停采即收摊（开关关闭 / 422 自愈 / stop()）
        if (HeartbeatGate.shouldEndArm(running)) {
            log("hb tick: end arm (running=$running)")
            return
        }
        val winMs = activeHeartbeatWindowMs()
        if (!HeartbeatGate.shouldEmitOnTick(
                running, hasHistory, HeartbeatGate.due(now, lastSentAt, windowMs = winMs))) {
            // 本窗口已有回调出点（或尚无历史定位）→ 不补点，只按锚点续挂
            log("hb tick: gated (${(now - lastSentAt) / 1000}s < ${winMs / 1000}s) -> re-arm")
            ctx?.let { scheduleHeartbeat(it) }
            return
        }
        emitHeartbeat(now)
        ctx?.let { scheduleHeartbeat(it) }
    }

    /**
     * 心跳出点：STATIONARY_LOCKED 优先沿用锁定的真实锚点；
     * 否则沿用 [lastAccepted]（acc ≤ 50 的最后入点定位）造轨迹点；
     * 无历史点时只保鲜 latest。两者都做「刷新 lastSent + 立即 flush」，
     * 保证对方端最后在线不冻结。
     */
    private fun emitHeartbeat(atElapsed: Long) {
        val nowMs = System.currentTimeMillis()
        val lockedFix = debouncer.heartbeatFix(nowMs)
        // 口径二次校验：来源必须是 acc ≤ 50 的入点定位（[lastAccepted] 本来
        // 只存这类，这里是防将来有人改 lastAccepted 的写入条件）
        val src = lastAccepted?.takeIf {
            HeartbeatGate.heartbeatSourceAllowed(it.getDouble("acc"), ACC_LATEST_ONLY_M)
        }
        val prev = lastSent
        if (lockedFix == null && src == null && prev == null) {
            // 冷启动即静止且无任何历史定位：不造假点（下个 tick 再说）
            log("hb tick: cold start without any fix -> skip")
            return
        }
        val pn = cachedPlaceName
        val hbLat: Double
        val hbLng: Double
        if (lockedFix != null) {
            val point = JSONObject().apply {
                put("id", "pl-hb-$nowMs")
                put("ts", nowMs.toDouble())
                put("lat", lockedFix.lat)
                put("lng", lockedFix.lng)
                put("acc", lockedFix.acc)
                put("speed", 0.0)
                if (pn.isNotEmpty()) put("place_name", pn)
            }
            enqueue(point)
            lastEnqueued = point
            hbLat = lockedFix.lat
            hbLng = lockedFix.lng
            log("hb tick: locked anchor enqueued (acc=${lockedFix.acc})")
        } else if (src != null) {
            val point = JSONObject().apply {
                put("id", "pl-hb-$nowMs")
                put("ts", nowMs.toDouble())
                put("lat", src.getDouble("lat"))
                put("lng", src.getDouble("lng"))
                put("acc", src.getDouble("acc"))
                put("speed", 0.0) // 静止心跳，速度按 0 记
                if (pn.isNotEmpty()) put("place_name", pn)
            }
            enqueue(point)
            lastEnqueued = point
            hbLat = src.getDouble("lat")
            hbLng = src.getDouble("lng")
            log("hb tick: point enqueued (acc=${src.getDouble("acc")})")
        } else {
            hbLat = prev!!.getDouble("lat")
            hbLng = prev.getDouble("lng")
            log("hb tick: no acc<=50 history -> latest only (${prev.optDouble("battery", -1.0)})")
        }
        val lat = hbLat
        val lng = hbLng
        AmapShadowEvaluator.sampleAligned(
            context = appContext,
            trigger = "heartbeat",
            nativeTsMs = nowMs,
            nativeLatGcj = lat,
            nativeLngGcj = lng,
            nativeAcc = lockedFix?.acc ?: src?.optDouble("acc", 50.0) ?: 50.0,
            nativeProvider = "heartbeat",
            nativeSpeed = 0.0,
            nativeDebounce = if (lockedFix != null) "hb_anchor" else if (src != null) "hb_last" else "hb_latest",
            nativeState = debouncer.state.name,
        )
        lastSent = JSONObject().apply {
            put("lat", lat); put("lng", lng)
            put("battery", readBattery()); put("charging", readCharging())
            put("net", readNet()); put("wifi", readWifi())
            if (pn.isNotEmpty()) put("place_name", pn)
            put("ts", nowMs.toDouble())
        }
        lastSentAt = atElapsed
        // 直连 flush：queue 可能为空（只保鲜 latest），flush 已允许空 points 载荷
        flush()
    }

    /** Android OS Geocoder reverse lookup on single background thread (no third-party APIs). */
    private fun maybeGeocodeAsync(ctx: Context, wgsLat: Double, wgsLng: Double) {
        val now = System.currentTimeMillis()
        if (geocodeInFlight) return
        if (!PlaceFormatter.shouldRegeocode(
                lastGeocodeLat, lastGeocodeLng, lastGeocodeAtMs, wgsLat, wgsLng, now)) {
            return
        }
        if (!Geocoder.isPresent()) return
        geocodeInFlight = true
        val appCtx = ctx.applicationContext ?: ctx
        geocodeExecutor.execute {
            try {
                val geocoder = Geocoder(appCtx, Locale.CHINA)
                var first: Address? = null
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val latch = CountDownLatch(1)
                    geocoder.getFromLocation(wgsLat, wgsLng, 1) { list ->
                        first = list.firstOrNull()
                        latch.countDown()
                    }
                    latch.await(3, TimeUnit.SECONDS)
                } else {
                    @Suppress("DEPRECATION")
                    first = geocoder.getFromLocation(wgsLat, wgsLng, 1)?.firstOrNull()
                }
                val addr = first
                val formatted = if (addr != null) {
                    PlaceFormatter.formatAddress(
                        adminArea = addr.adminArea,
                        locality = addr.locality,
                        subLocality = addr.subLocality,
                        thoroughfare = addr.thoroughfare,
                        featureName = addr.featureName,
                        addressLine = if (addr.maxAddressLineIndex >= 0) addr.getAddressLine(0) else null,
                    )
                } else {
                    ""
                }
                if (formatted.isNotEmpty()) {
                    cachedPlaceName = formatted
                }
                lastGeocodeLat = wgsLat
                lastGeocodeLng = wgsLng
                lastGeocodeAtMs = System.currentTimeMillis()
            } catch (e: Exception) {
                log("geocode failed (ignored): ${e.message}")
                lastGeocodeLat = wgsLat
                lastGeocodeLng = wgsLng
                lastGeocodeAtMs = System.currentTimeMillis()
            } finally {
                geocodeInFlight = false
            }
        }
    }

    // ── 采集与判定 ──────────────────────────────────────────────────────

    private fun onLocation(location: Location) {
        receivedCount++
        lastReceivedAt = System.currentTimeMillis()
        appContext?.let { maybeGeocodeAsync(it, location.latitude, location.longitude) }
        val acc = if (location.hasAccuracy()) location.accuracy.toDouble() else 9999.0
        val gcj = wgs84ToGcj02(location.latitude, location.longitude)
        val rawSpeed = if (location.hasSpeed()) location.speed.toDouble() else null
        val outcome = debouncer.process(
            RawFix(
                lat = gcj.first,
                lng = gcj.second,
                acc = acc,
                speed = rawSpeed,
                timeMs = location.time,
            ),
        )
        val debounceTag = when (outcome) {
            is DebounceOutcome.Emit -> if (outcome.isAnchor) "emit_anchor" else "emit_move"
            is DebounceOutcome.Drop -> "drop_${outcome.reason.name.lowercase(Locale.ROOT)}"
        }
        AmapShadowEvaluator.sampleAligned(
            context = appContext,
            trigger = "callback",
            nativeTsMs = location.time,
            nativeLatGcj = gcj.first,
            nativeLngGcj = gcj.second,
            nativeAcc = acc,
            nativeProvider = location.provider ?: "",
            nativeSpeed = rawSpeed,
            nativeDebounce = debounceTag,
            nativeState = debouncer.state.name,
        )
        updateAdaptiveSampling(debouncer.state)
        when (outcome) {
            is DebounceOutcome.Drop -> {
                if (outcome.reason != DropReason.STATIONARY_ABSORBED) {
                    droppedCount++
                }
                if (outcome.state == DebounceState.STATIONARY_LOCKED) {
                    stillMode = true
                }
                log("debounce drop: ${outcome.reason} state=${outcome.state} acc=${acc}m")
                maybeArmHeartbeat()
                return
            }
            is DebounceOutcome.Emit -> {
                val f = outcome.fix
                stillMode = (outcome.state == DebounceState.STATIONARY_LOCKED)
                if (!stillMode) stillCount = 0
                val pn = cachedPlaceName
                val point = JSONObject().apply {
                    put("id", "pl-${f.timeMs}")
                    put("ts", f.timeMs.toDouble())
                    put("lat", f.lat)
                    put("lng", f.lng)
                    put("acc", f.acc)
                    put("speed", f.speed ?: 0.0)
                    if (pn.isNotEmpty()) put("place_name", pn)
                }
                if (f.acc <= ACC_LATEST_ONLY_M) {
                    enqueue(point)
                    lastAccepted = JSONObject().apply {
                        put("lat", f.lat); put("lng", f.lng); put("acc", f.acc)
                    }
                }
                lastEnqueued = point
                lastSent = JSONObject().apply {
                    put("lat", f.lat); put("lng", f.lng)
                    put("battery", readBattery()); put("charging", readCharging())
                    put("net", readNet()); put("wifi", readWifi())
                    if (pn.isNotEmpty()) put("place_name", pn)
                    put("ts", System.currentTimeMillis().toDouble())
                }
                lastSentAt = SystemClock.elapsedRealtime()
                maybeArmHeartbeat()
                maybeFlush()
            }
        }
    }

    private fun enqueue(point: JSONObject) {
        // 「仅街区」档：入队前就把坐标圆整到 0.005°（≈500m）——
        // 端侧先行是隐私优先，服务端还会再兜一次（两道都不许漏）。
        if (gridStreet) {
            try {
                point.put("lat", UsageGates.gridRound(point.getDouble("lat")))
                point.put("lng", UsageGates.gridRound(point.getDouble("lng")))
            } catch (e: Exception) {
                log("grid round failed: ${e.message}")
            }
        }
        while (queue.size >= QUEUE_MAX) { queue.removeFirst(); log("queue overflow -> drop oldest") }
        queue.addLast(point)
        log("enqueued (n=${queue.size})")
    }

    private fun maybeFlush() {
        if (lastSent == null) return
        val now = SystemClock.elapsedRealtime()
        if (nextFlushAllowedAtElapsed > 0L && now < nextFlushAllowedAtElapsed) return
        val due = queue.size >= BATCH_MAX ||
            (queue.isNotEmpty() && now - lastFlushAt >= BATCH_FLUSH_MS)
        if (due) flush()
    }

    // ── 原生上报（HttpURLConnection 零依赖）────────────────────────────

    /**
     * fix7：允许 **空 points 载荷**——心跳 tick 只保鲜 latest 时队列为空，
     * 也要把 latest 送出去（否则断档期间对方端「最后在线」冻结）。
     * 后端 `POST /api/peer/location` 对空 points 合法（`body.get('points') or []`
     * → 循环空转，只写 latest）。
     *
     * fix8：单飞 + 主线程快照。
     * · 在途请求只允许一个（`flushing`）；在途期间的新请求只置 `flushPending`，
     *   由收尾回调补发一轮——原实现会 spawn 多个线程取同一批，各自按
     *   batch.length() 累加 `reportedCount`，导致卡面「已报」虚高。
     * · `queue` 是 ArrayDeque，不能被主线程写、后台线程读。这里在 main
     *   线程切片成 id 列表 + 已序列化的 payload 字符串，后台线程只见快照。
     */
    private fun flush() {
        if (!FlushGate.canStart(flushing)) {
            flushPending = true
            log("flush skipped: in-flight -> pending")
            return
        }
        val urlBase = baseUrl ?: return
        val cookie = sessionCookie ?: return
        if (queue.isEmpty() && lastSent == null) return

        // ── main 线程快照（此后不再碰 queue / lastSent）──────────────
        val n = minOf(BATCH_MAX, queue.size)
        val ids = ArrayList<String>(n)
        val pts = JSONArray()
        var i = 0
        for (p in queue) {
            if (i++ >= n) break
            ids.add(p.optString("id"))
            pts.put(p)
        }
        // lastSent 是会被重新赋值的可变对象 → 深拷贝一份字符串再解析
        val latestCopy = lastSent?.let {
            runCatching { JSONObject(it.toString()) }.getOrNull()
        }
        val payload = JSONObject().apply {
            put("points", pts)
            if (latestCopy != null) put("latest", latestCopy)
        }.toString()

        flushing = true
        flushPending = false
        Thread {
            var ok = false
            var accepted = 0
            var selfHeal = false
            try {
                val conn = URL("$urlBase/api/peer/location").openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 10_000
                conn.readTimeout = 15_000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Cookie", cookie)
                conn.setRequestProperty("X-Love-Space", "1")
                OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(payload) }
                val code = conn.responseCode
                ok = code in 200..299
                if (ok) {
                    // fix8：按服务端 accepted 计数（幂等 dup/非法行不计）
                    val text = try {
                        conn.inputStream.bufferedReader().use { it.readText() }
                    } catch (_: Exception) {
                        ""
                    }
                    accepted = FlushGate.parseAccepted(text)
                } else {
                    lastError = "HTTP $code"
                    // 上报者开关关闭 422 → 端上自愈：停报清队列（提示词对齐修订 6）
                    if (code == 422) selfHeal = true
                }
                conn.disconnect()
            } catch (e: Exception) {
                lastError = e.message ?: e.toString()
            }
            // 收尾一律回 main 线程：先放锁，再按快照处理队列与计数
            handler.post {
                flushing = false
                if (selfHeal) {
                    queue.clear()
                    stop()
                    log("422 -> self-heal: stop & clear")
                } else if (ok) {
                    // 按快照 id 从队头移除（只删本次提交的；队头已变则停手）
                    for (id in ids) {
                        val head = queue.firstOrNull() ?: break
                        if (head.optString("id") != id) break
                        queue.removeFirst()
                    }
                    reportedCount += accepted
                    lastFlushAt = SystemClock.elapsedRealtime()
                    lastFlushWallMs = System.currentTimeMillis()
                    debouncer.recordSuccess()
                    nextFlushAllowedAtElapsed = 0L
                    log("flush ok n=${ids.size} accepted=$accepted " +
                        "(reported=$reportedCount, queue=${queue.size})")
                } else {
                    val delayMs = debouncer.recordFailure()
                    nextFlushAllowedAtElapsed = SystemClock.elapsedRealtime() + delayMs
                    log("flush fail (queue=${queue.size}) backoff=${delayMs / 1000}s err=$lastError")
                }
                // 尾随补发：仅在成功路径（失败立即重试会在无网夜空转打点，
                // 留给下一个 tick / 回调再发）
                val tail = FlushGate.shouldTailFlush(
                    flushPending, ok && !selfHeal, listeners.isNotEmpty())
                flushPending = false
                if (tail) flush()
            }
        }.start()
    }

    // ── 状态附带（读不到给空不报错）────────────────────────────────────

    // 电量/充电：sticky BATTERY_CHANGED 广播（免 receiver 生命周期）
    private fun readBattery(): Int = try {
        val ctx = appContext ?: return -1
        val intent = ctx.registerReceiver(null,
            android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        intent?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
    } catch (_: Exception) { -1 }

    private fun readCharging(): Boolean = try {
        val ctx = appContext ?: return false
        val intent = ctx.registerReceiver(null,
            android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
    } catch (_: Exception) { false }

    // 网络类型：ConnectivityManager activeNetwork 能力判定（wifi/cell/none）
    private fun readNet(): String = try {
        val ctx = appContext ?: return ""
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val nw = cm.activeNetwork ?: return "none"
        val caps = cm.getNetworkCapabilities(nw)
        when {
            caps == null -> "none"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            else -> "other"
        }
    } catch (_: Exception) { "" }

    // Wi-Fi SSID：定位权限已覆盖读取（读不到给空，不报错）
    private fun readWifi(): String = try {
        val ctx = appContext ?: return ""
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE)
            as android.net.wifi.WifiManager
        val ssid = wifi.connectionInfo?.ssid?.trim('"') ?: ""
        if (ssid.startsWith("<unknown")) "" else ssid
    } catch (_: Exception) { ""
    }

    // ── GCJ-02（端上转换，后端入库统一 GCJ-02）──────────────────────────

    private const val A = 6378245.0
    private const val EE = 0.00669342162296594323

    private fun outOfChina(lat: Double, lng: Double): Boolean =
        lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271

    private fun tLat(x: Double, y: Double): Double {
        var r = -100.0 + 2.0*x + 3.0*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        r += (20.0*sin(6.0*x*PI) + 20.0*sin(2.0*x*PI)) * 2.0/3.0
        r += (20.0*sin(y*PI) + 40.0*sin(y/3.0*PI)) * 2.0/3.0
        r += (160.0*sin(y/12.0*PI) + 320.0*sin(y*PI/30.0)) * 2.0/3.0
        return r
    }
    private fun tLng(x: Double, y: Double): Double {
        var r = 300.0 + x + 2.0*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        r += (20.0*sin(6.0*x*PI) + 20.0*sin(2.0*x*PI)) * 2.0/3.0
        r += (20.0*sin(x*PI) + 40.0*sin(x/3.0*PI)) * 2.0/3.0
        r += (150.0*sin(x/12.0*PI) + 300.0*sin(x/30.0*PI)) * 2.0/3.0
        return r
    }

    /** WGS-84 → GCJ-02（境外原样返回）。 */
    fun wgs84ToGcj02(lat: Double, lng: Double): Pair<Double, Double> {
        if (outOfChina(lat, lng)) return Pair(lat, lng)
        var dLat = tLat(lng - 105.0, lat - 35.0)
        var dLng = tLng(lng - 105.0, lat - 35.0)
        val radLat = lat / 180.0 * PI
        var magic = sin(radLat)
        magic = 1 - EE * magic * magic
        val sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI)
        dLng = (dLng * 180.0) / (A / sqrtMagic * cos(radLat) * PI)
        return Pair(lat + dLat, lng + dLng)
    }

    private fun distanceMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val r = 6371000.0
        val dLat = (lat2 - lat1) * PI / 180.0
        val dLng = (lng2 - lng1) * PI / 180.0
        val s = sin(dLat/2)*sin(dLat/2) +
            cos(lat1*PI/180)*cos(lat2*PI/180)*sin(dLng/2)*sin(dLng/2)
        return r * 2 * atan2(sqrt(s), sqrt(1 - s))
    }
}

/**
 * fix7 静止心跳的**纯决策**（不碰 Android API，JVM 单测直接覆盖）。
 *
 * 抽出来的理由：真正的风险不在四则运算，而在「判定条件写错/漏一条」——
 * 旧实现就是门控写进 onLocation 且 `heartbeat` 变量置后无人消费，导致
 * 去重把心跳点全杀了。把这几条判定集中成纯函数，单测能锁住：
 * · 满窗口才出点（防双发）
 * · 运行中且静止才出点（停止/恢复行进即收摊）
 * · 连续 N 次静止才进 stillMode（且不重复挂表）
 *
 * **不被单测覆盖的部分**（回执已注明）：AlarmManager 在真机 Doze 下是否
 * 准时触发、动态接收器是否收到广播——这两条只能真机 `dumpsys deviceidle`
 * + logcat 实测，JVM 单测无法证明。
 */
internal object HeartbeatGate {
    /** 心跳窗口（5 min）。生产侧 `STILL_HEARTBEAT_MS` 引用此值，改参只改这里。 */
    const val HEARTBEAT_MS = 5 * 60_000L

    /** 连续多少次「位移 <25 m」判定进入静止。 */
    const val STILL_CONFIRM_TIMES = 3

    /** 锚点已过时最早多久后触发（防立刻连打）。 */
    const val MIN_ARM_DELAY_MS = 1_000L

    /** 距上次上报是否已满一个心跳窗口（定时器与回调两路共用，先到者为准）。 */
    fun due(
        nowElapsed: Long,
        lastSentAtElapsed: Long,
        windowMs: Long = HEARTBEAT_MS,
    ): Boolean = nowElapsed - lastSentAtElapsed >= windowMs

    /** 是否进入静止态（已静止不重复触发，避免重复挂表）。 */
    fun shouldEnterStill(
        stillCount: Int,
        alreadyStill: Boolean,
        confirmTimes: Int = STILL_CONFIRM_TIMES,
    ): Boolean = !alreadyStill && stillCount >= confirmTimes

    /** 是否已有可复用定位（acc≤50 入点定位 或 latest 快照）——无历史不挂表。 */
    fun hasHistory(hasAccepted: Boolean, hasSent: Boolean): Boolean = hasAccepted || hasSent

    /** fix8 持续兜底：只要采集中且已有历史定位就一直挂表（不再要求 stillMode）。 */
    fun shouldArm(running: Boolean, hasHistory: Boolean): Boolean = running && hasHistory

    /** tick 的退出条件：采集已停（开关关闭 / 422 自愈 / stop）→ 收摊。 */
    fun shouldEndArm(running: Boolean): Boolean = !running

    /** tick 是否该产点：运行中 + 有历史 + 满窗口（三条全真）。 */
    fun shouldEmitOnTick(running: Boolean, hasHistory: Boolean, due: Boolean): Boolean =
        running && hasHistory && due

    /**
     * 下一次挂表的目标时刻（elapsed）：**恒以 `lastSentAt + 窗口` 为锚点**，
     * 不按 tick 时刻累加（否则每次 tick 都把下一次推后 5 min，漂移累积）；
     * 锚点已过去则取 `now + MIN_ARM_DELAY_MS` 立刻补一跳。
     */
    fun nextArmAt(
        nowElapsed: Long,
        lastSentAtElapsed: Long,
        windowMs: Long = HEARTBEAT_MS,
        minDelayMs: Long = MIN_ARM_DELAY_MS,
    ): Long {
        val anchor = lastSentAtElapsed + windowMs
        val earliest = nowElapsed + minDelayMs
        return if (anchor > earliest) anchor else earliest
    }

    /**
     * 心跳点能否入轨迹（acc 口径）：只接受 acc ≤ [accLatestOnlyM] 的来源定位，
     * 50–100 的定位只许保鲜 latest，不许拿来造轨迹点。
     */
    fun heartbeatSourceAllowed(acc: Double, accLatestOnlyM: Double = 50.0): Boolean =
        acc <= accLatestOnlyM
}

/**
 * fix8 flush 纯决策（JVM 单测覆盖）：单飞开关与 `accepted` 解析。
 *
 * 单飞的意义：旧实现每次入队 ≥5 条就 spawn 一个上报线程，多个线程取同一批，
 * 各自 2xx 后都累加计数 → 「已报」虚高。这里把「能不能开跑」「收尾要不要补发」
 * 「怎么读 accepted」三条判定抽成纯函数，避免以后再被随手改坏。
 */
internal object FlushGate {
    /** 无在途请求才允许开跑。 */
    fun canStart(flushing: Boolean): Boolean = !flushing

    /**
     * 收尾后是否补发一轮：有尾随请求 **且本次成功** **且仍在采集**。
     * 失败不补发——无网时立即重试等于空转打点，交给下一个 tick/回调。
     */
    fun shouldTailFlush(pending: Boolean, succeeded: Boolean, running: Boolean): Boolean =
        pending && succeeded && running

    /**
     * 解析 `POST /api/peer/location` 响应的 `accepted`
     * （`app/main.py:1852` → `{'ok': True, 'accepted': <int>}`）。
     *
     * **刻意不用 `org.json.JSONObject`**：本对象是 JVM 单测的目标，而 android.jar
     * 在单测里是 Stub——`JSONObject` 未配置 `returnDefaultValues` 时直接抛
     * `Stub!`、配置后又返回 null，两种情况都会让「解析正确性」在无真机环境下
     * 根本验证不了（CI 也跑不出结论）。响应形状由本仓后端固定（单个整数键），
     * 这里按 `"accepted"` 后的数字做严格提取：
     * 空体 / 非 JSON / 缺字段 / 负数 / 非数字一律 0，绝不抛异常。
     */
    fun parseAccepted(body: String?): Int {
        if (body.isNullOrBlank()) return 0
        val key = "\"accepted\""
        val start = body.indexOf(key)
        if (start < 0) return 0
        var j = start + key.length
        // 跳过 `:` 与空白（不同 JSON 序列化器的分隔符风格不同，均容忍）
        while (j < body.length && (body[j] == ':' || body[j].isWhitespace())) j++
        val sb = StringBuilder()
        while (j < body.length) {
            val c = body[j]
            if (c == '-' || c.isDigit() || c == '"') {
                if (c != '"') sb.append(c)
                j++
            } else {
                break
            }
        }
        val n = sb.toString().toIntOrNull() ?: return 0
        return if (n > 0) n else 0
    }
}

/**
 * 2.8.7 状态事件的判定口径（纯函数，JVM 单测可覆盖）。
 *
 * 抽出来的理由：阈值/防抖是这段逻辑里唯一"会算错"的部分，埋在 BroadcastReceiver
 * 里就只能靠真机试；抽成顶层 object 后与 Dart 侧 state_aggregator.dart 一一对应。
 */
internal object StateGates {
    const val BATTERY_DELTA = 2
    const val BATTERY_MIN_INTERVAL_MS = 60_000L
    const val NET_MIN_INTERVAL_MS = 30_000L
    const val SSID_COOLDOWN_MS = 5 * 60_000L
    const val UNLOCK_WINDOW_MS = 10 * 60_000L

    /**
     * 电量是否该上报。
     *
     * 关键：`moved` 与**上次已报值**比（不是上次读数）——逐 1% 的读数如果跟读数
     * 比永远攒不到 2%；防抖窗口内被压住时也不更新已报值，变化不会丢。
     */
    fun battery(
        level: Int,
        chargingFlag: Int,
        emittedLevel: Int,
        seenCharging: Int,
        lastEmitMs: Long,
        nowMs: Long,
    ): Boolean {
        if (level < 0 || level > 100) return false
        val flipped = seenCharging >= 0 && seenCharging != chargingFlag
        val moved = emittedLevel < 0 || kotlin.math.abs(level - emittedLevel) >= BATTERY_DELTA
        if (!flipped && !moved) return false
        if (lastEmitMs > 0L && nowMs - lastEmitMs < BATTERY_MIN_INTERVAL_MS) return false
        return true
    }

    /** 网络是否该上报：类型变化即报；纯 SSID 抖动走 5min 冷却；整体 30s 防抖。 */
    fun net(
        type: String,
        ssid: String,
        lastType: String,
        lastSsid: String,
        lastEmitMs: Long,
        ssidLastEmitMs: Long,
        nowMs: Long,
    ): Boolean {
        if (type !in setOf("wifi", "cell", "none")) return false
        val first = lastType.isEmpty()
        val typeChanged = !first && lastType != type
        val ssidChanged = type == "wifi" && lastSsid.isNotEmpty() && lastSsid != ssid
        if (!first && !typeChanged && !ssidChanged) return false
        if (ssidChanged && !typeChanged && ssidLastEmitMs > 0L &&
            nowMs - ssidLastEmitMs < SSID_COOLDOWN_MS) return false
        if (lastEmitMs > 0L && nowMs - lastEmitMs < NET_MIN_INTERVAL_MS) return false
        return true
    }

    fun unlockDue(count: Int, windowStartMs: Long, nowMs: Long): Boolean =
        count > 0 && windowStartMs > 0L && nowMs - windowStartMs >= UNLOCK_WINDOW_MS

    fun screenSessionSec(startedAtMs: Long, nowMs: Long): Int {
        // 只把负数当「无会话」：0 是合法时间戳（测试与冷启动），用它当哨兵会
        // 把 0→120s 的真实会话算成 0（本单测第一版就是这么红的）。
        if (startedAtMs < 0L) return 0
        return ((nowMs - startedAtMs) / 1000L).toInt()
    }
}
