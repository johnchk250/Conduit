package com.conduit.conduit

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the sync engine alive while the app is in the
 * background, plus a transfer-tied partial wake lock.
 *
 * The actual sync logic lives in the Flutter/Dart isolate (the engine); this
 * service exists purely to satisfy Android's background-execution rules and
 * surface a persistent "Conduit is running" notification.
 *
 * ## Wake lock (Roadmap Phase 0.4)
 *
 * `onCreate` no longer holds a blanket 10-minute wake lock. Instead it exposes
 * an acquire/release pair (driven by the `conduit/wakelock` method channel
 * from the engine's transfer start/stop callbacks). A transfer acquires a
 * short, renewable 60s lock; an idle folder holds none, so Doze is free to take
 * over between syncs. The lock is reference-counted OFF (we manage a single
 * timed acquisition per active burst rather than nesting them).
 *
 * ## Restart on task removal (Roadmap Phase 1)
 *
 * `onTaskRemoved` (swipe-from-recents) schedules a one-shot restart via
 * AlarmManager so the service comes back ~1s later. This is the standard
 * pattern for surviving the recents gesture on stock Android; OEM killers
 * (MIUI/EMUI/ColorOS) still require the user's battery/autostart whitelist,
 * documented in the in-app Survival screen.
 *
 * ## Notification visibility toggle (Polish)
 *
 * Two notification channels exist:
 *   - CH_ID_NORMAL (IMPORTANCE_DEFAULT): full notification with status-bar icon.
 *   - CH_ID_SILENT (IMPORTANCE_MIN): silent entry in the drawer only; the
 *     status-bar icon is hidden by the OS. This satisfies the FGS requirement
 *     while minimising visual clutter when the user opts out.
 *
 * The Dart side calls `setNotificationVisibility(bool)` via MainActivity's
 * CH_SYNC channel, which sends ACTION_SET_VISIBILITY to this service.
 */
class SyncService : Service() {

    companion object {
        private const val CH_ID_NORMAL = "conduit_fg_v2"
        private const val CH_ID_SILENT = "conduit_fg_silent"
        private const val NOTIF_ID = 1
        private const val ACTION_START = "com.conduit.conduit.START"
        private const val ACTION_STOP = "com.conduit.conduit.STOP"
        /** Sent by MainActivity to flip the notification channel (visible/silent). */
        const val ACTION_SET_VISIBILITY = "com.conduit.conduit.SET_VISIBILITY"
        /** Boolean extra on ACTION_SET_VISIBILITY: true = normal, false = silent. */
        const val EXTRA_VISIBLE = "visible"
        /** Sent by MainActivity when Dart's live-peer-session state changes
         * (Roadmap Phase 0.6 — battery). See [multicastLock] doc. */
        const val ACTION_SET_DISCOVERY_NEEDED = "com.conduit.conduit.SET_DISCOVERY_NEEDED"
        /** Boolean extra on ACTION_SET_DISCOVERY_NEEDED: true = no peer session
         * is live, (re)acquire the MulticastLock; false = at least one is,
         * release it. */
        const val EXTRA_NEEDED = "needed"

        // Delay before restarting the service after a task-removal.
        private const val RESTART_DELAY_MS = 1_000L

        // Watchdog (Phase 1, Issue #8): a repeating inexact alarm that re-launches
        // the service if it has been killed AFTER the one-shot onTaskRemoved
        // restart — i.e. OOM kill, OEM battery killer, or the Android 14+ 6-hour
        // dataSync FGS daily cap. The one-shot handles the common recents-swipe
        // case promptly; this repeating alarm is the long-haul fallback.
        // Inexact → battery-friendly (Android 12+ may batch it to ~15 min; that's
        // fine for a watchdog, the FGS is the primary survival mechanism).
        private const val WATCHDOG_INTERVAL_MS = 2 * 60 * 1000L // 2 min
        private const val WATCHDOG_RC = 42

        fun start(ctx: Context) {
            val intent = Intent(ctx, SyncService::class.java).apply { action = ACTION_START }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }
        fun stop(ctx: Context) {
            val intent = Intent(ctx, SyncService::class.java).apply { action = ACTION_STOP }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        /**
         * Ask the running service to change its notification visibility.
         * [visible] true = normal importance (status-bar icon shown),
         *           false = min importance (silent; no status-bar icon).
         */
        fun setVisibility(ctx: Context, visible: Boolean) {
            val intent = Intent(ctx, SyncService::class.java).apply {
                action = ACTION_SET_VISIBILITY
                putExtra(EXTRA_VISIBLE, visible)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        /**
         * Ask the running service to acquire or release its MulticastLock.
         * See [multicastLock] doc for the battery rationale. [needed] true =
         * no peer session is live, false = at least one is.
         */
        fun setDiscoveryNeeded(ctx: Context, needed: Boolean) {
            val intent = Intent(ctx, SyncService::class.java).apply {
                action = ACTION_SET_DISCOVERY_NEEDED
                putExtra(EXTRA_NEEDED, needed)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        /**
         * Arm the repeating watchdog alarm (idempotent). Fired in [onStartCommand]
         * so every entry path sets it up; re-arming with FLAG_UPDATE_CURRENT
         * replaces any existing alarm rather than stacking. Also (re)armed in
         * [onTaskRemoved] as a defensive guarantee.
         */
        fun scheduleWatchdog(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(ctx, RestartReceiver::class.java).apply {
                setPackage(ctx.packageName)
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else
                PendingIntent.FLAG_UPDATE_CURRENT
            val pi = PendingIntent.getBroadcast(ctx, WATCHDOG_RC, intent, flags)
            // ELAPSED_REALTIME_WAKEUP + SystemClock.elapsedRealtime() keeps the
            // trigger in the same time base (using wall-clock millis here would
            // fire at the wrong time — see audit Issue #3).
            am.setInexactRepeating(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + WATCHDOG_INTERVAL_MS,
                WATCHDOG_INTERVAL_MS,
                pi,
            )
        }

        /**
         * Cancel the repeating watchdog alarm. Called on an intentional stop so
         * the watchdog doesn't keep relaunching a service the user meant to kill.
         */
        fun cancelWatchdog(ctx: Context) {
            val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(ctx, RestartReceiver::class.java).apply {
                setPackage(ctx.packageName)
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else
                PendingIntent.FLAG_UPDATE_CURRENT
            val pi = PendingIntent.getBroadcast(ctx, WATCHDOG_RC, intent, flags)
            am.cancel(pi)
            pi.cancel()
        }
    }

    private var baseWakeLock: PowerManager.WakeLock? = null
    private var intentionalStop = false

    // Current notification channel: true = normal (status-bar visible),
    // false = silent (IMPORTANCE_MIN, no status-bar icon).
    private var notifVisible = true

    // MulticastLock so the Dart isolate actually receives UDP discovery
    // beacons (broadcast to 255.255.255.255). Without it Android's Wi-Fi
    // driver filters those packets out and LAN auto-discovery never fires —
    // both devices sit on the same network yet never auto-connect. The
    // CHANGE_WIFI_MULTICAST_STATE permission is declared in the manifest; this
    // lock is the runtime half that makes the permission do anything.
    //
    // Roadmap Phase 0.6 (battery): previously held for the service's entire
    // life, released only in onDestroy — meaning it was held 24/7 even for
    // the many hours a day a peer session is already live and no beacon can
    // do anything useful (an established session is a unicast TCP socket,
    // unaffected by this lock either way). Now acquired here as the correct
    // startup default (no session is live yet), then toggled by
    // ACTION_SET_DISCOVERY_NEEDED — sent by AppState._setDiscoveryLockEnabled
    // via MainActivity's conduit/wakelock channel every time the set of live
    // peer sessions changes empty <-> non-empty. onDestroy still releases it
    // unconditionally as a final safety net.
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannels()
        val notif = buildNotification("Conduit is running", notifVisible)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        // NOTE (Roadmap Phase 0.4): a long-held blanket wake lock was removed.
        // The transfer-tied wake lock is owned by MainActivity (acquire/release
        // over the conduit/wakelock channel), so this service only keeps the
        // process in the foreground — no blanket lock while idle.
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        baseWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Conduit::Base")
        baseWakeLock?.setReferenceCounted(false)

        acquireMulticastLock()
    }

    /**
     * Acquire the MulticastLock so the Dart isolate's UDP discovery listener
     * receives broadcast beacons. See [multicastLock]. Best-effort: a failure
     * here (no Wi-Fi, old platform quirk) must not stop the service — sync over
     * a manually-paired session still works, only auto-discovery is degraded.
     */
    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            // A process holds a single named MulticastLock; reference-counted
            // off so multiple acquire/release callers don't fight.
            val lock = wifi.createMulticastLock("Conduit::Discovery")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
        } catch (_: Throwable) {
            // Ignore — see method doc.
        }
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        multicastLock = null
        try {
            if (lock.isHeld) lock.release()
        } catch (_: Throwable) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                intentionalStop = true
                cancelWatchdog(this)
                @Suppress("DEPRECATION")
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SET_VISIBILITY -> {
                val visible = intent.getBooleanExtra(EXTRA_VISIBLE, true)
                notifVisible = visible
                // Re-post the notification on the appropriate channel.
                val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIF_ID, buildNotification("Conduit is running", notifVisible))
            }
            ACTION_SET_DISCOVERY_NEEDED -> {
                val needed = intent.getBooleanExtra(EXTRA_NEEDED, true)
                if (needed) acquireMulticastLock() else releaseMulticastLock()
            }
            else -> {
                // ACTION_START or START_STICKY recreation (null intent).
                // Arm the repeating watchdog on every entry — covers the first start,
                // START_STICKY recreations, and the one-shot restart. Idempotent via
                // FLAG_UPDATE_CURRENT.
                scheduleWatchdog(this)
            }
        }
        return START_STICKY
    }

    /**
     * The user swiped the app from recents. Schedule a restart so the service
     * (and therefore the Dart sync engine via the persistent notification)
     * survives the gesture on stock Android. OEM killers still need the user's
     * whitelist; this only covers the standard platform behaviour.
     *
     * Two layers: (1) the one-shot alarm below for an immediate ~1s restart,
     * and (2) [scheduleWatchdog] re-armed here as a defensive guarantee so the
     * long-haul repeating fallback is definitely running even if onStartCommand
     * never saw an explicit start action.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        scheduleWatchdog(this)
        val restart = Intent(applicationContext, this::class.java).apply {
            setPackage(packageName)
            // Carry over the original intent's extras, if any. (Intent.putAll
            // resolves to replaceExtras(source: Intent), but the parameter is
            // non-null while onTaskRemoved's rootIntent is nullable, so we copy
            // explicitly.)
            if (rootIntent != null) replaceExtras(rootIntent)
        }
        val flags = PendingIntent.FLAG_ONE_SHOT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_IMMUTABLE else 0
        val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(this, 1, restart, flags)
        } else {
            PendingIntent.getService(this, 1, restart, flags)
        }
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        am.set(
            AlarmManager.ELAPSED_REALTIME_WAKEUP,
            SystemClock.elapsedRealtime() + RESTART_DELAY_MS,
            pi,
        )
        // Do not call super: the platform default may stop the service for a
        // task-removal, which is exactly the behavior this override prevents.
    }

    override fun onDestroy() {
        // Cancel the watchdog only for an intentional Quit. If OxygenOS or the
        // system destroys the service, leaving the watchdog armed is what lets
        // Conduit come back instead of silently disappearing.
        if (intentionalStop) cancelWatchdog(this)
        if (baseWakeLock?.isHeld == true) {
            try { baseWakeLock?.release() } catch (_: Throwable) {}
        }
        releaseMulticastLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Create both notification channels (idempotent; no-op on API < 26). */
    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

            // Normal channel: visible status-bar icon.
            val normal = NotificationChannel(
                CH_ID_NORMAL, "Conduit background sync", NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Keeps folder sync running in the background"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            nm.createNotificationChannel(normal)

            // Silent channel: no status-bar icon, no sound, minimal drawer entry.
            // Used when the user turns off "Show in status bar" in Settings.
            val silent = NotificationChannel(
                CH_ID_SILENT, "Conduit (silent)", NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Hidden background sync notification"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
            nm.createNotificationChannel(silent)
        }
    }

    /**
     * Build the foreground notification on the appropriate channel.
     * [visible] true → CH_ID_NORMAL (status-bar icon shown),
     *           false → CH_ID_SILENT (no status-bar icon).
     */
    private fun buildNotification(text: String, visible: Boolean): Notification {
        val channelId = if (visible) CH_ID_NORMAL else CH_ID_SILENT

        // Tap-to-open: tapping the notification brings the app to the foreground.
        // getLaunchIntentForPackage returns the main LAUNCHER intent; FLAG_ACTIVITY_SINGLE_TOP
        // ensures we land in the already-running MainActivity via onNewIntent rather than
        // spawning a second instance (matches the activity's own launchMode="singleTop").
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val contentPiFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val contentPi = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, contentPiFlags)
        }

        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Conduit")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notif_conduit)
            .setOngoing(true)
            .setPriority(if (visible) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOnlyAlertOnce(true)
            .apply { if (contentPi != null) setContentIntent(contentPi) }
            .build()
    }
}
