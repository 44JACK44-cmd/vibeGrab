package com.ryanheise.audioservice;

import android.content.Context;
import android.content.Intent;

public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";
    // VibeGrab patch: custom media notification actions (repeat / favorite).
    public static final String ACTION_CUSTOM_ACTION = "com.ryanheise.audioservice.intent.action.ACTION_CUSTOM_ACTION";
    public static final String EXTRA_CUSTOM_ACTION_NAME = "customActionName";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent != null
                && ACTION_NOTIFICATION_DELETE.equals(intent.getAction())
                && AudioService.instance != null) {
            AudioService.instance.handleDeleteNotification();
            return;
        }
        if (intent != null
                && ACTION_CUSTOM_ACTION.equals(intent.getAction())
                && AudioService.instance != null) {
            String name = intent.getStringExtra(EXTRA_CUSTOM_ACTION_NAME);
            if (name != null) {
                AudioService.instance.handleCustomAction(name);
                return;
            }
        }
        super.onReceive(context, intent);
    }
}
