// ============================================================
// FILE: lib/services/wifi_direct_service.dart
//
// KEY FIX (was the main bug):
//   The old code used `await for` on the raw socket stream to read
//   the handshake, then tried to call socket.listen() again inside
//   SocketManager.addConnection(). A Dart stream can only have ONE
//   listener — the second listen() was silently ignored, so no
//   messages ever came through after the handshake.
//
//   FIX: Read the socket as raw bytes into a line buffer manually
//   using socket.listen() ONCE. When the first complete line (the
//   handshake) arrives, parse it and then pass ALL subsequent data
//   to SocketManager via a shared StreamController. This way the
//   socket stream is only subscribed to once, ever.
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/connected_device.dart';
import 'socket_manager.dart';

typedef PeerConnectedCallback = void Function(ConnectedDevice device);
typedef PeerDisconnectedCallback = void Function(String deviceId);

class WifiDirectService {
  static const MethodChannel _platform = MethodChannel('wifi_direct');

  final SocketManager socketManager;
  final String myDeviceId;
  final String myDeviceName;

  // ── Server socket (Group Owner only) ─────────────────────
  ServerSocket? _serverSocket;
  bool _serverRunning = false;

  // ── Auto-rescan timer ────────────────────────────────────
  Timer? _rescanTimer;
  bool _isConnected = false;

  // ── Debounce timer for groupFormed=false ─────────────────
  // Android fires groupFormed=false briefly when a 3rd peer joins the GO.
  // We wait 1.5s before actually tearing down — if groupFormed=true
  // arrives in that window we cancel the teardown.
  Timer? _groupDisbandTimer;

  // ── Callbacks ────────────────────────────────────────────
  Function(List<Map<String, dynamic>> devices)? onDevicesFound;
  Function(Map<String, dynamic> connectionInfo)? onConnectionChanged;
  PeerConnectedCallback? onPeerConnected;
  PeerDisconnectedCallback? onPeerDisconnected;

  WifiDirectService({
    required this.socketManager,
    required this.myDeviceId,
    required this.myDeviceName,
  }) {
    _setupMethodChannel();
    // Handle peer_announce: when GO tells us about another client,
    // we directly TCP-connect to that client's IP.
    socketManager.onSystemMessage = _handleSystemMessage;
  }

