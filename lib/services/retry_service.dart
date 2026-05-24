// ============================================================
// FILE: lib/services/retry_service.dart
// PURPOSE: Periodically retry undelivered pending packets.
//
// Two triggers for retry:
//   1. Periodic timer (every 30 seconds) — background polling
//   2. Peer reconnect event — immediate flush for that peer
//
// Retry logic:
//   - Load all undelivered packets from PacketQueueService
//   - For each packet, check if receiver is currently connected
//   - If connected: resend the encrypted payload via broadcast
//   - Increment retry counter; PacketQueueService drops after maxRetries
// ============================================================

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'socket_manager.dart';
import 'packet_queue_service.dart';

class RetryService {
  final SocketManager socketManager;
  final PacketQueueService packetQueue;

  /// How often to check for packets to retry.
  static const Duration _retryInterval = Duration(seconds: 30);

  Timer? _timer;

  RetryService({
    required this.socketManager,
    required this.packetQueue,
  });

  // -----------------------------------------------------------
  // start()
  // Begin periodic retry timer. Call once in main().
  // -----------------------------------------------------------
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_retryInterval, (_) => _retryAll());
    debugPrint('🔁 [RetryService] Started — interval: ${_retryInterval.inSeconds}s');
  }

  // -----------------------------------------------------------
  // stop()
  // Cancel the retry timer (call on app dispose).
  // -----------------------------------------------------------
  void stop() {
    _timer?.cancel();
    _timer = null;
    debugPrint('🛑 [RetryService] Stopped');
  }

  // -----------------------------------------------------------
  // onPeerReconnected()
  // Called by WifiDirectService/SocketManager when a peer comes
  // back online. Immediately flush any queued packets for them.
  // -----------------------------------------------------------
  void onPeerReconnected(String reconnectedDeviceId) {
    debugPrint('👋 [RetryService] Peer reconnected: $reconnectedDeviceId '
        '— flushing queued packets');
    _retryForReceiver(reconnectedDeviceId);
  }

  // -----------------------------------------------------------
  // _retryAll()
  // Retry all pending packets whose receiver is now online.
  // -----------------------------------------------------------
  Future<void> _retryAll() async {
    final pending = packetQueue.getPendingPackets();
    if (pending.isEmpty) return;

    debugPrint('🔁 [RetryService] Checking ${pending.length} pending packets...');

    for (final packet in pending) {
      final receiverOnline = socketManager.connectedDeviceIds
          .contains(packet.receiverId);

      if (receiverOnline) {
        _resendPacket(packet.packetId, packet.encryptedPayload, packet.receiverId);
      } else {
        debugPrint('⏳ [RetryService] Receiver ${packet.receiverId} offline '
            '— keeping packet ${packet.packetId} in queue');
      }
    }
  }

  // -----------------------------------------------------------
  // _retryForReceiver()
  // Retry only packets destined for one specific receiver.
  // -----------------------------------------------------------
  Future<void> _retryForReceiver(String receiverId) async {
    final packets = packetQueue.getPendingPacketsForReceiver(receiverId);
    if (packets.isEmpty) {
      debugPrint('📭 [RetryService] No queued packets for $receiverId');
      return;
    }

    debugPrint('📨 [RetryService] Flushing ${packets.length} packet(s) '
        'for $receiverId');

    for (final packet in packets) {
      _resendPacket(packet.packetId, packet.encryptedPayload, packet.receiverId);
    }
  }

  // -----------------------------------------------------------
  // _resendPacket()
  // Broadcast the stored encrypted payload and increment retry count.
  // -----------------------------------------------------------
  Future<void> _resendPacket(
      String packetId, String encryptedPayload, String receiverId) async {
    debugPrint('📤 [RetryService] Retrying packet $packetId → $receiverId');

    // Broadcast — routing table will get it to the right node
    socketManager.broadcast(encryptedPayload);

    // Bump retry counter (PacketQueueService drops at maxRetries)
    await packetQueue.incrementRetry(packetId);
  }
}
