// ============================================================
// FILE: lib/models/message.dart
// PURPOSE: The core message model for the mesh network.
//
// Every message in RelayX carries extra fields beyond just text:
//   - id:         A unique ID so we can detect duplicates
//   - senderId:   Who originally created this message
//   - receiverId: Who should DISPLAY this message (final destination)
//   - ttl:        "Time To Live" — decremented every hop; when 0 drop it
//   - hopCount:   How many devices this message has passed through
//   - isEncrypted: Whether the content is AES-encrypted
// ============================================================

import 'package:uuid/uuid.dart';

/// Represents a single message travelling through the mesh network.
class MeshMessage {
  /// Unique identifier — used to prevent duplicate forwarding
  final String id;

  /// The device ID of whoever originally sent this message
  final String senderId;

  /// The device ID of the intended final recipient
  final String receiverId;

  /// The message body (may be AES-encrypted — check isEncrypted)
  final String content;

  /// When this message was created (milliseconds since epoch)
  final DateTime timestamp;

  /// Time-To-Live: decremented each hop; when 0 the message is dropped
  int ttl;

  /// How many relay devices this message has passed through
  int hopCount;

  /// True when `content` has been AES-encrypted by EncryptionService
  final bool isEncrypted;

  /// Optional: the last device that forwarded this message (for "Relayed via X" UI)
  final String? relayedBy;

  MeshMessage({
    String? id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    DateTime? timestamp,
    this.ttl = 5,          // default: allow up to 5 hops
    this.hopCount = 0,
    this.isEncrypted = false,
    this.relayedBy,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  // -----------------------------------------------------------
  // toMap() — serialize for Hive storage or socket transmission
  // -----------------------------------------------------------
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'content': content,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'ttl': ttl,
      'hopCount': hopCount,
      'isEncrypted': isEncrypted,
      'relayedBy': relayedBy,
    };
  }

  // -----------------------------------------------------------
  // fromMap() — deserialize from Hive or socket JSON
  // -----------------------------------------------------------
  factory MeshMessage.fromMap(Map<dynamic, dynamic> map) {
    return MeshMessage(
      id: map['id'] as String? ?? const Uuid().v4(),
      senderId: map['senderId'] as String? ?? 'unknown',
      receiverId: map['receiverId'] as String? ?? 'unknown',
      content: map['content'] as String? ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        map['timestamp'] as int? ?? 0,
      ),
      ttl: map['ttl'] as int? ?? 5,
      hopCount: map['hopCount'] as int? ?? 0,
      isEncrypted: map['isEncrypted'] as bool? ?? false,
      relayedBy: map['relayedBy'] as String?,
    );
  }

  // -----------------------------------------------------------
  // copyWith() — create a modified copy (used by mesh router
  //              to decrement TTL and increment hopCount)
  // -----------------------------------------------------------
  MeshMessage copyWith({
    int? ttl,
    int? hopCount,
    String? relayedBy,
  }) {
    return MeshMessage(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      timestamp: timestamp,
      ttl: ttl ?? this.ttl,
      hopCount: hopCount ?? this.hopCount,
      isEncrypted: isEncrypted,
      relayedBy: relayedBy ?? this.relayedBy,
    );
  }

  @override
  String toString() =>
      'MeshMessage(id:$id from:$senderId to:$receiverId ttl:$ttl hops:$hopCount)';
}

// ============================================================
// BACKWARD COMPAT: Keep the old ChatMessage class so that
// previously stored Hive data does not break on upgrade.
// ============================================================

/// Legacy single-hop chat message — kept for Hive migration.
class ChatMessage {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? relayedBy; // NEW: optional relay info for UI

  ChatMessage({
    required this.text,
    required this.isMe,
    DateTime? timestamp,
    this.relayedBy,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'text': text,
        'isMe': isMe,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'relayedBy': relayedBy,
      };

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) => ChatMessage(
        text: map['text'] as String? ?? '',
        isMe: map['isMe'] as bool? ?? false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          map['timestamp'] as int? ?? 0,
        ),
        relayedBy: map['relayedBy'] as String?,
      );

  /// Create a ChatMessage from a MeshMessage for display purposes.
  factory ChatMessage.fromMesh(MeshMessage msg, {required bool isMe}) =>
      ChatMessage(
        text: msg.content,
        isMe: isMe,
        timestamp: msg.timestamp,
        relayedBy: msg.relayedBy,
      );
}
