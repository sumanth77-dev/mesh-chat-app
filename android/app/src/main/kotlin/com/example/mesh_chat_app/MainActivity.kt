package com.example.mesh_chat_app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.*
import android.net.wifi.WpsInfo
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.net.ServerSocket
import java.net.Socket
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity: FlutterActivity() {

    private val CHANNEL = "wifi_direct"
    private val TAG = "WifiDirect"

    private lateinit var manager: WifiP2pManager
    private lateinit var channel: WifiP2pManager.Channel
    private lateinit var receiver: BroadcastReceiver
    private lateinit var intentFilter: IntentFilter

    private var peerList: MutableList<WifiP2pDevice> = mutableListOf()
    private var methodChannel: MethodChannel? = null
    private var isGroupOwner = false
    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private val connectedClients: MutableList<Socket> = mutableListOf()
    private var receiverRegistered = false

    private val PERMISSION_REQUEST_CODE = 1001

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "MainActivity created")

        manager = getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
        channel = manager.initialize(this, mainLooper, null)

        intentFilter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }

        receiver = WiFiP2pBroadcastReceiver()

        MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CHANNEL)
            .also { methodChannel = it }
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermissions" -> result.success(checkAndRequestPermissions())
                    "discover" -> startDiscovery(result)
                    "connect" -> {
                        val addr = call.argument<String>("address")
                        if (addr != null) connectToDevice(addr, result)
                        else result.error("INVALID_ARGS", "Device address required", null)
                    }
                    "disconnect" -> disconnectFromGroup(result)
                    "sendMessage" -> {
                        val msg = call.argument<String>("message")
                        if (msg != null) sendMessageToDevice(msg, result)
                        else result.error("INVALID_ARGS", "Message required", null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun checkAndRequestPermissions(): Boolean {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.CHANGE_WIFI_STATE,
            Manifest.permission.INTERNET,
            Manifest.permission.ACCESS_NETWORK_STATE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        val needed = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (needed.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), PERMISSION_REQUEST_CODE)
            return false
        }
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    // 🔍 Start peer discovery
    private fun startDiscovery(result: MethodChannel.Result) {
        manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { result.success("Discovery started") }
            override fun onFailure(reason: Int) {
                result.error("DISCOVERY_FAILED", "Reason: $reason", null)
            }
        })
    }

    // ─── CONNECT FLOW (4 steps) ─────────────────────────────────────────────
    //
    // ROOT CAUSE OF CONNECT_FAILED:0 (WifiP2pManager.ERROR):
    //   Android's removeGroup() fires onSuccess() BEFORE the group is actually
    //   torn down in the WiFi firmware. Calling connect() immediately after
    //   returns ERROR (0) because the framework is still internally cleaning up.
    //
    // FIX: Add delays —
    //   • 1500ms after removeGroup  (let firmware actually tear down the group)
    //   •  500ms after stopDiscovery (let radio settle)
    //   • Retry up to 3x on both BUSY (2) and ERROR (0)
    // ────────────────────────────────────────────────────────────────────────

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    // Step 1 — cancel any pending invitation
    private fun connectToDevice(deviceAddress: String, result: MethodChannel.Result) {
        Log.d(TAG, "🔗 [1/4] cancelConnect → $deviceAddress")
        manager.cancelConnect(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "✅ cancelConnect ok")
                removeAnyExistingGroup(deviceAddress, result)
            }
            override fun onFailure(r: Int) {
                Log.d(TAG, "ℹ️ cancelConnect ($r) — continuing")
                removeAnyExistingGroup(deviceAddress, result)
            }
        })
    }

    // Step 2 — destroy any leftover group, then connect
    private fun removeAnyExistingGroup(deviceAddress: String, result: MethodChannel.Result) {
        Log.d(TAG, "🔗 [2/3] removeGroup")
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "✅ removeGroup ok — waiting 600ms for firmware cleanup")
                handler.postDelayed({ doConnect(deviceAddress, result, 1) }, 600)
            }
            override fun onFailure(r: Int) {
                Log.d(TAG, "ℹ️ removeGroup ($r) — no group — connecting immediately")
                handler.postDelayed({ doConnect(deviceAddress, result, 1) }, 200)
            }
        })
    }

    // Step 4 — actual connect with retry on BUSY (2) OR ERROR (0)
    private fun doConnect(deviceAddress: String, result: MethodChannel.Result, attempt: Int) {
        Log.d(TAG, "🔗 [4/4] connect() attempt $attempt to $deviceAddress")
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            wps.setup = WpsInfo.PBC
            // groupOwnerIntent=15: THIS device strongly prefers to be Group Owner (hub).
            // This means the device clicking "Connect" becomes the central node.
            // Other devices (B, C, D) all connect to it as clients — star topology.
            groupOwnerIntent = 15
        }
        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "✅ connect() accepted by framework (attempt $attempt)")
                result.success("Connection initiated")
            }
            override fun onFailure(reason: Int) {
                val shouldRetry = (reason == WifiP2pManager.BUSY || reason == WifiP2pManager.ERROR)
                        && attempt < 3
                if (shouldRetry) {
                    val delay = if (reason == WifiP2pManager.ERROR) 1000L else 600L
                    Log.w(TAG, "⚠️ connect() reason=$reason — retry ${attempt+1} in ${delay}ms")
                    handler.postDelayed({ doConnect(deviceAddress, result, attempt + 1) }, delay)
                } else {
                    val msg = when (reason) {
                        WifiP2pManager.ERROR           -> "WiFi Direct error (reason 0). Try: turn WiFi OFF then ON, then retry."
                        WifiP2pManager.P2P_UNSUPPORTED -> "WiFi Direct not supported on this device."
                        WifiP2pManager.BUSY            -> "Framework still busy after 3 tries. Turn WiFi off/on."
                        else                           -> "Connect failed (reason $reason)."
                    }
                    Log.e(TAG, "❌ connect() FINAL FAIL after $attempt tries: $msg")
                    result.error("CONNECT_FAILED", msg, null)
                }
            }
        })
    }

    // 📤 Send message
    private fun sendMessageToDevice(message: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (isGroupOwner) {
                    sendToConnectedClients(message, result)
                } else {
                    if (clientSocket != null && !clientSocket!!.isClosed) {
                        PrintWriter(clientSocket!!.outputStream, true).println(message)
                        Log.d(TAG, "✅ Message sent to Group Owner")
                        runOnUiThread { result.success("Message sent") }
                    } else {
                        Log.e(TAG, "Client socket not connected")
                        runOnUiThread { result.error("NOT_CONNECTED", "Not connected to Group Owner", null) }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error sending: ${e.message}")
                runOnUiThread { result.error("SEND_FAILED", e.message, null) }
            }
        }.start()
    }

    private fun sendToConnectedClients(message: String, result: MethodChannel.Result? = null) {
        synchronized(connectedClients) {
            if (connectedClients.isEmpty()) {
                runOnUiThread { result?.error("NOT_CONNECTED", "No clients connected", null) }
                return
            }
            val dead = mutableListOf<Socket>()
            var anySent = false
            for (socket in connectedClients) {
                try {
                    if (!socket.isClosed) {
                        PrintWriter(socket.outputStream, true).println(message)
                        anySent = true
                    } else dead.add(socket)
                } catch (e: Exception) { dead.add(socket) }
            }
            connectedClients.removeAll(dead)
            runOnUiThread {
                if (anySent) result?.success("Message sent")
                else result?.error("SEND_FAILED", "Failed to send to any client", null)
            }
        }
    }

    // ❌ Disconnect — cancel connect attempt + remove group + cleanup
    private fun disconnectFromGroup(result: MethodChannel.Result) {
        manager.cancelConnect(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() { removeGroup(result) }
            override fun onFailure(reason: Int) { removeGroup(result) } // proceed anyway
        })
    }

    private fun removeGroup(result: MethodChannel.Result) {
        manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "✅ Disconnected from group")
                cleanupSockets()
                result.success("Disconnected")
            }
            override fun onFailure(reason: Int) {
                // Even on failure, clean up local state
                cleanupSockets()
                result.success("Disconnected (forced)")
            }
        })
    }

    // 🧹 Full cleanup — sockets, clients list, group owner state
    private fun cleanupSockets() {
        try { clientSocket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        clientSocket = null
        serverSocket = null
        synchronized(connectedClients) {
            connectedClients.forEach { try { it.close() } catch (_: Exception) {} }
            connectedClients.clear()
        }
        isGroupOwner = false
        Log.d(TAG, "🧹 Sockets cleaned up")
    }

    // 📡 BroadcastReceiver
    private inner class WiFiP2pBroadcastReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val enabled = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1) ==
                            WifiP2pManager.WIFI_P2P_STATE_ENABLED
                    Log.d(TAG, "WiFi P2P enabled: $enabled")
                }

                WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                    manager.requestPeers(channel) { peers ->
                        peerList.clear()
                        peerList.addAll(peers.deviceList)
                        val devices = peerList.map {
                            mapOf("name" to it.deviceName, "address" to it.deviceAddress, "status" to it.status.toString())
                        }
                        runOnUiThread { methodChannel?.invokeMethod("onDevicesFound", devices) }
                    }
                }

                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    manager.requestConnectionInfo(channel) { info ->
                        isGroupOwner = info.isGroupOwner
                        val groupFormed = info.groupFormed
                        Log.d(TAG, "Group formed: $groupFormed | isGO: $isGroupOwner")

                        if (groupFormed) {
                            // Request peers to find who we're connected to
                            // This lets the non-initiating phone identify the connected device
                            manager.requestPeers(channel) { peers ->
                                peerList.clear()
                                peerList.addAll(peers.deviceList)

                                // Find the connected peer (status 0 = CONNECTED in WiFi P2P)
                                val connectedPeer = peerList.firstOrNull { it.status == WifiP2pDevice.CONNECTED }
                                    ?: peerList.firstOrNull() // fallback to first peer

                                val peerAddress = connectedPeer?.deviceAddress ?: ""
                                val peerName = connectedPeer?.deviceName ?: ""

                                Log.d(TAG, "Connected peer: $peerName ($peerAddress)")

                                runOnUiThread {
                                    methodChannel?.invokeMethod("onConnectionChanged", mapOf(
                                        "groupFormed" to true,
                                        "isGroupOwner" to isGroupOwner,
                                        "groupOwnerAddress" to info.groupOwnerAddress?.hostAddress,
                                        "connectedPeerAddress" to peerAddress,
                                        "connectedPeerName" to peerName
                                    ))
                                }

                                // ✅ MESH UPGRADE: Socket management is now handled entirely
                                // in Dart (lib/services/wifi_direct_service.dart).
                                // Dart's WifiDirectService reads 'groupOwnerAddress' from the
                                // onConnectionChanged callback above and opens the socket itself.
                                // DO NOT call startServerSocket() / startClientSocket() here —
                                // doing so would cause both layers to compete on port 8888.
                            }
                        } else {
                            // Group disbanded — reset everything
                            cleanupSockets()
                            runOnUiThread {
                                methodChannel?.invokeMethod("onConnectionChanged", mapOf(
                                    "groupFormed" to false,
                                    "isGroupOwner" to false,
                                    "groupOwnerAddress" to null,
                                    "connectedPeerAddress" to "",
                                    "connectedPeerName" to ""
                                ))
                            }
                        }
                    }
                }

                WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION -> {
                    val device: WifiP2pDevice? = intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_DEVICE)
                    Log.d(TAG, "This device: ${device?.deviceName}")
                }
            }
        }
    }

    // 🖥️ Server socket (Group Owner)
    private fun startServerSocket() {
        if (serverSocket != null && !serverSocket!!.isClosed) {
            Log.d(TAG, "Server socket already running")
            return
        }
        Thread {
            try {
                serverSocket = ServerSocket(8888)
                Log.d(TAG, "✅ Server listening on port 8888")
                while (serverSocket != null && !serverSocket!!.isClosed) {
                    val socket = serverSocket?.accept() ?: break
                    Log.d(TAG, "✅ Client connected from ${socket.inetAddress}")
                    handleClientConnection(socket)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Server socket closed: ${e.message}")
            }
        }.start()
    }

    private fun handleClientConnection(socket: Socket) {
        synchronized(connectedClients) { connectedClients.add(socket) }
        Log.d(TAG, "Total clients: ${connectedClients.size}")
        Thread {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream))
                while (true) {
                    val message = reader.readLine() ?: break
                    Log.d(TAG, "📨 From client: $message")
                    runOnUiThread {
                        methodChannel?.invokeMethod("onMessageReceived", mapOf(
                            "message" to message,
                            "from" to (socket.inetAddress.hostAddress ?: "Unknown")
                        ))
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Client read error: ${e.message}")
            } finally {
                synchronized(connectedClients) { connectedClients.remove(socket) }
                try { socket.close() } catch (_: Exception) {}
            }
        }.start()
    }

    // 📱 Client socket with retry logic
    private fun startClientSocket(groupOwnerAddress: String) {
        if (groupOwnerAddress.isEmpty()) {
            Log.e(TAG, "No group owner address!")
            return
        }
        try { clientSocket?.close() } catch (_: Exception) {}
        clientSocket = null

        Thread {
            var connected = false
            var attempts = 0
            while (!connected && attempts < 10) {
                attempts++
                try {
                    Log.d(TAG, "🔄 Client attempt $attempts to $groupOwnerAddress:8888")
                    val socket = Socket()
                    socket.connect(java.net.InetSocketAddress(groupOwnerAddress, 8888), 3000)
                    clientSocket = socket
                    connected = true
                    Log.d(TAG, "✅ Connected to GO at $groupOwnerAddress")

                    val reader = BufferedReader(InputStreamReader(clientSocket!!.inputStream))
                    while (true) {
                        val message = reader.readLine() ?: break
                        Log.d(TAG, "📨 From GO: $message")
                        runOnUiThread {
                            methodChannel?.invokeMethod("onMessageReceived", mapOf(
                                "message" to message,
                                "from" to "Group Owner"
                            ))
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Client attempt $attempts failed: ${e.message}")
                    try { clientSocket?.close() } catch (_: Exception) {}
                    clientSocket = null
                    if (!connected && attempts < 10) Thread.sleep(1000)
                }
            }
            if (!connected) Log.e(TAG, "❌ Failed after 10 attempts")
        }.start()
    }

    override fun onResume() {
        super.onResume()
        if (!receiverRegistered) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
                    registerReceiver(receiver, intentFilter, Context.RECEIVER_EXPORTED)
                else registerReceiver(receiver, intentFilter)
                receiverRegistered = true
            } catch (e: Exception) { Log.e(TAG, "Register error: ${e.message}") }
        }
    }

    override fun onPause() {
        super.onPause()
        if (receiverRegistered) {
            try { unregisterReceiver(receiver); receiverRegistered = false }
            catch (e: Exception) { Log.e(TAG, "Unregister error: ${e.message}") }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        cleanupSockets()
        if (receiverRegistered) {
            try { unregisterReceiver(receiver); receiverRegistered = false }
            catch (e: Exception) { Log.e(TAG, "onDestroy error: ${e.message}") }
        }
    }
}