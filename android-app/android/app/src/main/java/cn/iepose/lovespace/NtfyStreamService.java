package cn.iepose.lovespace;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import androidx.core.app.NotificationCompat;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashSet;
import java.util.Set;

/**
 * Native ntfy streaming client. The reverse proxy previously buffered
 * long-lived streams (bytes did not reach the phone until the socket closed),
 * so 1.1.9 used short polls. The proxy now sets proxy_buffering off, so this
 * reverts to a streaming connection with a message-id cursor: messages arrive
 * in real time (<1s) once the connection is up. Xiaomi/Android may still
 * suspend background networking, so the UI explains the vendor settings
 * required and never promises guaranteed delivery.
 */
public class NtfyStreamService extends Service {
    private static final String TAG = "LoveSpace/NtfyStream";
    private static final String PREFS = "lovespace";
    private static final String KEY_TOPIC = "ntfy_topic";
    private static final String KEY_LAST_TIME = "ntfy_last_time";
    private static final String KEY_LAST_IDS = "ntfy_last_ids";
    private static final String KEY_LAST_ID = "ntfy_last_id";
    private static final String KEY_LAST_ATTEMPT = "ntfy_last_attempt";
    private static final String KEY_LAST_SUCCESS = "ntfy_last_success";
    private static final String KEY_LAST_ERROR = "ntfy_last_error";
    private static final String KEY_CONNECTED = "ntfy_connected";
    private static final String DEFAULT_NTFY_SERVER = "https://mp.yangyuhui86.top/ntfy";
    private static final String CHANNEL_MSG = "love-msg-v2";
    private static final String CHANNEL_GUARD = "love-guard-v1";
    private static final int GUARD_NOTIF_ID = 20260101;
    private static final int MESSAGE_NOTIF_ID = 20261002;
    private static final long READ_TIMEOUT_MS = 60_000L;
    // 流式模式：连接持续保持，仅在断开后等待此间隔再重连（ntfy 45s keepalive 保活，
    // nginx proxy_buffering off 后流式实时到达，不再需要短轮询）
    private static final long RECONNECT_OK_MS = 2_000L;

    public static volatile boolean appForeground = false;
    public static volatile boolean serviceActive = false;
    private static volatile NtfyStreamService instance;

    private volatile boolean running = false;
    private volatile HttpURLConnection activeConnection;
    private Thread streamThread;

    public static void start(Context ctx) {
        try {
            SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            if (prefs.getString(KEY_TOPIC, "").isEmpty()) return;
            Intent it = new Intent(ctx, NtfyStreamService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(it);
            else ctx.startService(it);
        } catch (Exception e) {
            Log.e(TAG, "启动提醒服务失败", e);
        }
    }

    public static void stop(Context ctx) {
        NtfyStreamService current = instance;
        if (current != null) current.disconnectActive();
        try {
            ctx.stopService(new Intent(ctx, NtfyStreamService.class));
        } catch (Exception e) {
            Log.w(TAG, "停止提醒服务失败", e);
        }
    }

    public static void reconnect(Context ctx) {
        NtfyStreamService current = instance;
        if (current != null) current.disconnectActive();
        start(ctx);
    }

    private void disconnectActive() {
        HttpURLConnection connection = activeConnection;
        if (connection != null) connection.disconnect();
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        setConnected(getSharedPreferences(PREFS, MODE_PRIVATE), false);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_GUARD, "后台提醒连接", NotificationManager.IMPORTANCE_LOW);
            ch.setDescription("显示恋爱空间后台提醒连接状态");
            ch.setShowBadge(false);
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(ch);
        }
        Intent launch = new Intent(this, MainActivity.class);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(this, 1, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        Notification guard = new NotificationCompat.Builder(this, CHANNEL_GUARD)
                .setSmallIcon(getApplicationInfo().icon)
                .setContentTitle("恋爱空间提醒已开启")
                .setContentText("后台保持消息连接；可在设置中查看状态")
                .setOngoing(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build();
        startForeground(GUARD_NOTIF_ID, guard);
        serviceActive = true;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (!running) {
            running = true;
            streamThread = new Thread(this::streamLoop, "ntfy-stream");
            streamThread.setDaemon(true);
            streamThread.start();
            Log.i(TAG, "ntfy 长连接服务已启动（前台模式）");
        } else {
            disconnectActive();
        }
        return START_STICKY;
    }

    private void streamLoop() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        long backoffMs = 1_000L;
        while (running) {
            boolean ok = false;
            try {
                ok = pollOnce(prefs);
            } catch (Exception e) {
                if (running) {
                    setConnected(prefs, false);
                    prefs.edit().putString(KEY_LAST_ERROR, e.getClass().getSimpleName()).apply();
                    Log.w(TAG, "ntfy 轮询中断: " + e.getClass().getSimpleName());
                }
                backoffMs = Math.min(30_000L, backoffMs * 2L);
            } finally {
                HttpURLConnection connection = activeConnection;
                activeConnection = null;
                if (connection != null) connection.disconnect();
            }
            sleep(ok ? RECONNECT_OK_MS : backoffMs);
        }
    }

