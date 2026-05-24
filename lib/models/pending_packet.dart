// ============================================================
// FILE: lib/models/pending_packet.dart
// PURPOSE: Represents a queued outgoing packet waiting for delivery ACK.
//
// Packets are stored ENCRYPTED so relay nodes cannot read content.
// Persisted to Hive so queue survives app restarts.
// ============================================================

class PendingPacket {
  /// Unique ID — same as the MeshMessage.id inside the payload.
  final String packetId;

  /// The target receiver's mesh device ID.
  final String receiverId;

  /// Full JSON-encoded MeshMessage string, already encrypted.
  final String encryptedPayload;

  /// When this packet was first queued.
  final DateTime timestamp;

  /// How many send attempts have been made.
  int retryCount;

  /// Original TTL of the packet.
  final int ttl;

  /// True once an ACK is received — packet can be deleted.
  bool delivered;

  /// When we last attempted a resend (null if never retried).
  DateTime? lastRetryTime;

  PendingPacket({
    required this.packetId,
    required this.receiverId,
    required this.encryptedPayload,
    required this.timestamp,
    this.retryCount = 0,
    this.ttl = 5,
    this.delivered = false,
    this.lastRetryTime,
  });

  // ── Serialization ─────────────────────────────────────────
  Map<String, dynamic> toMap() => {
        'packetId': packetId,
        'receiverId': receiverId,
        'encryptedPayload': encryptedPayload,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'retryCount': retryCount,
        'ttl': ttl,
        'delivered': delivered,
        'lastRetryTime': lastRetryTime?.millisecondsSinceEpoch,
      };

  factory PendingPacket.fromMap(Map<String, dynamic> map) => PendingPacket(
        packetId: map['packetId'] as String,
        receiverId: map['receiverId'] as String,
        encryptedPayload: map['encryptedPayload'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
            map['timestamp'] as int),
        retryCount: (map['retryCount'] as int?) ?? 0,
        ttl: (map['ttl'] as int?) ?? 5,
        delivered: (map['delivered'] as bool?) ?? false,
        lastRetryTime: map['lastRetryTime'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                map['lastRetryTime'] as int)
            : null,
      );

  @override
  String toString() =>
      'PendingPacket[$packetId] to:$receiverId retries:$retryCount delivered:$delivered';
}
