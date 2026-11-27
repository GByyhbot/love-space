package cn.iepose.lovespace.love_space

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import com.amap.api.maps.AMap
import com.amap.api.maps.CameraUpdateFactory
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

    private val container = FrameLayout(context)
    private val channel = MethodChannel(messenger, "${AmapConfigChannel.VIEW_TYPE}_$viewId")
    private var mapView: TextureMapView? = null
    private var aMap: AMap? = null
    private var replayMarker: Marker? = null
    private var lastBounds: LatLngBounds? = null
    private var lastSinglePoint: LatLng? = null

    init {
        channel.setMethodCallHandler(this)
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
            aMap = mv.map?.also { map ->
                map.uiSettings.apply {
                    isScrollGesturesEnabled = true
                    isZoomGesturesEnabled = true
                    isZoomControlsEnabled = false
                    isCompassEnabled = false
                    isScaleControlsEnabled = true
                }
                map.setOnMapTouchListener { ev ->
                    if (ev.action == MotionEvent.ACTION_MOVE) {
                        channel.invokeMethod("onUserDrag", null)
                    }
                }
                if (initialParams != null) {
                    applyTrackData(map, initialParams)
                }
                channel.invokeMethod("onMapReady", null)
            }
        } catch (t: Throwable) {
            channel.invokeMethod("onMapError", t.message ?: "AMap init failed")
        }
    }

    override fun getView(): View = container

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
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
        val dark = data["dark"] == true
        map.mapType = if (dark) AMap.MAP_TYPE_NIGHT else AMap.MAP_TYPE_NORMAL

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
        channel.setMethodCallHandler(null)
        try {
            mapView?.onPause()
            mapView?.onDestroy()
        } catch (_: Throwable) {
            // ignore teardown errors
        }
        mapView = null
        aMap = null
    }
}