    private boolean pollOnce(SharedPreferences prefs) throws Exception {
        String topic = prefs.getString(KEY_TOPIC, "");
        if (topic.isEmpty()) {
            sleep(5_000L);
            return false;
        }
        String server = prefs.getString("ntfy_server", DEFAULT_NTFY_SERVER);
        Uri serverUri = Uri.parse(server);
        if (!"https".equalsIgnoreCase(serverUri.getScheme()) || serverUri.getHost() == null
                || serverUri.getUserInfo() != null || !topic.matches("[A-Za-z0-9_-]{20,80}")) {
            throw new IllegalArgumentException("Invalid ntfy endpoint");
        }

        // 首次运行：以当前时间为水位跳过历史消息（不回放弹窗），游标随后用消息 ID 推进
        if (prefs.getLong(KEY_LAST_TIME, 0L) <= 0L) {
            prefs.edit().putLong(KEY_LAST_TIME, System.currentTimeMillis() / 1000L)
                    .remove(KEY_LAST_IDS).apply();
        }
        // 流式长连接：since 用最新消息 ID 做增量游标（首次 since=all 全量回放建游标，
        // 历史消息只推进不弹窗）。nginx proxy_buffering off 后流式实时到达，无需 poll=1。
        String lastId = prefs.getString(KEY_LAST_ID, "");
        String since = lastId.isEmpty() ? "all" : lastId;
        prefs.edit().putLong(KEY_LAST_ATTEMPT, System.currentTimeMillis()).apply();
        URL url = new URL(server.replaceAll("/+$", "") + "/" + topic + "/json?since=" + since);
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        activeConnection = connection;
        connection.setRequestMethod("GET");
        connection.setConnectTimeout(15_000);
        connection.setReadTimeout((int) READ_TIMEOUT_MS);
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept", "application/x-ndjson");
        connection.setRequestProperty("Cache-Control", "no-cache");
        connection.setRequestProperty("User-Agent", "LoveSpace-Android/1.2.0");

        int code = connection.getResponseCode();
        if (code != HttpURLConnection.HTTP_OK) {
            prefs.edit().putString(KEY_LAST_ERROR, "HTTP " + code).apply();
            Log.w(TAG, "ntfy 返回 HTTP " + code);
            return false;
        }
        setConnected(prefs, true);
        prefs.edit().putLong(KEY_LAST_SUCCESS, System.currentTimeMillis()).remove(KEY_LAST_ERROR).apply();

        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while (running && (line = reader.readLine()) != null) {
                if (!running) break;
                if (!line.trim().isEmpty()) {
                    prefs.edit().putLong(KEY_LAST_SUCCESS, System.currentTimeMillis()).apply();
                    handleEvent(prefs, topic, server, line);
                }
                String activeTopic = prefs.getString(KEY_TOPIC, "");
                String activeServer = prefs.getString("ntfy_server", DEFAULT_NTFY_SERVER);
                if (!topic.equals(activeTopic) || !server.equals(activeServer)) break;
            }
        }
        return true;
    }

    private void handleEvent(SharedPreferences prefs, String topic, String server, String line) {
        try {
            JSONObject event = new JSONObject(line);
            if (!"message".equals(event.optString("event"))) return;
            if (!topic.equals(prefs.getString(KEY_TOPIC, ""))
                    || !server.equals(prefs.getString("ntfy_server", DEFAULT_NTFY_SERVER))) return;

            long timestamp = event.optLong("time", 0L);
            String id = event.optString("id", "");
            if (timestamp <= 0L || id.isEmpty()) return;

            // 增量游标始终推进到最新消息 ID（重放的历史消息也推进，避免每次全量回放）
            if (!id.equals(prefs.getString(KEY_LAST_ID, ""))) {
                prefs.edit().putString(KEY_LAST_ID, id).apply();
            }

            // 时间水位防御：首次建游标（since=all）回放的旧消息只推进游标、不弹窗
            long lastTime = prefs.getLong(KEY_LAST_TIME, 0L);
            Set<String> idsAtLastTime = new HashSet<>(prefs.getStringSet(KEY_LAST_IDS, new HashSet<>()));
            if (timestamp < lastTime || (timestamp == lastTime && idsAtLastTime.contains(id))) return;

            if (timestamp > lastTime) idsAtLastTime.clear();
            idsAtLastTime.add(id);
            prefs.edit().putLong(KEY_LAST_TIME, Math.max(timestamp, lastTime))
                    .putStringSet(KEY_LAST_IDS, idsAtLastTime).apply();

            if (appForeground) {
                Log.d(TAG, "App 在前台，由页面负责系统提醒");
                return;
            }
            postMessageNotification();
        } catch (Exception e) {
            Log.w(TAG, "忽略格式错误的 ntfy 消息", e);
        }
    }

    private void setConnected(SharedPreferences prefs, boolean connected) {
        prefs.edit().putBoolean(KEY_CONNECTED, connected).apply();
    }

    private void postMessageNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_MSG, "新消息", NotificationManager.IMPORTANCE_HIGH);
            ch.setDescription("聊天与系统通知（锁屏仅显示通用提醒）");
            ch.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
            ch.enableVibration(true);
            nm.createNotificationChannel(ch);
        }
        Intent launch = new Intent(this, MainActivity.class);
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent pi = PendingIntent.getActivity(this, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        NotificationCompat.Builder b = new NotificationCompat.Builder(this, CHANNEL_MSG)
                .setSmallIcon(getApplicationInfo().icon)
                .setContentTitle("恋爱空间")
                .setContentText("你有新的消息或提醒")
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
                .setVibrate(new long[]{0, 250, 250, 250});
        nm.notify(MESSAGE_NOTIF_ID, b.build());
    }

    public static void postTestNotification(Context context) {
        NotificationManager nm = (NotificationManager) context.getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_MSG, "新消息", NotificationManager.IMPORTANCE_HIGH);
            ch.setDescription("聊天与系统通知（锁屏仅显示通用提醒）");
            ch.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
            ch.enableVibration(true);
            nm.createNotificationChannel(ch);
        }
        Notification test = new NotificationCompat.Builder(context, CHANNEL_MSG)
                .setSmallIcon(context.getApplicationInfo().icon)
                .setContentTitle("恋爱空间通知测试")
                .setContentText("如果看到了这条提醒，系统通知权限正常。")
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .build();
        nm.notify(20261006, test);
    }

    private void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        disconnectActive();
        serviceActive = false;
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        setConnected(prefs, false);
        if (streamThread != null) streamThread.interrupt();
        if (instance == this) instance = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
