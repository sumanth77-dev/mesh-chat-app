// ============================================================
// FILE: lib/main.dart
// PURPOSE: App entry point — initializes all mesh services.
//
// INITIALIZATION ORDER (important!):
//   1. Hive (database) — must be first
//   2. SharedPreferences (or Hive) to load/create this device's
//      permanent mesh ID and display name
//   3. Create SocketManager → WifiDirectService → MeshRouter
//      (they share the same SocketManager instance)
//   4. Launch UI
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'services/database_service.dart';
import 'services/socket_manager.dart';
import 'services/encryption_service.dart';
import 'services/mesh_router.dart';
import 'services/wifi_direct_service.dart';
import 'services/notification_service.dart';
import 'services/packet_queue_service.dart';
import 'services/ack_manager.dart';
import 'services/retry_service.dart';
import 'screens/device_list_screen.dart';
import 'utils/app_theme.dart';

// ── Global mesh service instances ─────────────────────────
// These are singletons shared across the whole app.
// They are created here and passed down to screens.
late final SocketManager globalSocketManager;
late final WifiDirectService globalWifiDirectService;
late final MeshRouter globalMeshRouter;
late final EncryptionService globalEncryption;
late final DatabaseService globalDatabase;

/// This device's permanent mesh ID (UUID, generated once at install).
late final String myDeviceId;

/// This device's display name (used as "relayedBy" label).
late final String myDeviceName;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Step 1: Initialize Hive ────────────────────────────────
  await DatabaseService.initialize();
  await PacketQueueService.initialize();
  globalDatabase = DatabaseService();

  // ── Step 2: Load or create this device's mesh identity ─────
  // We store the UUID in a Hive box so it persists across restarts.
  final identityBox = await Hive.openBox('identity');
  if (!identityBox.containsKey('deviceId')) {
    // First launch — generate a permanent UUID
    final newId = const Uuid().v4();
    await identityBox.put('deviceId', newId);
    // Unique default name using the last 4 chars of the UUID
    // so two fresh installs are distinguishable (e.g. RelayX-A3F1)
    final suffix = newId.replaceAll('-', '').substring(0, 4).toUpperCase();
    await identityBox.put('deviceName', 'RelayX-$suffix');
  }
  myDeviceId = identityBox.get('deviceId') as String;
  myDeviceName = identityBox.get('deviceName') as String;

  debugPrint('🪪 My mesh ID: $myDeviceId ($myDeviceName)');

  // ── Step 3: Create service instances ──────────────────────
  globalEncryption = EncryptionService();
  globalSocketManager = SocketManager()..myDeviceId = myDeviceId;

  globalWifiDirectService = WifiDirectService(
    socketManager: globalSocketManager,
    myDeviceId: myDeviceId,
    myDeviceName: myDeviceName,
  );

  globalMeshRouter = MeshRouter(
    socketManager: globalSocketManager,
    encryption: globalEncryption,
    database: globalDatabase,
    myDeviceId: myDeviceId,
    myDeviceName: myDeviceName,
  );

  // ── Step 4: Initialize local notifications ─────────────────
  // Must run before runApp so the channel exists when first
  // message arrives. Works fully offline — no internet needed.
  final notifService = NotificationService();
  await notifService.initialize();
  await notifService.requestPermission();

  // Wire into MeshRouter: fires ONLY for messages addressed to
  // THIS device (after decryption). Relay packets are never notified.
  globalMeshRouter.onNotifyMessage = (senderId, senderName, content) {
    notifService.showMessageNotification(
      senderName: senderName.isNotEmpty ? senderName : senderId.substring(0, 8),
      messageText: content,
    );
  };

  // ── Step 5: Store-and-Forward ──────────────────────────────
  final packetQueue = PacketQueueService();
  final ackManager = AckManager(
    socketManager: globalSocketManager,
    packetQueue: packetQueue,
    myDeviceId: myDeviceId,
  );
  final retryService = RetryService(
    socketManager: globalSocketManager,
    packetQueue: packetQueue,
  );
  globalMeshRouter.packetQueue = packetQueue;
  globalMeshRouter.ackManager = ackManager;
  globalSocketManager.onAckReceived = ackManager.handleIncomingAck;
  globalSocketManager.onPeerConnected = retryService.onPeerReconnected;
  retryService.start();

  // ── Step 6: Launch the app ─────────────────────────────────
  runApp(const RelayXApp());
}

class RelayXApp extends StatelessWidget {
  const RelayXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RelayX',
      theme: AppTheme.theme,
      home: DeviceListScreen(
        wifiDirect: globalWifiDirectService,
        meshRouter: globalMeshRouter,
        socketManager: globalSocketManager,
        myDeviceId: myDeviceId,
        myDeviceName: myDeviceName,
      ),
    );
  }
}