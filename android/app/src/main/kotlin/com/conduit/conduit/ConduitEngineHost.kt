package com.conduit.conduit

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.os.StatFs
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Process-level owner of the Flutter engine used by Conduit.
 *
 * Activity recreation is handled by [FlutterEngineCache], but that cache is
 * process memory and therefore cannot restore anything after Android kills the
 * process. [SyncService] calls [ensureEngine] on every creation. A sticky,
 * watchdog, or boot restart can consequently create a fresh engine, execute
 * Dart's normal entrypoint, reload AppState from disk, and reconnect without an
 * Activity ever being opened.
 */
object ConduitEngineHost {
    private const val TAG = "Conduit.EngineHost"

    @Synchronized
    fun ensureEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        val existing = cache.get(MainActivity.ENGINE_ID)
        if (existing != null) {
            return existing
        }

        val appContext = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(appContext)
        loader.ensureInitializationComplete(appContext, null)

        val engine = FlutterEngine(appContext)
        installBackgroundChannels(appContext, engine)
        cache.put(MainActivity.ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        Log.i(TAG, "Started Flutter engine after cold background launch")
        return engine
    }

    /**
     * Install handlers that are safe without an Activity. MainActivity replaces
     * these with its richer UI handlers when it attaches, and installs these
     * again before it detaches.
     */
    fun installBackgroundChannels(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        val messenger = engine.dartExecutor.binaryMessenger

        BluetoothProxy.install(appContext, messenger)

        SafOps.channel(messenger).setMethodCallHandler { call, result ->
            SafOps.handle(appContext, call, result)
        }

        MethodChannel(messenger, "conduit/sync_service")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> SyncService.start(appContext)
                        "stop" -> SyncService.stop(appContext)
                        "setNotificationVisibility" -> SyncService.setVisibility(
                            appContext,
                            call.argument<Boolean>("visible") ?: true,
                        )
                        // Opening settings is intentionally Activity-only.
                        "openBatterySettings" -> {
                            result.error("NO_ACTIVITY", "Battery settings require an Activity", null)
                            return@setMethodCallHandler
                        }
                        "openNotificationSettings" -> {
                            result.error("NO_ACTIVITY", "Notification settings require an Activity", null)
                            return@setMethodCallHandler
                        }
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                    result.success(null)
                } catch (t: Throwable) {
                    result.error("SYNC_SERVICE", t.message, null)
                }
            }

        MethodChannel(messenger, "conduit/wakelock")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquire" -> SyncService.setTransferLockEnabled(appContext, true)
                        "release" -> SyncService.setTransferLockEnabled(appContext, false)
                        "acquireConnection" -> SyncService.setConnectionLockEnabled(appContext, true)
                        "releaseConnection" -> SyncService.setConnectionLockEnabled(appContext, false)
                        "acquireDiscovery" -> SyncService.setDiscoveryNeeded(appContext, true)
                        "releaseDiscovery" -> SyncService.setDiscoveryNeeded(appContext, false)
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                    result.success(null)
                } catch (t: Throwable) {
                    result.error("WAKELOCK", t.message, null)
                }
            }

        MethodChannel(messenger, "conduit/clipboard")
            .setMethodCallHandler { call, result ->
                if (call.method != "write") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val clipboard = appContext.getSystemService(Context.CLIPBOARD_SERVICE)
                        as ClipboardManager
                    clipboard.setPrimaryClip(
                        ClipData.newPlainText("Conduit", call.argument<String>("text") ?: "")
                    )
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("CLIPBOARD_WRITE", t.message, null)
                }
            }

        MethodChannel(messenger, "conduit/phone_dashboard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceStatus" -> {
                        try {
                            val battery = appContext.registerReceiver(
                                null,
                                IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                            )
                            val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                            val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                            val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
                            val stat = StatFs(appContext.filesDir.path)
                            val power = appContext.getSystemService(Context.POWER_SERVICE)
                                as PowerManager
                            result.success(mapOf(
                                "batteryPct" to if (level >= 0 && scale > 0) level * 100 / scale else -1,
                                "power" to when (status) {
                                    BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                                    BatteryManager.BATTERY_STATUS_FULL -> "full"
                                    BatteryManager.BATTERY_STATUS_DISCHARGING,
                                    BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "discharging"
                                    else -> "unknown"
                                },
                                "storageAvailableBytes" to stat.availableBytes,
                                "storageTotalBytes" to stat.totalBytes,
                                "powerSaverMode" to power.isPowerSaveMode,
                                "batteryOptimizationWarning" to
                                    !power.isIgnoringBatteryOptimizations(appContext.packageName),
                            ))
                        } catch (t: Throwable) {
                            result.error("DEVICE_STATUS_ERROR", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

