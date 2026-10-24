package cn.iepose.lovespace;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import android.app.NotificationManager;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import androidx.core.app.NotificationManagerCompat;

import java.util.regex.Pattern;

/**
 * JS → 原生桥：登录后 WebView 把服务端分配的 ntfy topic 交给原生层，
 * 原生 ntfy 持续连接服务凭它接收消息并弹系统通知。
 */
@CapacitorPlugin(name = "PushBridge")
public class PushBridge extends Plugin {
    private static final Pattern TOPIC_PATTERN = Pattern.compile("[A-Za-z0-9_-]{20,80}");

    @PluginMethod
    public void setTopic(PluginCall call) {
        String topic = call.getString("topic");
        String server = call.getString("server", "https://mp.yangyuhui86.top/ntfy");
        if (topic != null && TOPIC_PATTERN.matcher(topic).matches()) {
            if (server == null || !server.startsWith("https://") || server.contains("@")) {
                call.reject("Push server must use HTTPS");
                return;
            }
            SharedPreferences prefs = getContext().getSharedPreferences("lovespace", Context.MODE_PRIVATE);
            Uri serverUri = Uri.parse(server);
            if (serverUri.getHost() == null || serverUri.getUserInfo() != null) {
                call.reject("Push server URL is invalid");
                return;
            }
            String previous = prefs.getString("ntfy_topic", "");
            String cleanServer = server.replaceAll("/+$", "");
            String previousServer = prefs.getString("ntfy_server", "");
            boolean changed = !topic.equals(previous) || !cleanServer.equals(previousServer);
            SharedPreferences.Editor editor = prefs.edit().putString("ntfy_topic", topic)
                    .putString("ntfy_server", cleanServer);
            if (changed) {
                editor.putBoolean("ntfy_connected", false)
                        .putLong("ntfy_last_time", System.currentTimeMillis() / 1000L)
                        .remove("ntfy_last_ids").remove("ntfy_last_id");
            } else if (!prefs.contains("ntfy_last_time")) {
                // Upgrade old installs without a cursor; begin at now to avoid replaying stale notices.
                editor.putLong("ntfy_last_time", System.currentTimeMillis() / 1000L);
            }
            editor.apply();
            if (changed || !NtfyStreamService.serviceActive) NtfyStreamService.reconnect(getContext());
            call.resolve();
            return;
        }
        call.reject("Push topic is invalid");
    }

    /** Clear account-bound push state as soon as the user logs out. */
    @PluginMethod
    public void clearTopic(PluginCall call) {
        Context context = getContext();
        SharedPreferences prefs = context.getSharedPreferences("lovespace", Context.MODE_PRIVATE);
        prefs.edit().remove("ntfy_topic").remove("ntfy_server").remove("ntfy_last_time")
                .remove("ntfy_last_ids").remove("ntfy_last_id").putBoolean("ntfy_connected", false)
                .remove("ntfy_last_error").apply();
        NtfyStreamService.stop(context);
        android.app.NotificationManager notifications =
                (android.app.NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
        if (notifications != null) notifications.cancelAll();
        call.resolve();
    }

    /** 返回原生 APK 版本号（build.gradle versionName），供应用内更新对比 */
    @PluginMethod
    public void version(PluginCall call) {
        JSObject ret = new JSObject();
        try {
            ret.put("version", getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0).versionName);
            ret.put("code", getContext().getPackageManager()
                    .getPackageInfo(getContext().getPackageName(), 0).versionCode);
        } catch (Exception e) {
            ret.put("version", "unknown");
        }
        call.resolve(ret);
    }

    /** Native diagnostics used by the notification settings page. */
    @PluginMethod
    public void status(PluginCall call) {
        Context context = getContext();
        SharedPreferences prefs = context.getSharedPreferences("lovespace", Context.MODE_PRIVATE);
        JSObject ret = new JSObject();
        try {
            ret.put("available", true);
            ret.put("configured", !prefs.getString("ntfy_topic", "").isEmpty());
            ret.put("service_running", NtfyStreamService.serviceActive);
            ret.put("stream_connected", prefs.getBoolean("ntfy_connected", false));
            ret.put("last_attempt", prefs.getLong("ntfy_last_attempt", 0));
            ret.put("last_success", prefs.getLong("ntfy_last_success", 0));
            ret.put("last_error", prefs.getString("ntfy_last_error", ""));
            boolean batteryUnrestricted = false;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PowerManager pm = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
                batteryUnrestricted = pm != null && pm.isIgnoringBatteryOptimizations(context.getPackageName());
            }
            ret.put("battery_unrestricted", batteryUnrestricted);
            ret.put("notifications_enabled", NotificationManagerCompat.from(context).areNotificationsEnabled());
            boolean channelEnabled = true;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                NotificationManager nm = (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
                if (nm != null) {
                    android.app.NotificationChannel channel = nm.getNotificationChannel("love-msg-v2");
                    channelEnabled = channel == null || channel.getImportance() != NotificationManager.IMPORTANCE_NONE;
                }
            }
            ret.put("message_channel_enabled", channelEnabled);
        } catch (Exception e) {
            ret.put("available", false);
            ret.put("error", e.getClass().getSimpleName());
        }
        call.resolve(ret);
    }

    /** Opens the per-app battery optimization exemption prompt from an explicit user action. */
    @PluginMethod
    public void openBatterySettings(PluginCall call) {
        Context context = getContext();
        try {
            Intent intent;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:" + context.getPackageName()));
            } else {
                intent = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            try {
                context.startActivity(intent);
            } catch (Exception first) {
                Intent fallback = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(fallback);
            }
            call.resolve();
        } catch (Exception e) {
            call.reject("无法打开电池设置", e);
        }
    }

    /** Opens Android's app notification settings. */
    @PluginMethod
    public void openNotificationSettings(PluginCall call) {
        try {
            Intent intent = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, getContext().getPackageName())
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(intent);
            call.resolve();
        } catch (Exception e) {
            call.reject("无法打开通知设置", e);
        }
    }

    /** Reconnects the ntfy stream with exponential backoff reset. */
    @PluginMethod
    public void restart(PluginCall call) {
        NtfyStreamService.reconnect(getContext());
        call.resolve();
    }

    /** Opens the signed-in website in the user's browser to enable browser system push. */
    @PluginMethod
    public void openWebPushBrowser(PluginCall call) {
        String value = call.getString("url", "");
        Uri uri = Uri.parse(value);
        if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null) {
            call.reject("网页推送地址必须是有效的 HTTPS 地址");
            return;
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, uri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(intent);
            call.resolve();
        } catch (Exception error) {
            call.reject("无法打开系统浏览器", error);
        }
    }

    /** Emits a generic local notification so the user can verify Android's notification path. */
    @PluginMethod
    public void testNotification(PluginCall call) {
        if (!NotificationManagerCompat.from(getContext()).areNotificationsEnabled()) {
            call.reject("系统通知权限未开启");
            return;
        }
        NtfyStreamService.postTestNotification(getContext());
        call.resolve();
    }
}
