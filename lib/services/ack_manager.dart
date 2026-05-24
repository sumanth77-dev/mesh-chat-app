// ============================================================
// FILE: lib/services/ack_manager.dart
// PURPOSE: Generate and process ACK packets.
//
// ACK flow:
//   1. Receiver gets a message → _deliverToSelf() calls sendAck()
//   2. ACK is sent as a system message back through the mesh
//   3. Original sender intercepts ACK via onSystemMessage
//   4. PacketQueueService.markDelivered() removes the packet
//
// ACK wire format (JSON system message):
//   { "type": "system", "action": "ack", "packetId": "...",
//     "senderId": "...", "receiverId": "..." }
// ============================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'socket_manager.dart';
import 'packet_queue_service.dart';

class AckManager {
  final SocketManager socketManager;
  final PacketQueueService packetQueue;
  final String myDeviceId;

  AckManager({
    required this.socketManager,
    required this.packetQueue,
    required this.myDeviceId,
  });

  // -----------------------------------------------------------
  // sendAck()
  // Called by MeshRouter._deliverToSelf() after a message is
  // successfully decrypted and delivered to this device.
  //
  // The ACK is sent as a system message so it bypasses MeshRouter
  // and is handled by onSystemMessage in SocketManager.
  // -----------------------------------------------------------
  void sendAck({
    required String packetId,
    required String originalSenderId,
  }) {
    final ack = jsonEncode({
      'type': 'system',
      'action': 'ack',
      'packetId': packetId,
      'senderId': originalSenderId,  // who sent the original message
      'ackBy': myDeviceId,           // who is confirming delivery
    });

    // Broadcast — the ACK will reach the original sender through
    // any currently connected neighbor.
    socketManager.broadcast(ack);
    debugPrint('📬 [AckManager] Sent ACK for packet $packetId '
        'to original sender $originalSenderId');
  }

  // -----------------------------------------------------------
  // handleIncomingAck()
  // Called when a system message with action="ack" arrives.
  // If the ack is for a packet WE sent, remove it from the queue.
  // -----------------------------------------------------------
  Future<void> handleIncomingAck(Map<String, dynamic> ackMap) async {
    final packetId = ackMap['packetId'] as String?;
    final originalSender = ackMap['senderId'] as String?;

    if (packetId == null || originalSender == null) {
      debugPrint('⚠️ [AckManager] Malformed ACK received');
      return;
    }

    // Only process ACKs for packets WE sent
    if (originalSender != myDeviceId) {
      debugPrint('🔀 [AckManager] ACK for $packetId is not for us — ignoring');
      return;
    }

    debugPrint('✅ [AckManager] ACK received for packet $packetId — removing from queue');
    await packetQueue.markDelivered(packetId);
  }
}
