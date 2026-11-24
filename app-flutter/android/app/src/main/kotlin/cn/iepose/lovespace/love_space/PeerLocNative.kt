package cn.iepose.lovespace.love_space

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
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

    // 会话凭据（Dart 端 start 注入；进程内保存，服务被杀随进程消失）
    private var sessionCookie: String? = null
    private var baseUrl: String? = null
    private var appContext: Context? = null

    // 采集态
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
                "status" -> result.success(status())
                "exportFatal" -> result.success(exportFatalLog())
                // ── 2.8.0 fix6 B3：电池优化豁免（设置卡入口）──────────
                // 状态查询走平台 API（PowerManager），不做任何推断；
                // 申请走系统对话框（ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS），
                // 是否真的豁免由系统决定，本层只回传「意图是否送出」。
                "batteryIgnored" -> result.success(batteryIgnored(context))
                "requestIgnoreBattery" -> result.success(requestIgnoreBattery(context))
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
    fun status(): Map<String, Any?> = mapOf(
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
        "error" to lastError)

    /** fatal 日志导出（验证卡导出/分享入口——机主拿得出来才算落盘完成）。 */
    fun exportFatalLog(): Map<String, Any?> {
        val ctx = appContext
        val f = java.io.File(
            (ctx?.getExternalFilesDir(null) ?: ctx?.filesDir), "peer-loc${java.io.File.separator}fatal-native.txt")
        val content = if (f.exists()) f.readText() else ""
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
        try {
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, MIN_TIME_MS, MIN_DISTANCE_M, listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER, MIN_TIME_MS, MIN_DISTANCE_M, listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.PASSIVE_PROVIDER, 0L, 0f, listener, Looper.getMainLooper())
            log("started: gps+network+passive (25m/15s; passive 0/0)")
        } catch (e: Exception) {
            log("start partial-error: ${e.message}") // provider 被系统关闭不整体失败
        }
    }

    @Synchronized
    fun stop() {
        // fix7：先摘闹钟与接收器（任何一条退出路径都必须取消，防泄漏/空转）
        cancelHeartbeat(appContext)
        unregisterHeartbeatReceiver()
        // 原实现是 `val manager = lm ?: return` 提前返回，导致 lm 为空时
        // 不清理状态；这里改成「有就摘监听、无论如何清状态」
        val manager = lm
        if (manager != null) {
            for (l in listeners) { try { manager.removeUpdates(l) } catch (_: Exception) {} }
        }
        listeners.clear(); lm = null; queue.clear(); lastSent = null
        lastEnqueued = null; lastAccepted = null; lastSentAt = 0; lastFlushAt = 0
        stillMode = false; stillCount = 0; heartbeatTicks = 0
        flushing = false; flushPending = false
        log("stopped (queue cleared, heartbeat alarm cancelled)")
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
    private fun scheduleHeartbeat(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val now = SystemClock.elapsedRealtime()
        val at = HeartbeatGate.nextArmAt(now, lastSentAt)
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
        val ctx = appContext
        val running = listeners.isNotEmpty()
        val hasHistory = HeartbeatGate.hasHistory(lastAccepted != null, lastSent != null)
        val now = SystemClock.elapsedRealtime()
        // 停采即收摊（开关关闭 / 422 自愈 / stop()）
        if (HeartbeatGate.shouldEndArm(running)) {
            log("hb tick: end arm (running=$running)")
            return
        }
        if (!HeartbeatGate.shouldEmitOnTick(
                running, hasHistory, HeartbeatGate.due(now, lastSentAt))) {
            // 本窗口已有回调出点（或尚无历史定位）→ 不补点，只按锚点续挂
            log("hb tick: gated (${(now - lastSentAt) / 1000}s < ${STILL_HEARTBEAT_MS / 1000}s) -> re-arm")
            ctx?.let { scheduleHeartbeat(it) }
            return
        }
        emitHeartbeat(now)
        ctx?.let { scheduleHeartbeat(it) }
    }

    /**
     * 心跳出点：优先用 [lastAccepted]（acc ≤ 50 的最后入点定位）造轨迹点；
     * 无历史点时只保鲜 latest。两者都做「刷新 lastSent + 立即 flush」，
     * 保证对方端最后在线不冻结。
     */
    private fun emitHeartbeat(atElapsed: Long) {
        val nowMs = System.currentTimeMillis()
        // 口径二次校验：来源必须是 acc ≤ 50 的入点定位（[lastAccepted] 本来
        // 只存这类，这里是防将来有人改 lastAccepted 的写入条件）
        val src = lastAccepted?.takeIf {
            HeartbeatGate.heartbeatSourceAllowed(it.getDouble("acc"), ACC_LATEST_ONLY_M)
        }
        val prev = lastSent
        if (src == null && prev == null) {
            // 冷启动即静止且无任何历史定位：不造假点（下个 tick 再说）
            log("hb tick: cold start without any fix -> skip")
            return
        }
        if (src != null) {
            val point = JSONObject().apply {
                put("id", "pl-hb-$nowMs")
                put("ts", nowMs.toDouble())
                put("lat", src.getDouble("lat"))
                put("lng", src.getDouble("lng"))
                put("acc", src.getDouble("acc"))
                put("speed", 0.0) // 静止心跳，速度按 0 记
            }
            enqueue(point)
            lastEnqueued = point
            log("hb tick: point enqueued (acc=${src.getDouble("acc")})")
        } else {
            log("hb tick: no acc<=50 history -> latest only (${prev!!.optDouble("battery", -1.0)})")
        }
        val lat = src?.getDouble("lat") ?: prev!!.getDouble("lat")
        val lng = src?.getDouble("lng") ?: prev!!.getDouble("lng")
        lastSent = JSONObject().apply {
            put("lat", lat); put("lng", lng)
            put("battery", readBattery()); put("charging", readCharging())
            put("net", readNet()); put("wifi", readWifi())
            put("ts", nowMs.toDouble())
        }
        lastSentAt = atElapsed
        // 直连 flush：queue 可能为空（只保鲜 latest），flush 已允许空 points 载荷
        flush()
    }

    // ── 采集与判定 ──────────────────────────────────────────────────────

    private fun onLocation(location: Location) {
        receivedCount++
        lastReceivedAt = System.currentTimeMillis()
        val acc = if (location.hasAccuracy()) location.accuracy.toDouble() else 9999.0
        // 精度过滤：acc>100 丢弃
        if (acc > ACC_DROP_M) {
            droppedCount++; log("drop: acc=${acc}m > ${ACC_DROP_M}m"); return
        }
        val gcj = wgs84ToGcj02(location.latitude, location.longitude)
        // 位移判定（与上次上报点比较，米）
        val moved = lastSent?.let {
            distanceMeters(it.getDouble("lat"), it.getDouble("lng"), gcj.first, gcj.second)
        } ?: Double.MAX_VALUE
        var heartbeat = false
        if (moved < MIN_DISTANCE_M) {
            stillCount++
            if (HeartbeatGate.shouldEnterStill(stillCount, stillMode)) {
                stillMode = true
                log("still confirmed x$stillCount -> heartbeat ${STILL_HEARTBEAT_MS / 1000}s")
            }
        } else {
            if (stillMode) log("movement resumed (moved=${moved.toInt()}m) -> active pace")
            stillCount = 0; stillMode = false
        }
        // 静止心跳 5 min 时间门控（与定时器共用 lastSentAt，先到者为准）：
        // 门控未到直接丢弃本次回调（PASSIVE/重复 provider 高频触发，
        // 不能每帧都当心跳入点）
        if (stillMode) {
            val now = SystemClock.elapsedRealtime()
            if (!HeartbeatGate.due(now, lastSentAt)) {
                log("still heartbeat gated (${(now - lastSentAt) / 1000}s < ${STILL_HEARTBEAT_MS / 1000}s)")
                return
            }
            heartbeat = true
        }
        // 多 provider 去重：与上一个**入队**点 <10 m 视为同位置重复回调。
        // fix7：心跳点豁免——静止点必然 <10 m，豁免否则心跳永远入不了队
        if (!heartbeat) {
            lastEnqueued?.let {
                if (distanceMeters(it.getDouble("lat"), it.getDouble("lng"),
                        gcj.first, gcj.second) < 10.0) {
                    log("dedup: same spot as last enqueued (${location.provider})")
                    return
                }
            }
        }
        val point = JSONObject().apply {
            put("id", "pl-${location.time}")
            put("ts", location.time.toDouble())
            put("lat", gcj.first)
            put("lng", gcj.second)
            put("acc", acc)
            put("speed", if (location.hasSpeed()) location.speed.toDouble() else 0.0)
        }
        // 精度分层：50<acc≤100 只更新 latest，不入轨迹 points
        if (acc <= ACC_LATEST_ONLY_M) {
            enqueue(point)
            // fix7：记住「最后一条 acc ≤ 50 的入点定位」，心跳点只从它复制
            lastAccepted = JSONObject().apply {
                put("lat", gcj.first); put("lng", gcj.second); put("acc", acc)
            }
        }
        lastEnqueued = point
        lastSent = JSONObject().apply {
            put("lat", gcj.first); put("lng", gcj.second)
            put("battery", readBattery()); put("charging", readCharging())
            put("net", readNet()); put("wifi", readWifi())
            put("ts", System.currentTimeMillis().toDouble())
        }
        lastSentAt = SystemClock.elapsedRealtime()
        // fix8：每次成功上报后把闹钟锚点前移到新的 lastSentAt + 5min
        // （运动中也挂着——熄屏后没有回调时靠它续点）
        maybeArmHeartbeat()
        maybeFlush()
    }

    private fun enqueue(point: JSONObject) {
        while (queue.size >= QUEUE_MAX) { queue.removeFirst(); log("queue overflow -> drop oldest") }
        queue.addLast(point)
        log("enqueued (n=${queue.size})")
    }

    private fun maybeFlush() {
        if (lastSent == null) return
        val due = queue.size >= BATCH_MAX ||
            (queue.isNotEmpty() &&
                SystemClock.elapsedRealtime() - lastFlushAt >= BATCH_FLUSH_MS)
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
                        val head = queue.peekFirst() ?: break
                        if (head.optString("id") != id) break
                        queue.removeFirst()
                    }
                    reportedCount += accepted
                    lastFlushAt = SystemClock.elapsedRealtime()
                    log("flush ok n=${ids.size} accepted=$accepted " +
                        "(reported=$reportedCount, queue=${queue.size})")
                } else {
                    log("flush fail (queue=${queue.size}) err=$lastError")
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
