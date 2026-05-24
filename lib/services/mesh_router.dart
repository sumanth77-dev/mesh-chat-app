// ============================================================
// FILE: lib/services/mesh_router.dart
// PURPOSE: The brain of the mesh network — routing logic.
//
// WHAT HAPPENS WHEN A MESSAGE ARRIVES:
//
//   Step 1: Parse the raw JSON into a MeshMessage.
//   Step 2: Check if we have SEEN this message ID before.
//           → If yes: IGNORE IT (duplicate prevention).
//   Step 3: Mark the message ID as SEEN in memory + Hive.
//   Step 4: Check if receiverId == myDeviceId
//           → If YES: Decrypt + display the message. We are done.
//           → If NO:  This device is a relay node. Forward it.
//   Step 5 (Forwarding):
//           - Decrement TTL.
//           - If TTL <= 0: Drop the message (loop prevention).
//           - Increment hopCount.
//           - Broadcast to all neighbors EXCEPT the one who sent it.
//
// IMPORTANT:
//   Relay nodes do NOT decrypt or display the message content.
//   Only the intended receiver decrypts and shows the message.
//
// HOW TTL PREVENTS INFINITE LOOPS:
//   Each hop decrements TTL. If network has a cycle (A→B→C→A)
//   the message is eventually dropped when TTL reaches 0.
// ============================================================

import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../models/pending_packet.dart';
import 'socket_manager.dart';
import 'encryption_service.dart';
import 'database_service.dart';
import 'packet_queue_service.dart';
import 'ack_manager.dart';

/// Called when a message INTENDED FOR THIS DEVICE arrives.
typedef IncomingMessageCallback = void Function(MeshMessage message);

/// Called to show a local notification for an incoming message.
/// Parameters: senderId, senderName (may be empty), decrypted content.
typedef NotifyMessageCallback = void Function(
    String senderId, String senderName, String content);

class MeshRouter {
  // ── Dependencies ───────────────────────────────────────────
  final SocketManager socketManager;
  final EncryptionService encryption;
  final DatabaseService database;

  // ── This device's identity ─────────────────────────────────
  /// The unique ID of THIS device in the mesh.
  String myDeviceId;

  /// Human-readable name of this device (shown in relay info).
  String myDeviceName;

  // ── In-memory dedup set ────────────────────────────────────
  /// Fast in-memory lookup for seen message IDs.
  /// Checked BEFORE hitting Hive for maximum speed.
  final Set<String> _seenMessageIds = {};

  // ── Callbacks ──────────────────────────────────────────────
  /// Called when a message addressed to THIS device arrives (after decrypt).
  IncomingMessageCallback? onMessageForMe;

  /// Called to trigger a local notification for the incoming message.
  /// Set in main.dart. Null-safe — no notification shown if not wired up.
  NotifyMessageCallback? onNotifyMessage;

  // ── Store-and-Forward (optional, set in main.dart) ─────────
  /// Handles queuing outgoing packets and removing them on ACK.
  PacketQueueService? packetQueue;

  /// Sends ACKs when messages arrive and processes incoming ACKs.
  AckManager? ackManager;

  MeshRouter({
    required this.socketManager,
    required this.encryption,
    required this.database,
    required this.myDeviceId,
    required this.myDeviceName,
  }) {
    // Tell SocketManager to call _handleRawMessage() for every incoming line
    socketManager.onMessageReceived = _handleRawMessage;

    // Pre-load seen IDs from Hive so we survive app restarts
    _restoreSeenIds();
  }

  // -----------------------------------------------------------
  // _restoreSeenIds()
  // Load persisted seen message IDs from Hive into the fast Set.
  // This prevents re-processing messages after an app restart.
  // -----------------------------------------------------------
  void _restoreSeenIds() {
    try {
      // DatabaseService exposes getSeenIds() for this purpose
      final ids = database.getAllSeenIds();
      _seenMessageIds.addAll(ids);
      debugPrint('📋 [MeshRouter] Restored ${_seenMessageIds.length} seen IDs');
    } catch (e) {
      debugPrint('⚠️ [MeshRouter] Could not restore seen IDs: $e');
    }
  }

  // -----------------------------------------------------------
  // sendMessage()
  // PUBLIC API — called by ChatScreen when user taps Send.
  //
  // Steps:
  //   1. Encrypt the plain text content.
  //   2. Build a MeshMessage with sender=me, receiver=target.
  //   3. Mark as seen immediately (ignore any echo of our own msg).
  //   4. Save the plain-text copy to Hive for our chat history.
  //   5. Broadcast the ENCRYPTED packet to all neighbors.
  // -----------------------------------------------------------
  Future<void> sendMessage({
    required String content,
    required String receiverId,
    int ttl = 5,
  }) async {
    // Step 1: Encrypt
    final encryptedContent = encryption.encryptMessage(content);

    // Step 2: Build the packet
    final msg = MeshMessage(
      senderId: myDeviceId,
      receiverId: receiverId,
      content: encryptedContent,
      ttl: ttl,
      hopCount: 0,
      isEncrypted: true,
    );

    debugPrint('📤 [MeshRouter] Sending: ${msg.id} to $receiverId ttl:$ttl');

    // Step 3: Mark our own message as seen so we ignore any echo
    _markSeen(msg.id);

    // Step 4: Save our sent message with PLAIN text for our UI
    await database.saveMessage(
      ChatMessage(text: content, isMe: true, timestamp: msg.timestamp),
    );

    // Step 5: Broadcast encrypted packet
    final json = jsonEncode(msg.toMap());
    socketManager.broadcast(json);

    // Step 6 (Store-and-Forward): Queue the packet so we can
    // retry if the receiver was offline and no ACK arrives.
    if (packetQueue != null) {
      final packet = PendingPacket(
        packetId: msg.id,
        receiverId: receiverId,
        encryptedPayload: json,
        timestamp: msg.timestamp,
        ttl: ttl,
      );
      await packetQueue!.addPendingPacket(packet);
    }
  }

