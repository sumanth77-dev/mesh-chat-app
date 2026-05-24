// ============================================================
// FILE: lib/services/socket_manager.dart
//
// KEY CHANGE: addConnection() replaced by addConnectionWithStream()
//
// WHY: The old addConnection(device, socket) called socket.listen()
// internally. But WifiDirectService had already called socket.listen()
// for the handshake. You can't call listen() twice on a Dart stream —
// the second call was silently ignored.
//
// FIX: WifiDirectService now owns the single socket.listen() call and
// forwards data via a StreamController. SocketManager receives that
// Stream (not the socket) and subscribes to it. The raw socket is
// still stored so we can write to it (write() is fine from anywhere).
// ============================================================

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/connected_device.dart';

/// Called whenever a complete JSON line arrives on any socket.
typedef MessageHandler = void Function(String rawJson, String fromDeviceId);

/// Called for internal mesh system messages (peer_announce, etc.).
/// These are intercepted BEFORE reaching MeshRouter.
typedef SystemMessageHandler = void Function(
    Map<String, dynamic> msg, String fromDeviceId);

class SocketManager {
  // ── State ──────────────────────────────────────────────────
  /// Write-side sockets (for sending data to peers).
  final Map<String, Socket> _sockets = {};

  /// Metadata for each connected device.
  final Map<String, ConnectedDevice> _devices = {};

  /// Active stream subscriptions (one per peer, for cleanup).
  final Map<String, StreamSubscription<List<int>>> _subscriptions = {};

  /// Cleanup callbacks from WifiDirectService (to cancel the listen).
  final Map<String, VoidCallback> _closeCallbacks = {};

  /// Our own device ID.
  String myDeviceId = '';

  /// Called whenever any socket receives a complete user/mesh message line.
  MessageHandler? onMessageReceived;

  /// Called for internal system messages (peer_announce, etc.).
  /// Handled in WifiDirectService, NOT passed to MeshRouter.
  SystemMessageHandler? onSystemMessage;

  /// Called when an ACK system message arrives.
  /// Wired to AckManager.handleIncomingAck() in main.dart.
  Future<void> Function(Map<String, dynamic>)? onAckReceived;

  /// Called when a new peer is successfully added.
  /// Wired to RetryService.onPeerReconnected() in main.dart.
  void Function(String deviceId)? onPeerConnected;

  // -----------------------------------------------------------
  // addConnectionWithStream()
  //
  // Register a peer. The caller (WifiDirectService) provides:
  //   - device:    metadata (name, ID, IP)
  //   - socket:    used ONLY for writing (send side)
  //   - stream:    pre-subscribed stream for reading (receive side)
  //   - onClose:  callback to cancel the upstream listener
  // -----------------------------------------------------------
  void addConnectionWithStream(
    ConnectedDevice device,
    Socket socket,
    Stream<List<int>> stream, {
    VoidCallback? onClose,
  }) {
    final id = device.deviceId;

    // Clean up any previous connection for this device
    _closeExisting(id);

    _sockets[id] = socket;
    _devices[id] = device;
    if (onClose != null) _closeCallbacks[id] = onClose;

    debugPrint('🔗 [SocketManager] Connected: ${device.deviceName} ($id)');
    debugPrint('   Total neighbors: ${_sockets.length}');

    // Notify RetryService so it can flush queued packets for this peer
    onPeerConnected?.call(id);

    // Subscribe to the data stream (this is the ONLY subscription)
    final lineBuffer = StringBuffer();
    final sub = stream.listen(
      (List<int> data) {
        final chunk = utf8.decode(data, allowMalformed: true);
        lineBuffer.write(chunk);
        final fullBuffer = lineBuffer.toString();
        final lines = fullBuffer.split('\n');

        // Process all complete lines
        for (int i = 0; i < lines.length - 1; i++) {
          final line = lines[i].trim();
          if (line.isNotEmpty) {
            // Intercept system messages before they reach MeshRouter
            bool isSystem = false;
            if (line.startsWith('{')) {
              try {
                final decoded = jsonDecode(line);
                if (decoded is Map && decoded['type'] == 'system') {
                  final action = decoded['action'] as String? ?? '';
                  if (action == 'ack') {
                    // ACK packet — hand to AckManager
                    onAckReceived?.call(Map<String, dynamic>.from(decoded));
                  } else {
                    // Other system messages (peer_announce, etc.)
                    onSystemMessage?.call(
                        Map<String, dynamic>.from(decoded), id);
                  }
                  isSystem = true;
                }
              } catch (_) {}
            }
            if (!isSystem) {
              debugPrint('📥 [SocketManager] From $id: $line');
              onMessageReceived?.call(line, id);
            }
          }
        }

        // Keep the trailing partial fragment
        lineBuffer.clear();
        lineBuffer.write(lines.last);
      },
      onError: (error) {
        debugPrint('❌ [SocketManager] Stream error from $id: $error');
        removeConnection(id);
      },
      onDone: () {
        debugPrint('🔌 [SocketManager] Stream closed from $id');
        removeConnection(id);
      },
      cancelOnError: true,
    );

    _subscriptions[id] = sub;
  }

