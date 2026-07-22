package com.conduit.conduit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service that keeps the sync engine alive while the app is in the
 * background, plus a transfer-tied partial wake lock.
 *
 * The service owns the process-level Flutter engine as well as its foreground
 * notification and locks. A cold service restart therefore recreates Dart and
 * restores synchronization without requiring MainActivity.
 *
 * ## Wake locks (Roadmap Phase 0.4 + 0.6, ownership fixed post-audit)
 *
 * `onCreate` no longer holds a blanket 10-minute wake lock. Instead this
 * service owns two independent, renewable partial wake locks, each exposed
 * as an acquire/release pair over the `conduit/wakelock` method channel
 * (forwarded here from MainActivity):
 *
 *   - **Transfer lock** (`Conduit::Transfer`): held only while bytes are
 *     actively moving. Dart calls `acquire`/`release` on the 0→1/1→0
 *     transitions of the engine's transfer-burst counter, and renews every
 *     45s while a burst is in progress so multi-file bursts longer than the
 *     lock's timeout don't silently lose protection.
 *   - **Clipboard/recovery lock** (`Conduit::Connection`): held while the
 *     opt-in clipboard feature has a live peer, or during a bounded reconnect
 *     boost. It is absent from normal folder-only idle operation and renews
 *     every 10 minutes while needed.
 *
 * Both locks are reference-counted OFF (a single timed acquisition per
 * enable/renew, not nested), and both were moved here from MainActivity: an
 * Activity-scoped lock is released the moment the Activity is destroyed
 * (e.g. a swipe-from-recents, since MainActivity is `launchMode="singleTask"`
 * with no `excludeFromRecents`), which defeated the entire point of a
 * transfer surviving in the background. Owning them here ties their lifetime
 * to the foreground service instead, which is what's actually meant to
 * outlive the UI — mirroring how [multicastLock] already worked correctly.
 *
 * ## Notification visibility toggle (Polish)
 *
 * Two notification channels exist:
 *   - CH_ID_NORMAL (IMPORTANCE_DEFAULT): full notification with status-bar icon.
 *   - CH_ID_SILENT (IMPORTANCE_MIN): a quieter foreground-service entry.
 *     Android may still expose it in the notification drawer or Active apps,
 *     as required for user-visible background work.
 *
 * The Dart side calls `setNotificationVisibility(bool)` through the shared
 * method channel; the update is applied directly to the running service.
 */
class SyncService : Service() {

    companion object {
        private const val CH_ID_NORMAL = "conduit_fg_v2"
        private const val CH_ID_SILENT = "conduit_fg_silent"
        private const val NOTIF_ID = 1
        private const val ACTION_START = "com.conduit.conduit.START"
        @Volatile
        private var instance: SyncService? = null
        @Volatile
        private var desiredNotificationVisible = true
        @Volatile
        private var desiredDiscoveryNeeded = true
        @Volatile
        private var desiredTransferLock = false
        @Volatile
        private var desiredConnectionLock = false

        // Timed safety nets for renewable locks. Transfers renew every 45s;
        // the lower-churn clipboard/recovery lock renews every 10 minutes.
        // Timeouts protect against a crashed isolate losing its release call.
        private const val TRANSFER_LOCK_TIMEOUT_MS = 120_000L
        private const val CONNECTION_LOCK_TIMEOUT_MS = 15 * 60 * 1000L

        fun start(ctx: Context) {
            if (instance != null) return
            val intent = Intent(ctx, SyncService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, SyncService::class.java))
        }

        /** Apply a control update directly to the already-running service.
         * No control method attempts to create a foreground service from the
         * background; [start] is the sole creation path. Desired state is kept
         * in process memory so calls racing onCreate are applied there. */
        private fun applyToRunning(block: SyncService.() -> Unit) {
            val service = instance ?: return
            service.mainHandler.post {
                if (instance === service) service.block()
            }
        }

        fun setVisibility(ctx: Context, visible: Boolean) {
            desiredNotificationVisible = visible
            applyToRunning { applyNotificationVisibility(visible) }
        }

        fun setDiscoveryNeeded(ctx: Context, needed: Boolean) {
            desiredDiscoveryNeeded = needed
            applyToRunning {
                if (needed) acquireMulticastLock() else releaseMulticastLock()
            }
        }

        fun setTransferLockEnabled(ctx: Context, enabled: Boolean) {
            desiredTransferLock = enabled
            applyToRunning {
                if (enabled) acquireTransferWakeLock() else releaseTransferWakeLock()
            }
        }

