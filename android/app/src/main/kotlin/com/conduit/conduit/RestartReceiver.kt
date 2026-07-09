package com.conduit.conduit

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Watchdog receiver (Roadmap Phase 1, audit Issue #8).
 *
 * Fired by the repeating inexact alarm armed in [SyncService.scheduleWatchdog].
 * If the foreground service was killed AFTER the one-shot onTaskRemoved restart
 * — an OOM kill, an OEM battery killer, or the Android 14+ 6-hour dataSync FGS
 * daily cap — this receiver relaunches it. [SyncService.start] re-posts the
 * foreground notification within the Android 12+ ~5s FGS-start window.
 *
 * If the service is already running, startForegroundService on a live FGS is a
 * no-op (it just re-delivers onStartCommand, which re-arms the alarm), so this
 * is safe to fire repeatedly. Manifest-registered; not exported — only the
 * system AlarmManager sends it.
 */
class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            SyncService.start(context)
        } catch (t: Throwable) {
            // Best-effort: a watchdog failure just means the next app open or
            // reboot re-launches the service. Don't crash the receiver.
            Log.w("Conduit.Restart", "watchdog relaunch failed: ${t.message}")
        }
    }
}
