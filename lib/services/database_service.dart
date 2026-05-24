// ============================================================
// FILE: lib/services/database_service.dart
// PURPOSE: All Hive persistence for the mesh app.
//
// WHAT WE STORE:
//   - 'messages'   box → received chat messages (ChatMessage maps)
//   - 'seen_ids'   box → message IDs we have already processed
//                         (prevents duplicate forwarding loops)
//   - 'peers'      box → previously connected devices
//
// HOW IT IS USED:
//   MeshRouter calls this service to:
//     1. Check if a message ID was already seen.
//     2. Mark a message ID as seen.
//     3. Save a message for display.
//   ChatScreen calls this to load chat history.
// ============================================================

import 'package:hive_flutter/hive_flutter.dart';
import '../models/message.dart';
import '../models/connected_device.dart';

class DatabaseService {
  // Hive box names — don't change these after first run!
  static const String _messagesBox = 'messages';
  static const String _seenIdsBox  = 'seen_ids';
  static const String _peersBox    = 'peers';

  // Singleton pattern so only one instance exists in the app
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  // -----------------------------------------------------------
  // INIT: Must be called once before using this service.
  //       Called from main.dart.
  // -----------------------------------------------------------
  static Future<void> initialize() async {
    await Hive.initFlutter();
    await Hive.openBox(_messagesBox);
    await Hive.openBox(_seenIdsBox);
    await Hive.openBox(_peersBox);
  }

  // -----------------------------------------------------------
  // MESSAGES — store and load chat messages for display
  // -----------------------------------------------------------

  /// Save a ChatMessage to Hive (for chat history).
  Future<void> saveMessage(ChatMessage msg) async {
    final box = Hive.box(_messagesBox);
    await box.add(msg.toMap());
  }

  /// Save a MeshMessage as a ChatMessage for the local peer (senderId).
  Future<void> saveMeshMessage(MeshMessage msg, {required bool isMe}) async {
    final chatMsg = ChatMessage.fromMesh(msg, isMe: isMe);
    await saveMessage(chatMsg);
  }

  /// Load all stored messages, sorted oldest-first.
  List<ChatMessage> loadMessages() {
    final box = Hive.box(_messagesBox);
    final stored = box.values.toList();
    final messages = stored
        .whereType<Map>()
        .map((m) => ChatMessage.fromMap(m))
        .toList();
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return messages;
  }

  /// Clear all stored chat messages (e.g. user taps "Clear History").
  Future<void> clearMessages() async {
    await Hive.box(_messagesBox).clear();
  }

  // -----------------------------------------------------------
  // SEEN MESSAGE IDs — duplicate loop prevention
  // -----------------------------------------------------------

  /// Returns true if this message ID has already been processed.
  /// This is how we prevent forwarding the same packet twice.
  bool isMessageSeen(String messageId) {
    final box = Hive.box(_seenIdsBox);
    return box.containsKey(messageId);
  }

  /// Mark a message ID as seen so we don't forward it again.
  Future<void> markMessageSeen(String messageId) async {
    final box = Hive.box(_seenIdsBox);
    // Store the timestamp so we could prune old entries later
    await box.put(messageId, DateTime.now().millisecondsSinceEpoch);
  }

  /// Return all stored seen message IDs (used by MeshRouter on startup).
  List<String> getAllSeenIds() {
    final box = Hive.box(_seenIdsBox);
    return box.keys.map((k) => k.toString()).toList();
  }

  /// Prune seen IDs older than [maxAge] to prevent unbounded growth.
  /// Call this periodically (e.g. once per hour).
  Future<void> pruneSeenIds({Duration maxAge = const Duration(hours: 24)}) async {
    final box = Hive.box(_seenIdsBox);
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final keysToDelete = box.keys.where((k) {
      final ts = box.get(k) as int? ?? 0;
      return ts < cutoff;
    }).toList();
    await box.deleteAll(keysToDelete);
  }

  // -----------------------------------------------------------
  // PEERS — remember connected devices across sessions
  // -----------------------------------------------------------

  /// Save a connected device to persistent storage.
  Future<void> savePeer(ConnectedDevice device) async {
    final box = Hive.box(_peersBox);
    // Use deviceId as the key so updates overwrite old entries
    await box.put(device.deviceId, device.toMap());
  }

  /// Load all previously known peers.
  List<ConnectedDevice> loadPeers() {
    final box = Hive.box(_peersBox);
    return box.values
        .whereType<Map>()
        .map((m) => ConnectedDevice.fromMap(m))
        .toList();
  }

  /// Remove a peer (e.g. after disconnect).
  Future<void> removePeer(String deviceId) async {
    await Hive.box(_peersBox).delete(deviceId);
  }
}
