// ============================================================
// FILE: lib/services/packet_queue_service.dart
// PURPOSE: Hive-backed persistent storage for pending packets.
//
// Lifecycle of a packet:
//   addPendingPacket()   → stored when send attempt cannot confirm delivery
//   incrementRetry()     → called by RetryService on each resend attempt
//   markDelivered()      → called by AckManager when ACK arrives
//   removePacket()       → cleans up delivered or expired packets
// ============================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/pending_packet.dart';

class PacketQueueService {
  // Singleton
  static final PacketQueueService _instance = PacketQueueService._internal();
  factory PacketQueueService() => _instance;
  PacketQueueService._internal();

  static const String _boxName = 'pending_packets';

  // Maximum number of retries before giving up
  static const int maxRetries = 10;

  /// Open the Hive box. Call once in main() during initialization.
  static Future<void> initialize() async {
    await Hive.openBox<String>(_boxName);
    debugPrint('📦 [PacketQueue] Initialized — '
        '${Hive.box<String>(_boxName).length} pending packets');
  }

  Box<String> get _box => Hive.box<String>(_boxName);

  // -----------------------------------------------------------
  // addPendingPacket()
  // Store a new packet. Uses packetId as the Hive key.
  // -----------------------------------------------------------
  Future<void> addPendingPacket(PendingPacket packet) async {
    final json = jsonEncode(packet.toMap());
    await _box.put(packet.packetId, json);
    debugPrint('📦 [PacketQueue] Stored packet ${packet.packetId} '
        'for receiver ${packet.receiverId}');
  }

  // -----------------------------------------------------------
  // removePacket()
  // Delete a packet (after delivery or expiry).
  // -----------------------------------------------------------
  Future<void> removePacket(String packetId) async {
    await _box.delete(packetId);
    debugPrint('🗑️ [PacketQueue] Removed packet $packetId');
  }

  // -----------------------------------------------------------
  // getPendingPackets()
  // Returns all undelivered packets, sorted oldest-first.
  // -----------------------------------------------------------
  List<PendingPacket> getPendingPackets() {
    final packets = <PendingPacket>[];
    for (final key in _box.keys) {
      final raw = _box.get(key as String);
      if (raw == null) continue;
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final p = PendingPacket.fromMap(map);
        if (!p.delivered) packets.add(p);
      } catch (e) {
        debugPrint('⚠️ [PacketQueue] Parse error for key $key: $e');
      }
    }
    packets.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return packets;
  }

  // -----------------------------------------------------------
  // getPendingPacketsForReceiver()
  // Returns all pending packets for a specific receiver.
  // Called when that peer reconnects.
  // -----------------------------------------------------------
  List<PendingPacket> getPendingPacketsForReceiver(String receiverId) =>
      getPendingPackets().where((p) => p.receiverId == receiverId).toList();

  // -----------------------------------------------------------
  // markDelivered()
  // Mark packet as delivered and clean it up.
  // -----------------------------------------------------------
  Future<void> markDelivered(String packetId) async {
    final raw = _box.get(packetId);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final p = PendingPacket.fromMap(map);
      p.delivered = true;
      await _box.put(packetId, jsonEncode(p.toMap()));
      // Clean up immediately
      await removePacket(packetId);
      debugPrint('✅ [PacketQueue] Packet $packetId marked delivered & removed');
    } catch (e) {
      debugPrint('⚠️ [PacketQueue] markDelivered error: $e');
    }
  }

  // -----------------------------------------------------------
  // incrementRetry()
  // Bump the retry counter and record lastRetryTime.
  // If maxRetries exceeded, remove the packet.
  // -----------------------------------------------------------
  Future<void> incrementRetry(String packetId) async {
    final raw = _box.get(packetId);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final p = PendingPacket.fromMap(map);
      p.retryCount++;
      p.lastRetryTime = DateTime.now();

      if (p.retryCount >= maxRetries) {
        debugPrint('⛔ [PacketQueue] Max retries reached for ${p.packetId} '
            '— giving up');
        await removePacket(packetId);
      } else {
        await _box.put(packetId, jsonEncode(p.toMap()));
        debugPrint('🔁 [PacketQueue] Retry count for $packetId: ${p.retryCount}');
      }
    } catch (e) {
      debugPrint('⚠️ [PacketQueue] incrementRetry error: $e');
    }
  }

  /// Total number of pending (undelivered) packets.
  int get pendingCount => getPendingPackets().length;
}
