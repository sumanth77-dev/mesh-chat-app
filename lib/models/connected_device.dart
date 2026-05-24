// ============================================================
// FILE: lib/models/connected_device.dart
// PURPOSE: Represents a peer device that this node is directly
//          connected to via WiFi Direct + socket.
//
// KEY CONCEPT:
//   In a mesh network, "neighbor" means a device that is ONE
//   socket-hop away from the current device.
//   This model tracks all such neighbors.
// ============================================================

/// Represents a directly connected neighbor device.
class ConnectedDevice {
  /// Unique device identifier sent during socket handshake.
  /// This is the "mesh ID" — used in senderId/receiverId fields.
  final String deviceId;

  /// Human-readable name (e.g. "Pixel 7").
  final String deviceName;

  /// WiFi Direct MAC address (e.g. "aa:bb:cc:dd:ee:ff").
  final String address;

  /// True if this device is the Group Owner (host) of the WiFi P2P group.
  final bool isGroupOwner;

  /// When this connection was established.
  final DateTime connectedAt;

  /// Optional: IP address of this device on the P2P network.
  final String? ipAddress;

  ConnectedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    this.isGroupOwner = false,
    DateTime? connectedAt,
    this.ipAddress,
  }) : connectedAt = connectedAt ?? DateTime.now();

  // -----------------------------------------------------------
  // Serialization — for Hive persistent storage
  // -----------------------------------------------------------
  Map<String, dynamic> toMap() {
    return {
      'deviceId': deviceId,
      'deviceName': deviceName,
      'address': address,
      'isGroupOwner': isGroupOwner,
      'connectedAt': connectedAt.millisecondsSinceEpoch,
      'ipAddress': ipAddress,
    };
  }

  factory ConnectedDevice.fromMap(Map<dynamic, dynamic> map) {
    return ConnectedDevice(
      deviceId: map['deviceId'] as String? ?? 'unknown',
      deviceName: map['deviceName'] as String? ?? 'Unknown Device',
      address: map['address'] as String? ?? '',
      isGroupOwner: map['isGroupOwner'] as bool? ?? false,
      connectedAt: DateTime.fromMillisecondsSinceEpoch(
        map['connectedAt'] as int? ?? 0,
      ),
      ipAddress: map['ipAddress'] as String?,
    );
  }

  ConnectedDevice copyWith({
    String? deviceId,
    String? deviceName,
    String? address,
    bool? isGroupOwner,
    String? ipAddress,
  }) {
    return ConnectedDevice(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      address: address ?? this.address,
      isGroupOwner: isGroupOwner ?? this.isGroupOwner,
      connectedAt: connectedAt,
      ipAddress: ipAddress ?? this.ipAddress,
    );
  }

  @override
  String toString() =>
      'ConnectedDevice(id:$deviceId name:$deviceName addr:$address GO:$isGroupOwner)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectedDevice && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}