        fun setConnectionLockEnabled(ctx: Context, enabled: Boolean) {
            desiredConnectionLock = enabled
            applyToRunning {
                if (enabled) acquireConnectionWakeLock() else releaseConnectionWakeLock()
            }
        }

    }

    private var baseWakeLock: PowerManager.WakeLock? = null
    /** Strong owner of the Dart isolate while the foreground service lives. */
    private var flutterEngine: FlutterEngine? = null

    /**
     * Network changes are system callbacks, so they still arrive when Dart
     * timers are deferred by Doze. Besides a bounded CPU wake window, forward
     * a monotonically increasing route generation to Dart. AppState uses it to
     * invalidate stale LAN sockets, rebind UDP discovery, clear reconnect
     * backoff, and announce on the new interface immediately.
     */
    private val mainHandler = Handler(Looper.getMainLooper())
    private val networkEpoch = SystemClock.elapsedRealtimeNanos().toString()
    private var currentNetwork: Network? = null
    private var networkGeneration = 0L
    private var lastLinkSignature: String? = null
    private var pendingNetworkSignal: Runnable? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val changed = currentNetwork != network
            currentNetwork = network
            if (changed) {
                networkGeneration += 1
                lastLinkSignature = null
            }
            acquireMulticastLock()
            wakeForReconnect()
            scheduleNetworkSignal("available", available = true)
            // A cold Flutter engine may still be registering its Dart handler.
            // Re-send the same generation once after startup; duplicate
            // generations are harmless and do not tear down sessions.
            mainHandler.postDelayed({
                if (currentNetwork == network) {
                    emitNetworkSignal("available_confirmed", true, networkGeneration)
                }
            }, 4_000L)
        }

        override fun onLost(network: Network) {
            if (currentNetwork != network) return
            currentNetwork = null
            lastLinkSignature = null
            networkGeneration += 1
            scheduleNetworkSignal("lost", available = false, delayMs = 100L)
        }

        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) {
            if (currentNetwork != network) return
            val signature = buildLinkSignature(linkProperties)
            val previous = lastLinkSignature
            lastLinkSignature = signature
            if (previous != null && previous != signature) {
                networkGeneration += 1
                acquireMulticastLock()
                wakeForReconnect()
                scheduleNetworkSignal("link_properties", available = true)
            }
        }
    }

    private fun buildLinkSignature(link: LinkProperties): String {
        val addresses = link.linkAddresses.map { it.toString() }.sorted().joinToString(",")
        val routes = link.routes.map {
            "${it.destination}/${it.gateway?.hostAddress ?: "-"}"
        }.sorted().joinToString(",")
        // DNS-only updates do not invalidate an established TCP route and must
        // not cause visible reconnect churn. Interface, address, and route
        // changes are the signals that matter for LAN socket reachability.
        return "${link.interfaceName}|$addresses|$routes"
    }

    private fun scheduleNetworkSignal(
        reason: String,
        available: Boolean,
        delayMs: Long = 750L,
    ) {
        pendingNetworkSignal?.let { mainHandler.removeCallbacks(it) }
        val generation = networkGeneration
        val signal = Runnable {
            pendingNetworkSignal = null
            emitNetworkSignal(reason, available, generation)
        }
        pendingNetworkSignal = signal
        mainHandler.postDelayed(signal, delayMs)
    }

    private fun emitNetworkSignal(reason: String, available: Boolean, generation: Long) {
        val engine = flutterEngine ?: return
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, "conduit/network_events")
                .invokeMethod(
                    "networkChanged",
                    mapOf(
                        "reason" to reason,
                        "available" to available,
                        "generation" to generation,
                        "epoch" to networkEpoch,
                    ),
                )
        } catch (_: Throwable) {
            // Dart may still be starting. onAvailable's delayed confirmation
            // and future network callbacks provide another opportunity.
        }
    }

    private fun wakeForReconnect() {
        try {
            if (baseWakeLock?.isHeld == true) baseWakeLock?.release()
            baseWakeLock?.acquire(45_000L)
        } catch (_: Throwable) {
            // Best-effort; the foreground service still protects the process.
        }
    }

    /**
     * Transfer-tied partial wake lock (Roadmap Phase 0.4).
     *
     * Post-audit fix: this used to live on `MainActivity` as an
     * Activity-scoped field. That was broken two ways: (1) `MainActivity`
     * is `launchMode="singleTask"` with no `excludeFromRecents`, so a plain
     * swipe-from-recents mid-transfer calls `onDestroy()`, which explicitly
     * released the lock — even though the Dart sync engine and this service
     * kept running underneath; (2) the lock had no renewal, just a flat
     * timed acquisition, so any transfer burst longer than the timeout
     * silently lost the lock even with the Activity alive. Living here
     * instead ties the lock's lifetime to the foreground service, which is
     * the thing that's actually supposed to outlive the UI — the same
     * reasoning already applied correctly to [multicastLock] below. Dart
     * renews this every 45s while a burst is active (see
     * app_state.dart's `_renewTransferWakeLock`); [TRANSFER_LOCK_TIMEOUT_MS]
     * is only a safety net against a lost renew/release call.
     */
    private var transferWakeLock: PowerManager.WakeLock? = null

    /**
     * Clipboard/recovery partial wake lock (Roadmap Phase 0.6). It is held only
     * while the user-enabled clipboard feature has a live peer, or during an
     * explicit reconnect/network-transition boost. Folder-only idle operation
     * remains lock-free. Dart renews it every 10 minutes; the timeout is a
     * safety net only.
     */
    private var connectionWakeLock: PowerManager.WakeLock? = null

    // Current notification channel: true = normal importance, false = the
    // quieter IMPORTANCE_MIN channel. Android may still show either entry.
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
    // startup default (no session is live yet), then toggled directly by
    // AppState._setDiscoveryLockEnabled whenever any paired peer still needs
    // discovery. onDestroy still releases it
    // unconditionally as a final safety net.
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        notifVisible = desiredNotificationVisible
        ensureChannels()
        val notif = buildNotification("Conduit is running", notifVisible)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
        // NOTE (Roadmap Phase 0.4, ownership fixed post-audit): a long-held
        // blanket wake lock was removed. The transfer- and connection-tied
        // wake locks are owned by THIS service (acquire/release/renew
        // forwarded over the conduit/wakelock channel), so they
        // survive Activity destruction (e.g. swipe-from-recents) as long as
        // this service is alive. No blanket lock is held while idle.
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        baseWakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Conduit::Base")
        baseWakeLock?.setReferenceCounted(false)

        // Hold the engine itself, not merely a notification. If Android created
        // this service after process death or boot, ensureEngine executes Dart's
        // entrypoint and AppState restores the listener, watchers, and peers.
        flutterEngine = ConduitEngineHost.ensureEngine(this)

        // A multicast lock does not keep the CPU awake. NetworkCallback gives
        // reconnection a bounded wake window after Wi-Fi/network transitions.
        try {
            val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            connectivity.registerDefaultNetworkCallback(networkCallback)
        } catch (_: Throwable) {}
        wakeForReconnect()

        if (desiredDiscoveryNeeded) acquireMulticastLock()
        if (desiredTransferLock) acquireTransferWakeLock()
        if (desiredConnectionLock) acquireConnectionWakeLock()
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

    /** Acquire (or renew) the transfer-tied lock with a fresh timeout window.
     * Safe to call repeatedly — each call re-arms the timer, which is exactly
     * how Dart's 45s renewal keeps it alive for the duration of a burst. */
    private fun acquireTransferWakeLock() {
        if (transferWakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            transferWakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Conduit::Transfer",
            )
            transferWakeLock?.setReferenceCounted(false)
        }
        if (transferWakeLock?.isHeld == true) {
            try { transferWakeLock?.release() } catch (_: Throwable) {}
        }
        transferWakeLock?.acquire(TRANSFER_LOCK_TIMEOUT_MS)
    }

    private fun releaseTransferWakeLock() {
        if (transferWakeLock?.isHeld == true) {
            try { transferWakeLock?.release() } catch (_: Throwable) {}
        }
    }

    /** Acquire (or renew) the clipboard/recovery lock. */
    private fun acquireConnectionWakeLock() {
        if (connectionWakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            connectionWakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "Conduit::Connection",
            )
            connectionWakeLock?.setReferenceCounted(false)
        }
        if (connectionWakeLock?.isHeld == true) {
            try { connectionWakeLock?.release() } catch (_: Throwable) {}
        }
        connectionWakeLock?.acquire(CONNECTION_LOCK_TIMEOUT_MS)
    }

    private fun releaseConnectionWakeLock() {
        if (connectionWakeLock?.isHeld == true) {
            try { connectionWakeLock?.release() } catch (_: Throwable) {}
        }
    }

    private fun applyNotificationVisibility(visible: Boolean) {
        notifVisible = visible
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification("Conduit is running", visible))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // ACTION_START or START_STICKY recreation (null intent). Control updates
        // are applied directly through the in-process service instance, so they
        // never create/restart a foreground service from a background isolate.
        return START_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        try {
            val connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            connectivity.unregisterNetworkCallback(networkCallback)
        } catch (_: Throwable) {}
        mainHandler.removeCallbacksAndMessages(null)
        pendingNetworkSignal = null
        currentNetwork = null
        flutterEngine = null
        if (baseWakeLock?.isHeld == true) {
            try { baseWakeLock?.release() } catch (_: Throwable) {}
        }
        releaseTransferWakeLock()
        releaseConnectionWakeLock()
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

            // Quieter channel: no sound, minimal interruption. Android may
            // still show the foreground-service entry or list it in Active apps.
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
     * [visible] true → CH_ID_NORMAL (normal importance),
     *           false → CH_ID_SILENT (minimal interruption).
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
