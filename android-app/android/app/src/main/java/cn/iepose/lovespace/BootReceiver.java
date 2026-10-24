package cn.iepose.lovespace;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.Intent;
import android.util.Log;

/**
 * 开机后仅恢复已登录账号的消息提醒服务，不擅自打开 App 界面。
 */
public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "LoveSpace/Boot";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;
        if (!action.equals(Intent.ACTION_BOOT_COMPLETED)
                && !action.equals("android.intent.action.QUICKBOOT_POWERON")) {
            return;
        }
        Log.i(TAG, "收到开机广播，检查消息提醒配置");
        try {
            SharedPreferences prefs = context.getSharedPreferences("lovespace", Context.MODE_PRIVATE);
            if (prefs.getString("ntfy_topic", "").isEmpty()) return;
            NtfyStreamService.start(context);
        } catch (Exception e) {
            Log.e(TAG, "启动失败", e);
        }
    }
}
