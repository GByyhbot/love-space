package cn.iepose.lovespace.love_space

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 🔴 2.8.0 第 0 步 fix5 根因修复（真机 MissingPluginException 实证）：
 * manifest activity 此前直接指向 audio_service 插件的
 * com.ryanheise.audioservice.AudioServiceActivity——本类（含
 * PeerLocNative.register 的 configureFlutterEngine）从未被实例化，
 * 原生 channel 不存在 → 前四轮 Dart→原生调用全部 MissingPluginException。
 * 修法：本类改为继承 AudioServiceActivity（audio_service 官方支持的自定义
 * Activity 口径，媒体前台服务行为不变）并接管 manifest activity 声明。
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 2.8.0 第 0 步 · 路线 B：原生 LocationManager 采集桥
        //（MethodChannel peer_loc/native：toggle/status/exportFatal 一口价）
        PeerLocNative.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // 高德 3D 地图配置与轨迹大图 PlatformView（仅轨迹页签大图使用）
        AmapConfigChannel.register(flutterEngine.dartExecutor.binaryMessenger, this)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            AmapConfigChannel.VIEW_TYPE,
            AmapTrackViewFactory(flutterEngine.dartExecutor.binaryMessenger)
        )
    }
}
