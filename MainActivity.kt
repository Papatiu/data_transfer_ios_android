package com.example.p2p_data_transfer

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.FlutterStandardTypedData
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import com.google.android.gms.nearby.connection.Strategy
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadTransferUpdate

class MainActivity : FlutterActivity() {
    private val TAG = "MainActivityNearby"
    private val METHOD_CHANNEL = "com.example.multipeer/methods"
    private val EVENT_CHANNEL = "com.example.multipeer/events"

    private val REQUEST_ENABLE_BT = 1010
    private val REQUEST_LOCATION = 1020

    private var eventSink: EventChannel.EventSink? = null
    private lateinit var connectionsClient: ConnectionsClient

    private val discoveredEndpoints = mutableMapOf<String, String>()
    private val connectedEndpoints = mutableSetOf<String>()

    private var isAdvertising = false
    private var isDiscovering = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        connectionsClient = Nearby.getConnectionsClient(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startAdvertising" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val name = args?.get("displayName") as? String ?: android.os.Build.MODEL
                            startAdvertising(name)
                            result.success(null)
                        }
                        "startBrowsing" -> {
                            startDiscovery()
                            result.success(null)
                        }
                        "startBoth" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val name = args?.get("displayName") as? String ?: android.os.Build.MODEL
                            startBothWithDelay(name)
                            result.success(null)
                        }
                        "stop" -> {
                            stopAll()
                            result.success(null)
                        }
                        "sendData" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val dataObj = args?.get("data")
                            val bytes = toByteArray(dataObj)
                            if (bytes != null) {
                                sendDataToAll(bytes)
                                result.success(null)
                            } else {
                                result.error("INVALID", "No data or invalid data", null)
                            }
                        }
                        "invitePeer" -> {
                            val args = call.arguments as? Map<String, Any?>
                            val peerId = args?.get("peerId") as? String
                            if (peerId != null) {
                                requestConnectionToPeer(peerId)
                                result.success(null)
                            } else {
                                result.error("INVALID", "peerId required", null)
                            }
                        }

                        // ----- Native permission helpers -----
                        "getNativePermissions" -> {
                            val btState = getBluetoothStateString()
                            val locState = getLocationStateString()
                            val map = mapOf("bluetooth" to btState, "location" to locState)
                            result.success(map)
                        }
                        "requestBluetooth" -> {
                            requestBluetooth()
                            result.success(null)
                        }
                        "requestLocationPermission" -> {
                            requestLocationPermission()
                            result.success(null)
                        }

                        // fallback no-op for other platform-specific triggers (keeps Dart safe)
                        "triggerLocalNetwork" -> {
                            // no-op on Android (Nearby or Wi-Fi direct flows would go here)
                            result.success(null)
                        }

                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Method handler error", e)
                    result.error("EXCEPTION", e.message, null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    // Robust conversion from possible Flutter channel types to ByteArray
    private fun toByteArray(obj: Any?): ByteArray? {
        if (obj == null) return null
        if (obj is ByteArray) return obj
        if (obj is FlutterStandardTypedData) return obj.data
        if (obj is ArrayList<*>) {
            try {
                val list = obj as ArrayList<*>
                val b = ByteArray(list.size)
                for (i in list.indices) {
                    val v = list[i] as Number
                    b[i] = v.toByte()
                }
                return b
            } catch (e: Exception) {
                return null
            }
        }
        return null
    }

    // ---------- Nearby Callbacks ----------
    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            Log.d(TAG, "onEndpointFound: id=$endpointId name=${info.endpointName}")
            discoveredEndpoints[endpointId] = info.endpointName
            sendEvent(mapOf("event" to "peerFound", "peerId" to endpointId, "displayName" to info.endpointName))
        }

        override fun onEndpointLost(endpointId: String) {
            val name = discoveredEndpoints.remove(endpointId)
            sendEvent(mapOf("event" to "peerLost", "peerId" to endpointId, "displayName" to name))
        }
    }

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            // Auto-accept connection
            try {
                connectionsClient.acceptConnection(endpointId, payloadCallback)
                sendEvent(mapOf("event" to "invitationReceived", "peerId" to endpointId, "displayName" to info.endpointName))
            } catch (e: Exception) {
                sendEvent(mapOf("event" to "error", "message" to "acceptConnection failed: ${e.message}"))
            }
        }

        override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) {
            if (resolution.status.isSuccess) {
                connectedEndpoints.add(endpointId)
                sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "connected"))
            } else {
                connectedEndpoints.remove(endpointId)
                sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "notConnected"))
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedEndpoints.remove(endpointId)
            sendEvent(mapOf("event" to "connectionState", "peerId" to endpointId, "state" to "notConnected"))
        }
    }

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type == Payload.Type.BYTES) {
                val bytes = payload.asBytes()
                if (bytes != null) {
                    val intList = bytes.map { it.toInt() and 0xFF }
                    sendEvent(mapOf("event" to "dataReceived", "peerId" to endpointId, "data" to intList))
                }
            }
        }
        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
    }

    // ---------- Operations ----------
    private fun startAdvertising(name: String) {
        if (isAdvertising) {
            sendEvent(mapOf("event" to "error", "message" to "Already advertising"))
            return
        }
        val advertisingOptions = AdvertisingOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startAdvertising(name, packageName, connectionLifecycleCallback, advertisingOptions)
            .addOnSuccessListener {
                isAdvertising = true
                Log.d(TAG, "startAdvertising success")
                sendEvent(mapOf("event" to "advertisingStarted"))
            }
            .addOnFailureListener { e ->
                isAdvertising = false
                val code = if (e is com.google.android.gms.common.api.ApiException) e.statusCode else -1
                Log.e(TAG, "startAdvertising failed with code $code", e)
                sendEvent(mapOf("event" to "error", "message" to "startAdvertising failed: ${e.message}"))
            }
    }

    private fun startDiscovery() {
        if (isDiscovering) {
            sendEvent(mapOf("event" to "error", "message" to "Already discovering"))
            return
        }
        val discoveryOptions = DiscoveryOptions.Builder().setStrategy(Strategy.P2P_STAR).build()
        connectionsClient.startDiscovery(packageName, endpointDiscoveryCallback, discoveryOptions)
            .addOnSuccessListener {
                isDiscovering = true
                Log.d(TAG, "startDiscovery success")
                sendEvent(mapOf("event" to "browsingStarted"))
            }
            .addOnFailureListener { e ->
                isDiscovering = false
                val code = if (e is com.google.android.gms.common.api.ApiException) e.statusCode else -1
                Log.e(TAG, "startDiscovery failed with code $code", e)
                sendEvent(mapOf("event" to "error", "message" to "startDiscovery failed: ${e.message}"))
            }
    }

    private fun startBothWithDelay(name: String) {
        startAdvertising(name)
        Handler(Looper.getMainLooper()).postDelayed({
            startDiscovery()
        }, 500)
    }

    private fun stopAll() {
        try {
            connectionsClient.stopAllEndpoints()
            if (isAdvertising) connectionsClient.stopAdvertising()
            if (isDiscovering) connectionsClient.stopDiscovery()

            isAdvertising = false
            isDiscovering = false
            connectedEndpoints.clear()
            discoveredEndpoints.clear()

            Log.d(TAG, "stopAll completed")
            sendEvent(mapOf("event" to "stopped"))
        } catch (e: Exception) {
            Log.e(TAG, "stopAll failed", e)
            sendEvent(mapOf("event" to "error", "message" to "stopAll failed: ${e.message}"))
        }
    }

    private fun sendDataToAll(bytes: ByteArray) {
        if (connectedEndpoints.isEmpty()) {
            sendEvent(mapOf("event" to "error", "message" to "No connected peers"))
            return
        }
        val payload = Payload.fromBytes(bytes)
        connectionsClient.sendPayload(connectedEndpoints.toList(), payload)
    }

    private fun requestConnectionToPeer(peerId: String) {
        val name = discoveredEndpoints[peerId] ?: "FlutterDevice"
        connectionsClient.requestConnection(name, peerId, connectionLifecycleCallback)
            .addOnSuccessListener {
                sendEvent(mapOf("event" to "invitationSent", "peerId" to peerId))
            }.addOnFailureListener { e ->
                sendEvent(mapOf("event" to "error", "message" to "requestConnection failed: ${e.message}"))
            }
    }

    private fun sendEvent(map: Map<String, Any?>) {
        Handler(Looper.getMainLooper()).post {
            try {
                eventSink?.success(map)
            } catch (e: Exception) {
                Log.w(TAG, "Event send failed", e)
            }
        }
    }

    // ---------- Native-permissions helpers ----------
    private fun getBluetoothStateString(): String {
        val adapter = BluetoothAdapter.getDefaultAdapter() ?: return "unavailable"
        return if (adapter.isEnabled) "enabled" else "disabled"
    }

    private fun getLocationStateString(): String {
        return try {
            val perm = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            if (perm == PackageManager.PERMISSION_GRANTED) "granted" else "denied"
        } catch (e: Exception) {
            "unknown"
        }
    }

    private fun requestBluetooth() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null) {
            sendEvent(mapOf("event" to "error", "message" to "Bluetooth not available"))
            return
        }
        if (!adapter.isEnabled) {
            val enableBt = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            try {
                startActivityForResult(enableBt, REQUEST_ENABLE_BT)
            } catch (e: Exception) {
                sendEvent(mapOf("event" to "error", "message" to "Cannot request enable bluetooth: ${e.message}"))
            }
        }
    }

    private fun requestLocationPermission() {
        val needed = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            ActivityCompat.requestPermissions(this as Activity, needed, REQUEST_LOCATION)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LOCATION) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            sendEvent(mapOf("event" to "nativePermissionResult", "permission" to "location", "granted" to granted))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_ENABLE_BT) {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            val enabled = adapter?.isEnabled == true
            sendEvent(mapOf("event" to "nativePermissionResult", "permission" to "bluetooth", "granted" to enabled))
        }
    }
}
