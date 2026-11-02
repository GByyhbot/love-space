package cn.iepose.lovespace;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * JS → 原生桥：设置页「链路检测」用。
 *
 * <p>多线路探测的真实实现（{@code probeAll}）和当前线路状态（{@code currentUrl}）都在
 * {@link MainActivity} 里，WebView 侧拿不到，所以在这里开一个只读+切换的窄口子：
 * 探测回传每条线路的实测延迟，切换则交回 MainActivity 走它自己的种子 cookie + 重载流程。
 *
 * <p>注意：{@code probe} 会阻塞至多约 16 秒，绝不能跑在主线程（Capacitor 默认在主线程
 * 派发 PluginMethod），否则页面直接假死。这里显式放到后台线程，结果再回主线程 resolve。
 */
@CapacitorPlugin(name = "LinkBridge")
public class LinkBridge extends Plugin {

    @PluginMethod
    public void probe(final PluginCall call) {
        final MainActivity activity = activity();
        if (activity == null) {
            call.reject("页面尚未就绪");
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                JSObject ret = new JSObject();
                try {
                    ret.put("routes", activity.probeRoutesForUi());
                    ret.put("current", activity.currentRoute());
                } catch (Throwable e) {
                    activity.runOnUiThread(new Runnable() {
                        @Override public void run() { call.reject("探测失败，请稍后再试"); }
                    });
                    return;
                }
                final JSObject ok = ret;
                activity.runOnUiThread(new Runnable() {
                    @Override public void run() { call.resolve(ok); }
                });
            }
        }, "link-probe").start();
    }

    /** 切到指定线路；地址必须属于 App 内置的候选列表，避免被网页侧带去任意站点。 */
    @PluginMethod
    public void use(PluginCall call) {
        String url = call.getString("url");
        MainActivity activity = activity();
        if (activity == null) {
            call.reject("页面尚未就绪");
            return;
        }
        if (url == null || url.isEmpty()) {
            call.reject("缺少线路地址");
            return;
        }
        if (!activity.isKnownRoute(url)) {
            call.reject("未知线路");
            return;
        }
        activity.switchToRoute(url);
        call.resolve();
    }

    private MainActivity activity() {
        if (getActivity() instanceof MainActivity) return (MainActivity) getActivity();
        return null;
    }
}
