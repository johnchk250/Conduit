package com.conduit.conduit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restarts the sync foreground service after device boot (Roadmap Phase 1).
 *
 * A phone that rebooted overnight would otherwise stay disconnected until the
 * user re-opens Conduit. This receiver starts the service (and therefore the
 * Dart isolate, which boots the engine and reconnects) as soon as the device is
 * up. The actual sync work lives in the Flutter engine; this only ensures the
 * process is alive.
 *
 * NOTE: on Android 14+ a BOOT_COMPLETED-launched FGS of type dataSync is
 * subject to the same daily-budget rules as any background dataSync work; the
 * in-app Survival screen documents this. The engine is idle-mostly, so the
 * budget rarely bites.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        try {
            SyncService.start(context)
        } catch (_: Throwable) {
            // Best-effort — a boot restart failure just means the user opens
            // the app once.
        }
    }
}
