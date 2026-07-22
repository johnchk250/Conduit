package com.conduit.conduit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restarts the sync foreground service after device boot (Roadmap Phase 1).
 *
 * A phone that rebooted overnight would otherwise stay disconnected until the
 * user re-opens Conduit. This receiver starts the service (and therefore the
 * Dart isolate, which boots the engine and reconnects) as soon as the device is
 * up. The actual sync work lives in the Flutter engine; this only ensures the
 * process is alive.
 *
 * The connectedDevice foreground-service type matches continuous LAN peer
 * connectivity and remains eligible for boot restoration.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
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