  // -----------------------------------------------------------
  // _setupMethodChannel()
  // -----------------------------------------------------------
  void _setupMethodChannel() {
    _platform.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDevicesFound':
          final devices = List<Map<String, dynamic>>.from(
            (call.arguments as List).map((d) => Map<String, dynamic>.from(d)),
          );
          onDevicesFound?.call(devices);
          break;

        case 'onConnectionChanged':
          final info = Map<String, dynamic>.from(call.arguments);
          onConnectionChanged?.call(info);

          final groupFormed = info['groupFormed'] as bool? ?? false;
          final isGO = info['isGroupOwner'] as bool? ?? false;
          final goAddress = info['groupOwnerAddress'] as String? ?? '';

          if (groupFormed) {
            // Cancel any pending teardown — group is alive
            _groupDisbandTimer?.cancel();
            _groupDisbandTimer = null;

            _stopRescanTimer();

            // ALL devices start a TCP server so other clients can connect
            // directly to them (peer-to-peer within the same P2P network).
            _startServerSocket();

            // Clients also connect to the GO's server
            if (!isGO && goAddress.isNotEmpty && !_isConnected) {
              _connectClientSocket(goAddress);
            }
            _isConnected = true;
          } else {
            // Debounce: wait 1.5s before tearing down.
            // Android fires groupFormed=false briefly when a 3rd device joins
            // the GO's group. The follow-up groupFormed=true cancels this timer.
            _groupDisbandTimer?.cancel();
            _groupDisbandTimer = Timer(
              const Duration(milliseconds: 1500),
              () {
                _isConnected = false;
                _serverRunning = false;
                _stopServerSocket();
                _groupDisbandTimer = null;
                debugPrint('⏰ [WifiDirect] Group disband confirmed (debounced)');
              },
            );
          }
          break;

        default:
          debugPrint('[WifiDirectService] Unknown method: ${call.method}');
      }
    });
  }

  // -----------------------------------------------------------
  // startAutoRescan()
  // Periodically re-triggers discovery so the device list
  // stays fresh automatically every 30 seconds.
  // -----------------------------------------------------------
  void startAutoRescan() {
    _stopRescanTimer();
    _rescanTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_isConnected) {
        try {
          await discoverDevices();
          debugPrint('🔄 [WifiDirect] Auto-rescan triggered');
        } catch (_) {}
      }
    });
  }

  void _stopRescanTimer() {
    _rescanTimer?.cancel();
    _rescanTimer = null;
  }

  // -----------------------------------------------------------
  // requestPermissions()
  // -----------------------------------------------------------
  Future<bool> requestPermissions() async {
    final results = await [
      Permission.location,
      Permission.nearbyWifiDevices,
    ].request();

    final locationGranted = results[Permission.location]?.isGranted ?? false;
    if (!locationGranted) {
      debugPrint('❌ [WifiDirect] Location permission denied');
      return false;
    }

    try {
      final ok = await _platform.invokeMethod<bool>('checkPermissions');
      return ok ?? true;
    } catch (_) {
      return true;
    }
  }

  // -----------------------------------------------------------
  // discoverDevices()
  // -----------------------------------------------------------
  Future<void> discoverDevices() async {
    try {
      await _platform.invokeMethod('discover');
      debugPrint('🔍 [WifiDirect] Discovery started');
    } on PlatformException catch (e) {
      debugPrint('❌ [WifiDirect] Discovery failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  // -----------------------------------------------------------
  // connectToDevice()
  // Auto-retries on BUSY (reason=2) up to 3 times.
  // -----------------------------------------------------------
  Future<void> connectToDevice(String deviceAddress) async {
    const maxTries = 3;
    for (int attempt = 1; attempt <= maxTries; attempt++) {
      try {
        await _platform.invokeMethod('connect', {'address': deviceAddress});
        debugPrint('🔗 [WifiDirect] Connect initiated to $deviceAddress (attempt $attempt)');
        return; // success — framework accepted the request
      } on PlatformException catch (e) {
        final isBusy = e.message?.toLowerCase().contains('busy') == true
            || e.code == 'CONNECT_FAILED';
        debugPrint('⚠️ [WifiDirect] Connect attempt $attempt failed: ${e.code} ${e.message}');
        if (isBusy && attempt < maxTries) {
          debugPrint('⏳ [WifiDirect] Retrying in 2s...');
          await Future.delayed(const Duration(seconds: 2));
        } else {
          rethrow;
        }
      }
    }
  }

  // -----------------------------------------------------------
  // disconnect()
  // -----------------------------------------------------------
  Future<void> disconnect() async {
    try {
      await _platform.invokeMethod('disconnect');
      _stopServerSocket();
      _isConnected = false;
      debugPrint('✅ [WifiDirect] Disconnected');
    } on PlatformException catch (e) {
      debugPrint('❌ [WifiDirect] Disconnect failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  // -----------------------------------------------------------
  // _startServerSocket()
  // Group Owner listens on port 8888 for client connections.
  // -----------------------------------------------------------
  Future<void> _startServerSocket() async {
    if (_serverRunning) {
      debugPrint('ℹ️ [WifiDirect] Server already running');
      return;
    }
    _serverRunning = true;

    try {
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 8888,
          shared: true);
      debugPrint('🖥️ [WifiDirect] Server listening on port 8888');

      _serverSocket!.listen(
        (Socket clientSocket) {
          debugPrint(
              '📱 [WifiDirect] Client connected from ${clientSocket.remoteAddress.address}');
          _performHandshake(clientSocket, isServerSide: true);
        },
        onError: (e) {
          debugPrint('❌ [WifiDirect] Server error: $e');
          _serverRunning = false;
        },
        onDone: () {
          debugPrint('🔌 [WifiDirect] Server socket closed');
          _serverRunning = false;
        },
      );
    } catch (e) {
      debugPrint('❌ [WifiDirect] Failed to start server: $e');
      _serverRunning = false;
    }
  }

  // -----------------------------------------------------------
  // _connectClientSocket()
  // Client connects to Group Owner with retry logic.
  // -----------------------------------------------------------
  Future<void> _connectClientSocket(String goAddress) async {
    // Give the P2P network interface 2 seconds to get an IP assigned
    // before we start hammering the connection.
    await Future.delayed(const Duration(seconds: 2));
    int attempts = 0;
    const maxAttempts = 15;

    while (attempts < maxAttempts) {
      attempts++;
      try {
        debugPrint(
            '🔄 [WifiDirect] Client attempt $attempts/$maxAttempts to $goAddress:8888');
        final socket = await Socket.connect(
          goAddress,
          8888,
          timeout: const Duration(seconds: 4),
        );
        debugPrint('✅ [WifiDirect] TCP connected to Group Owner at $goAddress');
        _performHandshake(socket);
        return;
      } catch (e) {
        debugPrint('⚠️ [WifiDirect] Attempt $attempts failed: $e');
        if (attempts < maxAttempts) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    debugPrint('❌ [WifiDirect] All $maxAttempts connection attempts failed');
    // Wait 2 extra seconds and make one final attempt before giving up
    await Future.delayed(const Duration(seconds: 2));
    try {
      debugPrint('🔄 [WifiDirect] Client FINAL attempt to $goAddress:8888');
      final socket = await Socket.connect(goAddress, 8888,
          timeout: const Duration(seconds: 6));
      debugPrint('✅ [WifiDirect] TCP connected (final attempt) to $goAddress');
      _performHandshake(socket);
    } catch (e) {
      debugPrint('❌ [WifiDirect] Final attempt also failed: $e');
    }
  }

  // -----------------------------------------------------------
  // _handleSystemMessage()
  // Called when SocketManager intercepts a type='system' message.
  // Currently handles 'peer_announce' — the GO tells each existing
  // client about a newly joined client so they can connect directly.
  // -----------------------------------------------------------
  void _handleSystemMessage(Map<String, dynamic> msg, String fromDeviceId) {
    final action = msg['action'] as String? ?? '';
    if (action == 'peer_announce') {
      final ip = msg['ip'] as String? ?? '';
      final deviceId = msg['deviceId'] as String? ?? '';
      final deviceName = msg['deviceName'] as String? ?? 'Unknown';
      if (ip.isEmpty || deviceId == myDeviceId) return;
      // Don't connect if already connected to this peer
      if (socketManager.connectedDeviceIds.contains(deviceId)) return;
      debugPrint('📣 [WifiDirect] peer_announce: $deviceName ($deviceId) at $ip');
      // Connect directly to the new peer's TCP server
      _connectClientSocket(ip);
    }
  }

  // -----------------------------------------------------------
  // _announcePeerToNeighbors()
  // Called by the server-side after a new client completes handshake.
  // Tells ALL existing neighbors about the new peer so they can
  // open direct TCP sockets to it — creating a full mesh.
  // -----------------------------------------------------------
  void _announcePeerToNeighbors(ConnectedDevice newPeer) {
    final announcement = jsonEncode({
      'type': 'system',
      'action': 'peer_announce',
      'deviceId': newPeer.deviceId,
      'deviceName': newPeer.deviceName,
      'ip': newPeer.ipAddress ?? newPeer.address,
    });
    // Send to all neighbors EXCEPT the newly joined peer
    socketManager.broadcastExcept(announcement, newPeer.deviceId);
    debugPrint('📣 [WifiDirect] Announced ${newPeer.deviceName} to '
        '${socketManager.neighborCount - 1} existing neighbor(s)');
  }

  // -----------------------------------------------------------
  // _performHandshake()
  void _performHandshake(Socket socket, {bool isServerSide = false}) {
    // Step 1: Send our identity immediately
    final myIdentity = jsonEncode({
      'deviceId': myDeviceId,
      'deviceName': myDeviceName,
      'type': 'handshake',
    });
    try {
      socket.write('$myIdentity\n');
    } catch (e) {
      debugPrint('❌ [WifiDirect] Failed to send handshake: $e');
      socket.destroy();
      return;
    }

    // Step 2: Listen to raw bytes ONCE.
    // We parse the first line as handshake. After handshake,
    // remaining bytes are forwarded to SocketManager.
    final lineBuffer = StringBuffer();
    bool handshakeDone = false;
    String? remoteDeviceId;

    // Create a StreamController to pass post-handshake bytes to SocketManager
    final dataController = StreamController<List<int>>();

    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (List<int> data) {
        if (!handshakeDone) {
          // We're still looking for the first '\n' (the handshake line)
          lineBuffer.write(utf8.decode(data, allowMalformed: true));
          final buffered = lineBuffer.toString();
          final newlineIdx = buffered.indexOf('\n');

          if (newlineIdx >= 0) {
            // Found the end of the handshake line
            final firstLine = buffered.substring(0, newlineIdx).trim();
            final remainder = buffered.substring(newlineIdx + 1);
            lineBuffer.clear();

            try {
              final identity = jsonDecode(firstLine) as Map<String, dynamic>;
              if (identity['type'] == 'handshake') {
                remoteDeviceId = identity['deviceId'] as String? ?? 'unknown';
                final remoteName = identity['deviceName'] as String? ?? 'Unknown';

                final device = ConnectedDevice(
                  deviceId: remoteDeviceId!,
                  deviceName: remoteName,
                  address: socket.remoteAddress.address,
                  ipAddress: socket.remoteAddress.address,
                );

                debugPrint('🤝 [WifiDirect] Handshake OK: $remoteName ($remoteDeviceId)');
                handshakeDone = true;

                // Step 3: Hand the socket + its future data stream to SocketManager.
                // We pass the StreamController's stream so SocketManager can subscribe.
                socketManager.addConnectionWithStream(
                  device,
                  socket,
                  dataController.stream,
                  onClose: () {
                    sub.cancel();
                    dataController.close();
                  },
                );
                onPeerConnected?.call(device);

                // Server-side: announce new peer to all existing neighbors
                // so they can open a direct TCP socket to this peer.
                if (isServerSide) {
                  _announcePeerToNeighbors(device);
                }

                // If there were bytes after the handshake line, forward them now
                if (remainder.isNotEmpty) {
                  dataController.add(utf8.encode(remainder));
                }
              } else {
                debugPrint('❌ [WifiDirect] Bad handshake type: ${identity['type']}');
                socket.destroy();
                dataController.close();
              }
            } catch (e) {
              debugPrint('❌ [WifiDirect] Handshake parse failed: $e | line: "$firstLine"');
              socket.destroy();
              dataController.close();
            }
          }
        } else {
          // Handshake done — forward all data to SocketManager's stream
          dataController.add(data);
        }
      },
      onError: (error) {
        debugPrint('❌ [WifiDirect] Socket error: $error');
        if (remoteDeviceId != null) {
          socketManager.removeConnection(remoteDeviceId!);
          onPeerDisconnected?.call(remoteDeviceId!);
        }
        dataController.close();
      },
      onDone: () {
        debugPrint('🔌 [WifiDirect] Socket closed by remote');
        if (remoteDeviceId != null) {
          socketManager.removeConnection(remoteDeviceId!);
          onPeerDisconnected?.call(remoteDeviceId!);
        }
        dataController.close();
      },
      cancelOnError: true,
    );
  }

  // -----------------------------------------------------------
  // _stopServerSocket()
  // -----------------------------------------------------------
  void _stopServerSocket() {
    try {
      _serverSocket?.close();
    } catch (_) {}
    _serverSocket = null;
    _serverRunning = false;
    // NOTE: Do NOT call socketManager.dispose() here.
    // The SocketManager is shared with MeshRouter and may still have
    // active peer connections from other sources. We only stop OUR
    // server-side socket here; SocketManager cleans itself up via
    // its own removeConnection() callbacks.
    debugPrint('🧹 [WifiDirect] Server socket stopped');
  }

  // -----------------------------------------------------------
  // Listener setters
  // -----------------------------------------------------------
  void setDeviceListener(
      Function(List<Map<String, dynamic>> devices) callback) {
    onDevicesFound = callback;
  }

  void setConnectionListener(
      Function(Map<String, dynamic> connectionInfo) callback) {
    onConnectionChanged = callback;
  }

  void setPeerConnectedCallback(PeerConnectedCallback callback) {
    onPeerConnected = callback;
  }

  void dispose() {
    _groupDisbandTimer?.cancel();
    _stopRescanTimer();
    _stopServerSocket();
  }
}