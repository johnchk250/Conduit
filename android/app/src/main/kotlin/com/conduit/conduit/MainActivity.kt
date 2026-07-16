package com.conduit.conduit

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.StatFs
import android.os.Vibrator
import android.os.VibrationEffect
import android.os.VibratorManager
import android.media.RingtoneManager
import android.media.Ringtone
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {

    companion object {
        private const val CH_PICK_TREE = "conduit/saf_pick_tree"
        private const val CH_SAF = "conduit/saf"
        // Roadmap Phase 0.4 + Phase 1: foreground-service control + battery
        // optimization guidance. Owned here so the Dart AppState routes the
        // platform wiring through a single host rather than the sync engine.
        private const val CH_SYNC = "conduit/sync_service"
        private const val CH_WAKELOCK = "conduit/wakelock"
        // Roadmap Phase 3d: outbound pipe → Dart when the user shares files into
        // Conduit from another app's share sheet.
        private const val CH_SHARE = "conduit/share_receive"
        // Roadmap Phase 2 clipboard: native write path for Android background
        // clipboard sync. Using applicationContext (foreground-service process)
        // instead of Flutter's activity-bound Clipboard.setData(), so Android 10+
        // allows the write even when the Activity is paused.
        private const val CH_CLIPBOARD = "conduit/clipboard"
        private const val REQ_PICK_TREE = 4201
        private const val REQ_POST_NOTIFICATIONS = 4202

        // Stable key for the cached FlutterEngine. The engine is saved here in
        // onDestroy() and retrieved in provideFlutterEngine() so that the Dart
        // isolate (AppState, TCP sessions, heartbeat timers) keeps running when
        // the Activity is destroyed (swipe from recents, config change, etc.).
        // This is the Flutter-idiomatic equivalent of KDE Connect keeping its
        // connection manager in a long-lived Service rather than an Activity.
        const val ENGINE_ID = "conduit_main_engine"
    }

    private var pendingTreeResult: MethodChannel.Result? = null
    private var startServiceAfterNotificationPermission = false

    // Phase 3d: channel used to push incoming share URIs to the Dart side.
    // Lateinit because it is created inside configureFlutterEngine.
    private lateinit var shareChannel: MethodChannel
    private var shareHandlerReady = false
    private val pendingShareUris = mutableListOf<String>()

    private var activeRingtone: Ringtone? = null
    private var activeVibrator: Vibrator? = null
    private var alertHandler: Handler? = null
    private val alertStopRunnable = Runnable {
        stopAlertSoundAndVibration()
    }

    // Keep the Dart isolate alive when the Android activity is removed from
    // recents. The foreground service keeps the process foreground; this keeps
    // the sync engine running inside that process instead of destroying it with
    // the UI host.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    // Return the cached engine if one exists (i.e. a previous Activity instance
    // already started Dart and saved it in onDestroy). On first launch the cache
    // is empty, so we fall through to the default which creates a fresh engine
    // and runs main() normally — with the Activity (and its method-channel
    // handlers) already in place, so _chSync.invokeMethod('start') etc. succeed.
    //
    // On every subsequent launch (swipe-from-recents, config change) the cached
    // engine is returned: the same Dart isolate re-attaches, configureFlutterEngine
    // re-registers method-channel handlers on the new Activity, and all existing
    // sessions / timers / AppState remain intact. No reconnect needed.
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(ENGINE_ID)
            ?: super.provideFlutterEngine(context)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Phase 3d: handle a share intent that launched the app cold (i.e. the
        // activity was not yet running when the user tapped "Conduit" in the
        // share sheet). The channel is not ready yet at this point — we store
        // the intent and flush it after configureFlutterEngine completes.
        _pendingShareIntent = intent
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Phase 3d: handle a share intent delivered to an already-running
        // activity (launchMode="singleTask" ensures we land here, not in a new
        // instance). The share handler may still be warming up, so handleShareIntent buffers safely.
        handleShareIntent(intent)
    }

    // Holds a share intent that arrived in onCreate before the channel existed.
    private var _pendingShareIntent: Intent? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Cache immediately, not only from onDestroy. SyncService starts while
        // this Activity is still alive and must be able to retain the exact
        // engine that owns AppState, its sockets, and its folder watchers.
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)

        super.configureFlutterEngine(flutterEngine)
        acquireMulticastLock()
        BluetoothProxy.install(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            this,
        )

        // Channel 1: launch the system folder picker, return the granted tree URI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_PICK_TREE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> {
                        pendingTreeResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                            )
                        }
                        @Suppress("DEPRECATION")
                        startActivityForResult(intent, REQ_PICK_TREE)
                    }
                    else -> result.notImplemented()
                }
            }

        // Channel 2: SAF operations against a persisted tree URI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_SAF)
            .setMethodCallHandler { call, result -> SafOps.handle(this, call, result) }

        // Channel 3 (Roadmap Phase 1): foreground-service start/stop + open the
        // OS battery-optimization screen so the user can whitelist Conduit.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_SYNC)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            SyncService.start(this)
                            ensurePostNotificationsPermissionForService()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SYNC_SERVICE", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            SyncService.stop(this)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("SYNC_SERVICE", e.message, null)
                        }
                    }
                    "openBatterySettings" -> {
                        // Stock-Android "ignore battery optimizations" path.
                        // The in-app Survival screen documents the OEM-specific
                        // steps beyond this.
                        openBatteryOptimizationSettings()
                        result.success(null)
                    }
                    // Polish: toggle the notification visibility (normal vs silent
                    // channel). Sent by Dart when the user flips the Settings switch.
                    "setNotificationVisibility" -> {
                        val visible = call.argument<Boolean>("visible") ?: true
                        SyncService.setVisibility(this, visible)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Channel 4 (Roadmap Phase 0.4): transfer-tied wake lock. Acquire a
        // short, renewable lock only while bytes are actually moving; release
        // on idle so Doze takes over. Forwarded to the running SyncService,
        // which owns the actual PowerManager wake lock (post-audit fix: this
        // used to be acquired directly on the Activity and was released the
        // moment the Activity was destroyed, e.g. a swipe-from-recents mid-
        // transfer — see SyncService.transferWakeLock doc for the full story).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_WAKELOCK)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        SyncService.setTransferLockEnabled(this, true)
                        result.success(null)
                    }
                    "release" -> {
                        SyncService.setTransferLockEnabled(this, false)
                        result.success(null)
                    }
                    "acquireConnection" -> {
                        SyncService.setConnectionLockEnabled(this, true)
                        result.success(null)
                    }
                    "releaseConnection" -> {
                        SyncService.setConnectionLockEnabled(this, false)
                        result.success(null)
                    }
                    // Roadmap Phase 0.6 (battery): toggles SyncService's
                    // MulticastLock, driven by AppState whenever the set of
                    // live peer sessions goes empty <-> non-empty. See
                    // SyncService.multicastLock doc for the rationale.
                    "acquireDiscovery" -> {
                        SyncService.setDiscoveryNeeded(this, true)
                        result.success(null)
                    }
                    "releaseDiscovery" -> {
                        SyncService.setDiscoveryNeeded(this, false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Channel 5 (Roadmap Phase 3d): push incoming share-sheet file URIs to
        // the Dart side. This channel is write-only from native→Dart; we never
        // need to handle a call FROM Dart here, so no setMethodCallHandler.
        shareChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CH_SHARE
        )
        shareChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "shareHandlerReady" -> {
                    shareHandlerReady = true
                    flushPendingShareUris()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Flush any share intent that arrived in onCreate (cold start) before
        // the channel existed.
        val pending = _pendingShareIntent
        _pendingShareIntent = null
        if (pending != null) handleShareIntent(pending)

        // Channel 6 (Roadmap Phase 2): native clipboard write for the PC→phone
        // inbound path. Flutter's Clipboard.setData() uses the Activity context,
        // which Android 10+ may reject when the Activity is paused. Calling
        // ClipboardManager directly via applicationContext goes through the same
        // process that hosts the foreground SyncService, which Android allows.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_CLIPBOARD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "write" -> {
                        try {
                            val text = call.argument<String>("text") ?: ""
                            val cm = applicationContext
                                .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("Conduit", text))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CLIPBOARD_WRITE", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Channel for Phone Dashboard status & alert actions (Roadmap P1 & P2)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "conduit/phone_dashboard")
            .setMethodCallHandler { call, result ->
                val context = applicationContext
                when (call.method) {
                    "getDeviceStatus" -> {
                        try {
                            val statusMap = mutableMapOf<String, Any>()
                            
                            // 1. Battery Status
                            val batteryIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                            val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                            val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                            val pct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
                            statusMap["batteryPct"] = pct
                            
                            val bStatus = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                            val powerState = when (bStatus) {
                                BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                                BatteryManager.BATTERY_STATUS_FULL -> "full"
                                BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                                BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "discharging"
                                else -> "unknown"
                            }
                            statusMap["power"] = powerState
                            
                            // 2. Storage Status
                            val filesDir = context.filesDir
                            val stat = StatFs(filesDir.path)
                            statusMap["storageAvailableBytes"] = stat.availableBytes
                            statusMap["storageTotalBytes"] = stat.totalBytes
                            
                            // 3. Power Manager States
                            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                            statusMap["powerSaverMode"] = pm.isPowerSaveMode
                            statusMap["batteryOptimizationWarning"] = !pm.isIgnoringBatteryOptimizations(context.packageName)
                            
                            result.success(statusMap)
                        } catch (e: Exception) {
                            result.error("DEVICE_STATUS_ERROR", e.message, null)
                        }
                    }
                    "setPhoneAlertEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val prefs = context.getSharedPreferences("conduit_phone_dashboard", Context.MODE_PRIVATE)
                        prefs.edit().putBoolean("allow_phone_alert", enabled).apply()
                        result.success(null)
                    }
                    "playPhoneAlert" -> {
                        val prefs = context.getSharedPreferences("conduit_phone_dashboard", Context.MODE_PRIVATE)
                        val allowed = prefs.getBoolean("allow_phone_alert", true)
                        if (!allowed) {
                            result.success("disabled")
                            return@setMethodCallHandler
                        }
                        
                        val started = playAlertSoundAndVibration(context)
                        if (started) {
                            result.success("started")
                        } else {
                            result.success("failed")
                        }
                    }
                    "stopPhoneAlert" -> {
                        stopAlertSoundAndVibration()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // -------------------------------------------------------------------------
    // Phase 3d — share-sheet intent handling
    // -------------------------------------------------------------------------

    /// Extracts content:// URIs from an incoming ACTION_SEND / ACTION_SEND_MULTIPLE
    /// intent and forwards them to the Dart side via [shareChannel].
    /// Safe to call with any intent — non-share intents are silently ignored.
    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val uris = mutableListOf<String>()

        when (intent.action) {
            Intent.ACTION_SEND -> {
                // Single file: URI is in EXTRA_STREAM
                @Suppress("DEPRECATION")
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                if (uri != null) uris.add(uri.toString())
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                // Multiple files: list of URIs in EXTRA_STREAM
                val list: ArrayList<Parcelable>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                        ?.let { ArrayList(it) }
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                list?.forEach { p -> (p as? Uri)?.let { uris.add(it.toString()) } }
            }
            else -> return // not a share intent — ignore
        }

        if (uris.isEmpty()) return

        if (!::shareChannel.isInitialized || !shareHandlerReady) {
            pendingShareUris.addAll(uris)
            return
        }

        // Invoke the Dart handler. invokeMethod is fire-and-forget from the
        // native side; the Dart handler picks it up asynchronously.
        shareChannel.invokeMethod("incomingFiles", mapOf("uris" to uris))
    }

    private fun flushPendingShareUris() {
        if (!::shareChannel.isInitialized || !shareHandlerReady) return
        if (pendingShareUris.isEmpty()) return
        val uris = pendingShareUris.toList()
        pendingShareUris.clear()
        shareChannel.invokeMethod("incomingFiles", mapOf("uris" to uris))
    }

    // -------------------------------------------------------------------------
    private fun ensurePostNotificationsPermissionForService(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }
        startServiceAfterNotificationPermission = true
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQ_POST_NOTIFICATIONS,
        )
        return false
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            if (startServiceAfterNotificationPermission) {
                startServiceAfterNotificationPermission = false
                try {
                    SyncService.start(this)
                } catch (_: Throwable) {}
            }
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        BluetoothProxy.onPermissionResult(requestCode)
    }
    /// Open the battery-optimization screen. Prefer the direct "ignore battery
    /// optimizations" prompt for THIS app; if that isn't appropriate (we already
    /// have permission, or the OEM hides it), fall back to the app's
    /// battery-settings page.
    private fun openBatteryOptimizationSettings() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val pkg = packageName
        try {
            if (!pm.isIgnoringBatteryOptimizations(pkg)) {
                val intent = Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                ).apply {
                    data = Uri.parse("package:$pkg")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
                return
            }
        } catch (_: Throwable) {
            // fall through to the all-apps list
        }
        try {
            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            startActivity(intent)
        } catch (_: Throwable) {
            // last resort: the app's own info page
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .apply {
                        data = Uri.parse("package:$pkg")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                startActivity(intent)
            } catch (_: Throwable) {}
        }
    }

    // MulticastLock so the Dart isolate's UDP discovery listener actually
    // receives broadcast beacons. Mirrors the lock held by SyncService so
    // auto-discovery works even before/independent of the foreground service
    // (e.g. on first launch before notification permission is granted). The
    // WifiManager hands out one named lock per process; we use a different name
    // than the service so the two don't share reference counts. Released in
    // onDestroy.
    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            val lock = wifi.createMulticastLock("Conduit::DiscoveryActivity")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
        } catch (_: Throwable) {
            // Best-effort: discovery degrades gracefully to manual pairing.
        }
    }

    private fun playAlertSoundAndVibration(context: Context): Boolean {
        stopAlertSoundAndVibration()

        try {
            val alertUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            
            if (alertUri != null) {
                activeRingtone = RingtoneManager.getRingtone(context, alertUri)
                activeRingtone?.play()
            }

            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            activeVibrator = vibrator

            val pattern = longArrayOf(0, 500, 500)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(pattern, 0)
            }

            alertHandler = Handler(Looper.getMainLooper())
            alertHandler?.postDelayed(alertStopRunnable, 25000)

            return true
        } catch (e: Exception) {
            e.printStackTrace()
            stopAlertSoundAndVibration()
            return false
        }
    }

    private fun stopAlertSoundAndVibration() {
        try {
            activeRingtone?.stop()
        } catch (_: Exception) {}
        activeRingtone = null

        try {
            activeVibrator?.cancel()
        } catch (_: Exception) {}
        activeVibrator = null

        alertHandler?.removeCallbacks(alertStopRunnable)
        alertHandler = null
    }

    override fun onDestroy() {
        stopAlertSoundAndVibration()
        // Save the running engine to cache BEFORE releasing anything.
        // shouldDestroyEngineWithHost()=false means Flutter will not call
        // engine.destroy() — but without this cache entry the engine object
        // has no strong reference after the Activity is gone and the GC can
        // collect it, silently killing the Dart isolate and all open sockets.
        // With the cache entry the engine stays alive; the next MainActivity
        // calls provideFlutterEngine(), retrieves it, and re-attaches without
        // restarting Dart or losing any sessions.
        flutterEngine?.let { FlutterEngineCache.getInstance().put(ENGINE_ID, it) }


        // Activity method-channel handlers capture this Activity. Replace the
        // background-critical handlers with application-context versions before
        // detaching, so the retained engine can keep using SAF and service
        // controls without leaking or calling a destroyed Activity.
        flutterEngine?.let {
            ConduitEngineHost.installBackgroundChannels(applicationContext, it)
        }

        // Note: the transfer/connection wake locks are no longer released
        // here. They now live in SyncService (see its class doc for why),
        // so they correctly survive this Activity's destruction — e.g. a
        // swipe-from-recents mid-transfer no longer kills the lock.
        val mlock = multicastLock
        multicastLock = null
        try {
            if (mlock != null && mlock.isHeld) mlock.release()
        } catch (_: Throwable) {}
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_TREE) {
            val r = pendingTreeResult
            pendingTreeResult = null
            val treeUri = data?.data
            if (resultCode == RESULT_OK && treeUri != null) {
                // Persist the permission so it survives reboots.
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                r?.success(treeUri.toString())
            } else {
                r?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
