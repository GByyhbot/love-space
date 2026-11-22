package cn.iepose.lovespace.love_space

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 2.8.0 第 0 步 · 路线 B：原生 LocationManager 采集桥
        //（EventChannel peer_loc/events + MethodChannel peer_loc/native）
        PeerLocNative.register(flutterEngine.dartExecutor.binaryMessenger, this)
    }
}
