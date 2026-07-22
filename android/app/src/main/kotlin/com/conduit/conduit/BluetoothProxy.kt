package com.conduit.conduit

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Bluetooth Classic RFCOMM transport exposed to Dart as loopback TCP. */
object BluetoothProxy {
    private const val CHANNEL = "conduit/bluetooth"
    private const val SERVICE_NAME = "Conduit"
    private const val PERMISSION_REQUEST = 4210
    private const val CONNECT_TIMEOUT_MS = 5_000L
    private val SERVICE_UUID: UUID =
        UUID.fromString("7c6b8a10-31d2-4d8e-9f54-19adf38c6d21")
    private val LOOPBACK_IPV4: InetAddress = InetAddress.getByName("127.0.0.1")

    private val main = Handler(Looper.getMainLooper())
    private val bridges = ConcurrentHashMap.newKeySet<Closeable>()
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var channel: MethodChannel? = null
    private var adapter: BluetoothAdapter? = null
    private var server: BluetoothServerSocket? = null
    private var dartPort: Int = 0
    private var receiverRegistered = false
    @Volatile private var running = false

    private val discoveryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothDevice.ACTION_FOUND -> {
                    @Suppress("DEPRECATION")
                    val device = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(
                            BluetoothDevice.EXTRA_DEVICE,
                            BluetoothDevice::class.java,
                        )
                    } else {
                        intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    }
                    if (device != null) emitDevice(device)
                }
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    // Paired fallback endpoints come from bondedDevices and the
                    // RFCOMM listener remains active. Repeating inquiry here
                    // only burns radio/CPU after the initial device refresh.
                    if (running) emitStatus("Bluetooth ready - LAN remains preferred")
                }
            }
        }
    }

    fun install(context: Context, messenger: BinaryMessenger, host: Activity? = null) {
        appContext = context.applicationContext
        activity = host
        channel = MethodChannel(messenger, CHANNEL).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        dartPort = call.argument<Int>("dartPort") ?: 0
                        val status = start()
                        result.success(mapOf("started" to running, "status" to status))
                    }
                    "stop" -> {
                        stop()
                        result.success(null)
                    }
                    "refreshDiscovery" -> {
                        emitKnownDevices()
                        try { adapter?.cancelDiscovery() } catch (_: Throwable) {}
                        startDiscovery()
                        result.success(null)
                    }
                    "requestPermissions" -> {
                        requestPermissions()
                        result.success(null)
                    }
                    "connect" -> {
                        val endpoint = call.argument<String>("endpointId")
                        if (endpoint.isNullOrBlank()) {
                            result.error("BLUETOOTH_ENDPOINT", "Missing Bluetooth address", null)
                        } else {
                            connect(endpoint, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun start(): String {
        val context = appContext ?: return "Bluetooth host unavailable"
        if (dartPort <= 0) return "Bluetooth could not determine the Conduit port"
        adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: return "This device has no Bluetooth adapter"
        if (!hasPermissions(context)) {
            running = false
            emitStatus("Bluetooth permission required")
            return "Bluetooth permission required"
        }
        if (adapter?.isEnabled != true) {
            running = false
            return "Turn on Bluetooth to enable fallback connections"
        }
        if (running) return "Bluetooth ready - LAN remains preferred"
        running = true
        val listenerError = startServer()
        if (listenerError != null) {
            running = false
            emitStatus(listenerError)
            return listenerError
        }
        registerReceiver(context)
        emitKnownDevices()
        startDiscovery()
        emitStatus("Bluetooth ready - LAN remains preferred")
        return "Bluetooth ready - LAN remains preferred"
    }

    private fun requestPermissions() {
        val host = activity ?: run {
            emitStatus("Open Conduit to grant Bluetooth permission")
            return
        }
        if (Build.VERSION.SDK_INT >= 31) {
            host.requestPermissions(
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                ),
                PERMISSION_REQUEST,
            )
        } else {
            host.requestPermissions(
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                PERMISSION_REQUEST,
            )
        }
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        emitStatus(start())
    }

    private fun hasPermissions(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= 31) {
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED &&
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED &&
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun registerReceiver(context: Context) {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(discoveryReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(discoveryReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun startServer(): String? {
        val listening = try {
            adapter?.listenUsingRfcommWithServiceRecord(
                SERVICE_NAME,
                SERVICE_UUID,
            ) ?: return "Bluetooth listener unavailable"
        } catch (t: Throwable) {
            return "Bluetooth listener unavailable: ${t.message}"
        }
        server = listening
        Thread({
            try {
                while (running) {
                    val bluetooth = listening.accept() ?: continue
                    proxyIncoming(bluetooth)
                }
            } catch (t: Throwable) {
                if (running) emitStatus("Bluetooth listener stopped: ${t.message}")
            }
        }, "Conduit-Bluetooth-Accept").start()
        return null
    }

    private fun emitKnownDevices() {
        try {
            adapter?.bondedDevices?.forEach(::emitDevice)
        } catch (_: SecurityException) {
            emitStatus("Bluetooth permission required")
        }
    }

    private fun startDiscovery() {
        if (!running) return
        try {
            if (adapter?.isDiscovering != true) adapter?.startDiscovery()
        } catch (_: SecurityException) {
            emitStatus("Bluetooth scan permission required")
        }
    }

    private fun emitDevice(device: BluetoothDevice) {
        try {
            emit("deviceFound", mapOf(
                "id" to device.address,
                "name" to (device.name ?: "Bluetooth device"),
            ))
        } catch (_: SecurityException) {}
    }

    private fun connect(endpoint: String, result: MethodChannel.Result) {
        Thread({
            var bluetooth: BluetoothSocket? = null
            var localServer: ServerSocket? = null
            var responded = false
            try {
                val btAdapter = adapter ?: throw IllegalStateException("Bluetooth is not started")
                btAdapter.cancelDiscovery()
                val device = btAdapter.getRemoteDevice(endpoint)
                val pendingSocket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                bluetooth = pendingSocket
                val connectFinished = AtomicBoolean(false)
                val timeout = Runnable {
                    if (connectFinished.compareAndSet(false, true)) {
                        closeQuietly(pendingSocket)
                    }
                }
                main.postDelayed(timeout, CONNECT_TIMEOUT_MS)
                pendingSocket.connect()
                if (!connectFinished.compareAndSet(false, true)) {
                    throw IllegalStateException("Bluetooth connection timed out")
                }
                main.removeCallbacks(timeout)
                localServer = ServerSocket(0, 1, LOOPBACK_IPV4)
                bridges.add(localServer)
                val port = localServer.localPort
                responded = true
                main.post { result.success(port) }
                val local = localServer.accept()
                bridges.remove(localServer)
                localServer.close()
                bridge(bluetooth, local)
            } catch (t: Throwable) {
                closeQuietly(bluetooth)
                closeQuietly(localServer)
                if (responded) {
                    emitStatus("Bluetooth bridge closed: ${t.message}")
                } else {
                    main.post { result.error("BLUETOOTH_CONNECT", t.message, null) }
                }
            }
        }, "Conduit-Bluetooth-Connect").start()
    }

    private fun proxyIncoming(bluetooth: BluetoothSocket) {
        Thread({
            try {
                val local = Socket(LOOPBACK_IPV4, dartPort).apply {
                    tcpNoDelay = true
                }
                val device = bluetooth.remoteDevice
                emit("incomingProxy", mapOf(
                    "sourcePort" to local.localPort,
                    "id" to device.address,
                ))
                // Ensure Dart registers the source-port mapping before hello bytes flow.
                Thread.sleep(100)
                bridge(bluetooth, local)
            } catch (t: Throwable) {
                closeQuietly(bluetooth)
                if (running) emitStatus("Incoming Bluetooth connection failed: ${t.message}")
            }
        }, "Conduit-Bluetooth-Incoming").start()
    }

    private fun bridge(bluetooth: BluetoothSocket, local: Socket) {
        bridges.add(bluetooth)
        bridges.add(local)
        val closed = AtomicBoolean(false)
        fun closeBoth() {
            if (!closed.compareAndSet(false, true)) return
            bridges.remove(bluetooth)
            bridges.remove(local)
            closeQuietly(bluetooth)
            closeQuietly(local)
        }
        Thread({
            try {
                bluetooth.inputStream.copyTo(local.getOutputStream(), 32 * 1024)
            } catch (_: Throwable) {
            } finally { closeBoth() }
        }, "Conduit-RFCOMM-to-Dart").start()
        Thread({
            try {
                local.getInputStream().copyTo(bluetooth.outputStream, 32 * 1024)
            } catch (_: Throwable) {
            } finally { closeBoth() }
        }, "Conduit-Dart-to-RFCOMM").start()
    }

    fun stop() {
        running = false
        try { adapter?.cancelDiscovery() } catch (_: Throwable) {}
        closeQuietly(server)
        server = null
        bridges.toList().forEach(::closeQuietly)
        bridges.clear()
        val context = appContext
        if (context != null && receiverRegistered) {
            try { context.unregisterReceiver(discoveryReceiver) } catch (_: Throwable) {}
            receiverRegistered = false
        }
    }

    private fun emit(method: String, arguments: Any) {
        main.post { channel?.invokeMethod(method, arguments) }
    }

    private fun emitStatus(message: String) {
        emit("status", mapOf("message" to message))
    }

    private fun closeQuietly(value: Closeable?) {
        try { value?.close() } catch (_: Throwable) {}
    }
}
