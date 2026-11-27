package cn.iepose.lovespace.love_space

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import java.util.concurrent.atomic.AtomicBoolean
import com.amap.api.maps.AMap
import com.amap.api.maps.CameraUpdateFactory
import com.amap.api.maps.ExceptionLogger
import com.amap.api.maps.MapsInitializer
import com.amap.api.maps.TextureMapView
import com.amap.api.maps.model.BitmapDescriptorFactory
import com.amap.api.maps.model.LatLng
import com.amap.api.maps.model.LatLngBounds
import com.amap.api.maps.model.Marker
import com.amap.api.maps.model.MarkerOptions
import com.amap.api.maps.model.PolylineOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * 高德地图加载/鉴权/瓦片下载诊断中心：
 * 通过 `MapsInitializer.setExceptionLogger`、`AMap.OnMapLoadedListener` 与初始化结果
 * 记录错误码并回调当前活跃轨迹视图，绝不允许底图静默全黑；
 * 同时通过 `PeerLocNative.diagnostics` 输出到「采集自检」面板。
 */
object AmapDiagnostics {
    private const val TAG = "AmapDiagnostics"
    private val loggerRegistered = AtomicBoolean(false)

    @Volatile
    var status: String = "idle"
        private set

    @Volatile
    var errorCode: String = ""
        private set

    @Volatile
    var errorMessage: String = ""
        private set

    @Volatile
    var errorCallback: String = ""
        private set

    @Volatile
    var errorAtMs: Long = 0L
        private set

    @Volatile
    private var activeErrorSink: ((code: String, callback: String, message: String) -> Unit)? = null

    fun ensureExceptionLogger() {
        if (!loggerRegistered.compareAndSet(false, true)) return
        try {
            MapsInitializer.setExceptionLogger(object : ExceptionLogger {
                override fun onDownloaderException(errCode: Int, responseCode: Int) {
                    val code = "downloader:$errCode/$responseCode"
                    val callback = "ExceptionLogger.onDownloaderException"
                    val msg = "AMap downloader failed (errorCode=$errCode, responseCode=$responseCode)"
                    android.util.Log.w(TAG, "$callback -> $msg")
                    recordError(code, callback, msg)
                }

                override fun onException(t: Throwable?) {
                    val type = t?.javaClass?.simpleName ?: "Throwable"
                    val code = "sdk:$type"
                    val callback = "ExceptionLogger.onException"
                    val msg = t?.message ?: "AMap SDK exception ($type)"
                    android.util.Log.w(TAG, "$callback -> $msg", t)
                    recordError(code, callback, msg)
                }
            })
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "setExceptionLogger failed", t)
        }
    }

    fun attachSink(sink: (code: String, callback: String, message: String) -> Unit) {
        activeErrorSink = sink
    }

    fun detachSink(sink: (code: String, callback: String, message: String) -> Unit) {
        if (activeErrorSink === sink) {
            activeErrorSink = null
        }
    }

    fun recordLoaded() {
        status = "loaded"
        errorCode = ""
        errorMessage = ""
        errorCallback = ""
    }

    fun recordError(code: String, callback: String, message: String) {
        status = "error"
        errorCode = code
        errorCallback = callback
        errorMessage = message
        errorAtMs = System.currentTimeMillis()
        activeErrorSink?.invoke(code, callback, message)
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "status" to status,
        "errorCode" to errorCode,
        "errorMessage" to errorMessage,
        "callback" to errorCallback,
        "errorAt" to errorAtMs,
    )
}

/**
 * 阻止外层竖向滚动列表（Flutter / Android 父容器）在触摸事件按下与滑动过程中抢走地图手势。
 */
private class MapTouchFrameLayout(context: Context) : FrameLayout(context) {
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN,
            MotionEvent.ACTION_MOVE,
            MotionEvent.ACTION_POINTER_DOWN -> parent?.requestDisallowInterceptTouchEvent(true)
            MotionEvent.ACTION_UP,
            MotionEvent.ACTION_CANCEL -> parent?.requestDisallowInterceptTouchEvent(false)
        }
        return super.dispatchTouchEvent(ev)
    }
}