  // -----------------------------------------------------------
  // _closeExisting() — internal cleanup for one peer
  // -----------------------------------------------------------
  void _closeExisting(String deviceId) {
    _subscriptions[deviceId]?.cancel();
    _subscriptions.remove(deviceId);
    _closeCallbacks[deviceId]?.call();
    _closeCallbacks.remove(deviceId);
    try { _sockets[deviceId]?.destroy(); } catch (_) {}
    _sockets.remove(deviceId);
    _devices.remove(deviceId);
  }

  // -----------------------------------------------------------
  // removeConnection() — called when a peer disconnects
  // -----------------------------------------------------------
  void removeConnection(String deviceId) {
    _closeExisting(deviceId);
    debugPrint('❌ [SocketManager] Removed: $deviceId | Remaining: ${_sockets.length}');
  }

  // -----------------------------------------------------------
  // sendToDevice() — unicast to one peer
  // -----------------------------------------------------------
  bool sendToDevice(String deviceId, String json) {
    final socket = _sockets[deviceId];
    if (socket == null) {
      debugPrint('⚠️ [SocketManager] No socket for: $deviceId');
      return false;
    }
    return _write(socket, json, deviceId);
  }

  // -----------------------------------------------------------
  // broadcast() — send to all peers
  // -----------------------------------------------------------
  void broadcast(String json) {
    if (_sockets.isEmpty) {
      debugPrint('⚠️ [SocketManager] broadcast() — no neighbors');
      return;
    }
    for (final entry in _sockets.entries) {
      _write(entry.value, json, entry.key);
    }
  }

  // -----------------------------------------------------------
  // broadcastExcept() — send to all except one (avoid loops)
  // -----------------------------------------------------------
  void broadcastExcept(String json, String excludeDeviceId) {
    for (final entry in _sockets.entries) {
      if (entry.key != excludeDeviceId) {
        _write(entry.value, json, entry.key);
      }
    }
  }

  // -----------------------------------------------------------
  // _write() — low-level write with newline framing
  // -----------------------------------------------------------
  bool _write(Socket socket, String json, String deviceId) {
    try {
      socket.write('$json\n');
      return true;
    } catch (e) {
      debugPrint('❌ [SocketManager] Write failed to $deviceId: $e');
      removeConnection(deviceId);
      return false;
    }
  }

  // -----------------------------------------------------------
  // Getters
  // -----------------------------------------------------------
  List<String> get connectedDeviceIds => _sockets.keys.toList();
  List<ConnectedDevice> get connectedDevices => _devices.values.toList();
  int get neighborCount => _sockets.length;
  bool get hasNeighbors => _sockets.isNotEmpty;
  ConnectedDevice? getDevice(String deviceId) => _devices[deviceId];

  // -----------------------------------------------------------
  // dispose() — close everything
  // -----------------------------------------------------------
  void dispose() {
    final ids = _sockets.keys.toList();
    for (final id in ids) {
      _closeExisting(id);
    }
    debugPrint('🧹 [SocketManager] All connections closed');
  }
}