  // -----------------------------------------------------------
  // _handleRawMessage()
  // Called by SocketManager for EVERY incoming JSON line.
  // This is the CORE ROUTING LOGIC.
  // -----------------------------------------------------------
  void _handleRawMessage(String rawJson, String fromDeviceId) {
    MeshMessage msg;

    // ── Parse ───────────────────────────────────────────────
    try {
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      msg = MeshMessage.fromMap(map);
    } catch (e) {
      debugPrint('❌ [MeshRouter] Parse error: $e  raw: $rawJson');
      return;
    }

    debugPrint(
      '📨 [MeshRouter] Got ${msg.id} '
      'sender:${msg.senderId} receiver:${msg.receiverId} '
      'ttl:${msg.ttl} hops:${msg.hopCount}',
    );

    // ── Step 2: Duplicate check ──────────────────────────────
    if (_isDuplicate(msg.id)) {
      debugPrint('🔁 [MeshRouter] DUPLICATE ignored: ${msg.id}');
      return;
    }

    // ── Step 3: Mark as seen ─────────────────────────────────
    _markSeen(msg.id);

    // ── Step 4: Is this message for ME? ─────────────────────
    if (msg.receiverId == myDeviceId) {
      _deliverToSelf(msg);
      return; // STOP — never forward messages meant for this device
    }

    // ── Step 5: I am a relay node ────────────────────────────
    _forwardMessage(msg, fromDeviceId);
  }

  // -----------------------------------------------------------
  // _deliverToSelf()
  // The message is for THIS device. Decrypt and deliver to UI.
  // Intermediate nodes NEVER call this method.
  // -----------------------------------------------------------
  void _deliverToSelf(MeshMessage msg) {
    debugPrint('🎯 [MeshRouter] Delivering to self — sender: ${msg.senderId}');

    // Decrypt
    final plainText = msg.isEncrypted
        ? encryption.decryptMessage(msg.content)
        : msg.content;

    // Build relay label (e.g. "2 hops" or "Relayed via B")
    final relayInfo = msg.hopCount > 0
        ? '${msg.hopCount} hop${msg.hopCount > 1 ? 's' : ''}'
        : null;

    // Create the decrypted version for UI and storage
    final decryptedMsg = MeshMessage(
      id: msg.id,
      senderId: msg.senderId,
      receiverId: msg.receiverId,
      content: plainText,
      timestamp: msg.timestamp,
      ttl: msg.ttl,
      hopCount: msg.hopCount,
      isEncrypted: false,
      relayedBy: relayInfo,
    );

    // Persist to Hive (chat history)
    database.saveMessage(
      ChatMessage.fromMesh(decryptedMsg, isMe: false),
    );

    // Notify the UI — ChatScreen is listening
    onMessageForMe?.call(decryptedMsg);

    // Show local notification — works even when app is minimized.
    final senderDevice = socketManager.connectedDevices
        .where((d) => d.deviceId == msg.senderId)
        .firstOrNull;
    final senderName = senderDevice?.deviceName ?? '';
    onNotifyMessage?.call(msg.senderId, senderName, plainText);

    // Send ACK back to original sender so they can clear the packet
    // from their store-and-forward queue.
    ackManager?.sendAck(
      packetId: msg.id,
      originalSenderId: msg.senderId,
    );

    debugPrint('✅ [MeshRouter] Delivered "$plainText" (${msg.hopCount} hops)');
  }

  // -----------------------------------------------------------
  // _forwardMessage()
  // THIS device is an intermediate relay node (e.g. B in A→B→C).
  // We do NOT decrypt — just modify TTL/hopCount and forward.
  // -----------------------------------------------------------
  void _forwardMessage(MeshMessage msg, String fromDeviceId) {
    // TTL check — prevents infinite loops in mesh cycles
    if (msg.ttl <= 0) {
      debugPrint('⛔ [MeshRouter] TTL expired — dropping ${msg.id}');
      return;
    }

    // Build the forwarded packet: TTL-1, hopCount+1, relayedBy=us
    final forwarded = msg.copyWith(
      ttl: msg.ttl - 1,
      hopCount: msg.hopCount + 1,
      relayedBy: myDeviceName,
    );

    debugPrint(
      '🔀 [MeshRouter] Forwarding ${forwarded.id} '
      'ttl:${forwarded.ttl} hops:${forwarded.hopCount} '
      'excluding sender:$fromDeviceId',
    );

    final json = jsonEncode(forwarded.toMap());

    // Broadcast to all neighbors EXCEPT the one who sent this to us.
    // This prevents the packet from bouncing straight back.
    socketManager.broadcastExcept(json, fromDeviceId);
  }

  // -----------------------------------------------------------
  // Dedup helpers (in-memory Set + Hive)
  // -----------------------------------------------------------

  bool _isDuplicate(String messageId) =>
      _seenMessageIds.contains(messageId) || database.isMessageSeen(messageId);

  void _markSeen(String messageId) {
    _seenMessageIds.add(messageId);       // in-memory: instant
    database.markMessageSeen(messageId);  // Hive: survives restart
  }

  // -----------------------------------------------------------
  // updateIdentity() — change this device's mesh ID at runtime
  // -----------------------------------------------------------
  void updateIdentity(String id, String name) {
    myDeviceId = id;
    myDeviceName = name;
    socketManager.myDeviceId = id;
    debugPrint('🪪 [MeshRouter] Identity: $name ($id)');
  }

  void dispose() {
    socketManager.dispose();
  }
}