/**
 * 主线程预加载高德 3D SDK 与底层 JNI 动态库：
 * - 合规要求：updatePrivacyShow / updatePrivacyAgree 必须最先调用；
 * - 治本逻辑：在 MainActivity.onCreate（主线程、带完整应用 ClassLoader）调用
 *   MapsInitializer.initialize + System.loadLibrary("AMapSDK_MAP_v9_8_3")，
 *   确保 JNI_OnLoad 的 FindClass/GetStaticMethodID 在应用类加载器上下文执行，
 *   杜绝首次在 GL 渲染线程加载 .so 时找不到 SDK Java 类而触发 SIGABRT。
 */
object AmapPreload {
    private const val TAG = "AmapPreload"

    @Volatile
    private var initialized = false

    fun initOnMainThread(context: Context) {
        if (initialized) return
        initialized = true
        try {
            val appCtx = context.applicationContext
            MapsInitializer.updatePrivacyShow(appCtx, true, true)
            MapsInitializer.updatePrivacyAgree(appCtx, true)
            AmapDiagnostics.ensureExceptionLogger()
            MapsInitializer.initialize(appCtx)
            System.loadLibrary("AMapSDK_MAP_v9_8_3")
            android.util.Log.i(
                TAG,
                "AMapSDK_MAP_v9_8_3 loaded on thread=${Thread.currentThread().name}"
            )
        } catch (t: Throwable) {
            android.util.Log.w(
                TAG,
                "preload failed on thread=${Thread.currentThread().name}",
                t
            )
        }
    }
}

/**
 * 高德地图配置通道：向 Flutter 汇报是否已注入有效 AMAP_API_KEY。
 * Key 为空时 Flutter 自动走自绘轨迹画布回退，不白屏。
 */
object AmapConfigChannel {
    const val CHANNEL_NAME = "cn.iepose.lovespace/amap_config"
    const val VIEW_TYPE = "cn.iepose.lovespace/amap_track_view"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasApiKey" -> {
                    val key = readApiKey(context)
                    result.success(!key.isNullOrBlank())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readApiKey(context: Context): String? {
        return try {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA
            )
            info.metaData?.getString("com.amap.api.v2.apikey")?.trim()
        } catch (_: Throwable) {
            null
        }
    }
}

class AmapTrackViewFactory(
    private val messenger: BinaryMessenger
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any?>
        return AmapTrackPlatformView(context, messenger, viewId, params)
    }
}

/**
 * 轨迹页签高德 3D 地图 PlatformView（使用 TextureMapView 避免 SurfaceView 裁切/遮挡问题）。
 *
 * 能力清单：
 * - 初始化前强制执行高德隐私合规声明（updatePrivacyShow + updatePrivacyAgree）；
 * - 支持双指缩放、拖拽；手动拖拽触发 onUserDrag 进入自由浏览模式；
 * - 按当日轨迹自动缩放适配边界（recenter 一键回到轨迹）；
 * - 精确模式画折线 + 停留点可点气泡（停留时长与到达–离开时间）；仅街区模式只画停留点；
 * - 支持时间轴回放标记沿轨迹移动；
 * - 任何初始化异常通过 onMapError 通知 Flutter 自动回退自绘画布。
 */
class AmapTrackPlatformView(
    context: Context,
    messenger: BinaryMessenger,
    viewId: Int,
    initialParams: Map<String, Any?>?
) : PlatformView, MethodChannel.MethodCallHandler {

    private val container = MapTouchFrameLayout(context)
    private val channel = MethodChannel(messenger, "${AmapConfigChannel.VIEW_TYPE}_$viewId")
    private val disposed = AtomicBoolean(false)
    private val errorReported = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mapView: TextureMapView? = null
    private var aMap: AMap? = null
    private var replayMarker: Marker? = null
    private var lastBounds: LatLngBounds? = null
    private var lastSinglePoint: LatLng? = null
    private var mapLoaded = false
    private var mapLoadedListener: AMap.OnMapLoadedListener? = null
    private val errorSink: (String, String, String) -> Unit = { code, callback, message ->
        mainHandler.post { emitMapError(code, callback, message) }
    }
    private val loadTimeoutRunnable = Runnable {
        if (!disposed.get() && !mapLoaded) {
            AmapDiagnostics.recordError(
                "load_timeout:8000ms",
                "AMap.OnMapLoadedListener(timeout)",
                "AMap tiles/map did not load within 8s"
            )
        }
    }

    init {
        channel.setMethodCallHandler(this)
        AmapDiagnostics.ensureExceptionLogger()
        AmapDiagnostics.attachSink(errorSink)
        try {
            // 高德 SDK 合规要求：创建地图前必须先声明隐私合规并同意
            MapsInitializer.updatePrivacyShow(context, true, true)
            MapsInitializer.updatePrivacyAgree(context, true)

            val mv = TextureMapView(context)
            mv.onCreate(null)
            mv.onResume()
            container.addView(
                mv,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT
                )
            )
            mapView = mv
            val map = mv.map
            if (map == null) {
                AmapDiagnostics.recordError(
                    "init_null_map",
                    "AmapTrackPlatformView.init",
                    "TextureMapView.getMap() returned null"
                )
            } else {
                aMap = map
                map.uiSettings.apply {
                    isScrollGesturesEnabled = true
                    isZoomGesturesEnabled = true
                    isZoomControlsEnabled = false
                    isCompassEnabled = false
                    isScaleControlsEnabled = true
                }
                val loaded = AMap.OnMapLoadedListener {
                    if (disposed.get()) return@OnMapLoadedListener
                    mapLoaded = true
                    mainHandler.removeCallbacks(loadTimeoutRunnable)
                    AmapDiagnostics.recordLoaded()
                }
                mapLoadedListener = loaded
                map.addOnMapLoadedListener(loaded)
                mainHandler.postDelayed(loadTimeoutRunnable, 8_000L)

                map.setOnMapTouchListener { ev ->
                    container.parent?.requestDisallowInterceptTouchEvent(
                        ev.actionMasked != MotionEvent.ACTION_UP &&
                            ev.actionMasked != MotionEvent.ACTION_CANCEL
                    )
                    if (!disposed.get() && ev.action == MotionEvent.ACTION_MOVE) {
                        channel.invokeMethod("onUserDrag", null)
                    }
                }
                if (initialParams != null) {
                    applyTrackData(map, initialParams)
                }
                if (!disposed.get()) {
                    channel.invokeMethod("onMapReady", null)
                }
            }
        } catch (t: Throwable) {
            AmapDiagnostics.recordError(
                "init_exception",
                "AmapTrackPlatformView.init",
                t.message ?: "AMap init failed"
            )
        }
    }

    private fun emitMapError(code: String, callback: String, message: String) {
        if (disposed.get() || !errorReported.compareAndSet(false, true)) return
        mainHandler.removeCallbacks(loadTimeoutRunnable)
        channel.invokeMethod(
            "onMapError",
            mapOf(
                "code" to code,
                "callback" to callback,
                "message" to message,
            )
        )
    }

    override fun getView(): View = container

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed.get()) {
            result.success(false)
            return
        }
        val map = aMap
        if (map == null) {
            result.success(false)
            return
        }
        when (call.method) {
            "setTrackData" -> {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any?>
                if (args != null) {
                    applyTrackData(map, args)
                }
                result.success(true)
            }
            "setReplayPosition" -> {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any?>
                updateReplayMarker(map, args)
                result.success(true)
            }
            "recenter" -> {
                recenterCamera(map)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun applyTrackData(map: AMap, data: Map<String, Any?>) {
        map.clear()
        replayMarker = null
        lastBounds = null
        lastSinglePoint = null

        val isStreet = data["isStreet"] == true
        // 地图可读性优先于跟随主题：高德 3D 夜间样式底图极暗，深浅双模式统一采用标准日图。
        map.mapType = AMap.MAP_TYPE_NORMAL

        val pathColor = (data["pathColor"] as? Number)?.toInt() ?: Color.parseColor("#E05A4F")
        val boundsBuilder = LatLngBounds.Builder()
        var coordCount = 0
        var firstCoord: LatLng? = null

        @Suppress("UNCHECKED_CAST")
        val rawPoints = (data["points"] as? List<Map<String, Any?>>) ?: emptyList()
        val polyCoords = mutableListOf<LatLng>()
        if (!isStreet) {
            for (pt in rawPoints) {
                val lat = (pt["lat"] as? Number)?.toDouble() ?: continue
                val lng = (pt["lng"] as? Number)?.toDouble() ?: continue
                val ll = LatLng(lat, lng)
                polyCoords.add(ll)
                boundsBuilder.include(ll)
                if (firstCoord == null) firstCoord = ll
                coordCount++
            }
            if (polyCoords.size >= 2) {
                map.addPolyline(
                    PolylineOptions()
                        .addAll(polyCoords)
                        .width(12f)
                        .color(pathColor)
                        .useGradient(false)
                )
            }
        }

        @Suppress("UNCHECKED_CAST")
        val rawStays = (data["stays"] as? List<Map<String, Any?>>) ?: emptyList()
        for (st in rawStays) {
            val lat = (st["lat"] as? Number)?.toDouble() ?: continue
            val lng = (st["lng"] as? Number)?.toDouble() ?: continue
            val title = (st["title"] as? String) ?: "停留点"
            val snippet = (st["snippet"] as? String) ?: ""
            val ll = LatLng(lat, lng)
            map.addMarker(
                MarkerOptions()
                    .position(ll)
                    .title(title)
                    .snippet(snippet)
                    .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE))
            )
            boundsBuilder.include(ll)
            if (firstCoord == null) firstCoord = ll
            coordCount++
        }

        if (coordCount >= 2) {
            lastBounds = try {
                boundsBuilder.build()
            } catch (_: Throwable) {
                null
            }
        }
        lastSinglePoint = firstCoord
        recenterCamera(map)
    }

    private fun updateReplayMarker(map: AMap, data: Map<String, Any?>?) {
        val lat = (data?.get("lat") as? Number)?.toDouble()
        val lng = (data?.get("lng") as? Number)?.toDouble()
        if (lat == null || lng == null) {
            replayMarker?.remove()
            replayMarker = null
            return
        }
        val pos = LatLng(lat, lng)
        val existing = replayMarker
        if (existing != null) {
            existing.position = pos
        } else {
            replayMarker = map.addMarker(
                MarkerOptions()
                    .position(pos)
                    .title("回放位置")
                    .icon(BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_RED))
            )
        }
    }

    private fun recenterCamera(map: AMap) {
        val bounds = lastBounds
        if (bounds != null) {
            map.animateCamera(CameraUpdateFactory.newLatLngBounds(bounds, 88))
        } else {
            val single = lastSinglePoint
            if (single != null) {
                map.animateCamera(CameraUpdateFactory.newLatLngZoom(single, 15f))
            }
        }
    }

    override fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        AmapDiagnostics.detachSink(errorSink)
        mainHandler.removeCallbacks(loadTimeoutRunnable)
        channel.setMethodCallHandler(null)
        val teardown = Runnable {
            val mv = mapView
            val map = aMap
            val loaded = mapLoadedListener
            mapView = null
            aMap = null
            mapLoadedListener = null
            replayMarker = null
            lastBounds = null
            lastSinglePoint = null

            try {
                if (loaded != null) {
                    map?.removeOnMapLoadedListener(loaded)
                }
                map?.setOnMapTouchListener(null)
                map?.stopAnimation()
                map?.clear()
            } catch (_: Throwable) {
                // ignore map cleanup errors before view teardown
            }

            if (mv != null) {
                // 按 TextureMapView 官方生命周期顺序：先暂停 GL 渲染，再从父容器摘除
                // 完成 Surface 分离，最后仅执行一次 onDestroy() 释放引擎。
                try {
                    mv.onPause()
                } catch (_: Throwable) {}
                try {
                    container.removeView(mv)
                } catch (_: Throwable) {}
                try {
                    mv.onDestroy()
                } catch (_: Throwable) {}
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            teardown.run()
        } else {
            mainHandler.post(teardown)
        }
    }
}
