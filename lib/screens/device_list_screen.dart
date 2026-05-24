import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/connected_device.dart';
import '../services/wifi_direct_service.dart';
import '../services/mesh_router.dart';
import '../services/socket_manager.dart';
import '../utils/app_theme.dart';
import 'chat_screen.dart';
import 'mesh_graph_screen.dart';

class DeviceListScreen extends StatefulWidget {
  final WifiDirectService wifiDirect;
  final MeshRouter meshRouter;
  final SocketManager socketManager;
  final String myDeviceId;
  final String myDeviceName;

  const DeviceListScreen({
    super.key,
    required this.wifiDirect,
    required this.meshRouter,
    required this.socketManager,
    required this.myDeviceId,
    required this.myDeviceName,
  });

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen>
    with TickerProviderStateMixin {

  List<Map<String, dynamic>> _discoveredPeers = [];
  bool _isScanning = false;
  String? _connectingAddress;
  Timer? _connectingTimeout;
  String? _connectionStatus;
  String? _errorMessage;
  bool _isGroupFormed = false;
  bool _isGroupOwner = false;

  // Cache WiFi Direct device names (MAC address → real device name)
  // Populated from discovery scan so neighbor cards show the real
  // Android device name (e.g. "POCO M3") instead of the mesh handshake
  // name (e.g. "RelayX Device").
  final Map<String, String> _wifiDirectNames = {};


  late AnimationController _radarController;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
    _pulseController = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _setupListeners();
    _initializeWifiDirect();
  }

  // Auto-scan timer removed — discovery resets P2P state and interrupts connections.
  // User taps Scan manually when needed.

  void _setupListeners() {
    widget.wifiDirect.setDeviceListener((peers) {
      if (!mounted) return;
      setState(() {
        if (peers.isNotEmpty) {
          _discoveredPeers = peers;
          // Cache real device names by MAC address
          for (final p in peers) {
            final addr = p['address'] as String? ?? '';
            final name = p['name'] as String? ?? '';
            if (addr.isNotEmpty && name.isNotEmpty) {
              _wifiDirectNames[addr] = name;
            }
          }
        }
        _isScanning = false;
      });
    });

    widget.wifiDirect.setConnectionListener((info) {
      if (!mounted) return;
      final groupFormed = info['groupFormed'] as bool? ?? false;
      final isGO = info['isGroupOwner'] as bool? ?? false;
      setState(() {
        _isGroupFormed = groupFormed;
        _isGroupOwner = isGO;
        _connectingAddress = null;
        _connectingTimeout?.cancel();
        if (groupFormed) {
          _connectionStatus = isGO ? 'Relay Hub · Group Owner' : 'Connected · Relay Node';
        } else {
          _connectionStatus = null;
          // Do NOT auto-rescan here — it would disrupt reconnect flow
        }
      });
    });

    widget.wifiDirect.setPeerConnectedCallback((device) {
      if (!mounted) return;
      setState(() {});
      _showSnack('${device.deviceName} joined the mesh', AppTheme.green);
    });
  }

  Future<void> _initializeWifiDirect() async {
    try {
      final ok = await widget.wifiDirect.requestPermissions();
      if (ok) {
        setState(() => _errorMessage = null);
        await _startDiscovery();
        // Auto-rescan removed — manual scan only
      } else {
        setState(() => _errorMessage = 'Permissions required. Please allow WiFi & Location.');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Init error: $e');
    }
  }

  Future<void> _startDiscovery() async {
    setState(() { _isScanning = true; _errorMessage = null; });
    try {
      await widget.wifiDirect.discoverDevices();
    } catch (e) {
      setState(() { _errorMessage = 'Scan failed: $e'; _isScanning = false; });
    }
  }

  Future<void> _connectToDevice(String address, String name) async {
    if (_connectingAddress != null) return;
    setState(() => _connectingAddress = address);
    _connectingTimeout?.cancel();
    _connectingTimeout = Timer(const Duration(seconds: 35), () {
      if (mounted && _connectingAddress == address) {
        setState(() => _connectingAddress = null);
        _showSnack('Connection timed out. Try again.', AppTheme.orange);
      }
    });
    try {
      await widget.wifiDirect.connectToDevice(address);
    } catch (e) {
      _connectingTimeout?.cancel();
      _showSnack('Could not connect to $name', AppTheme.red);
      if (mounted) setState(() => _connectingAddress = null);
    }
  }

  Future<void> _disconnect() async {
    final ok = await _confirmDialog('Leave Mesh', 'Disconnect from the mesh network?');
    if (!ok) return;
    try {
      await widget.wifiDirect.disconnect();
      setState(() { _connectionStatus = null; _isGroupFormed = false; });
      _startDiscovery();
    } catch (e) {
      _showSnack('Disconnect error: $e', AppTheme.red);
    }
  }

  void _openChat(ConnectedDevice peer) => Navigator.push(
    context,
    PageRouteBuilder(
      pageBuilder: (_, a, __) => ChatScreen(
        peer: peer, meshRouter: widget.meshRouter,
        socketManager: widget.socketManager,
        myDeviceId: widget.myDeviceId, myDeviceName: widget.myDeviceName,
      ),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ),
  );

  Future<void> _disconnectPeer(ConnectedDevice peer) async {
    final ok = await _confirmDialog(
      'Disconnect ${peer.deviceName}',
      'Remove ${peer.deviceName} from the mesh?\nOther connections will stay active.',
    );
    if (!ok) return;
    widget.socketManager.removeConnection(peer.deviceId);
    setState(() {});
    _showSnack('${peer.deviceName} disconnected', AppTheme.orange);
  }

  void _openMeshGraph() => Navigator.push(
    context,
    PageRouteBuilder(
      pageBuilder: (_, a, __) => MeshGraphScreen(
        socketManager: widget.socketManager,
        myDeviceId: widget.myDeviceId,
        myDeviceName: widget.myDeviceName,
      ),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ),
  );

  Future<bool> _confirmDialog(String title, String msg) async =>
    await showDialog<bool>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(color: AppTheme.textPrim)),
        content: Text(msg, style: const TextStyle(color: AppTheme.textSec)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: AppTheme.textSec))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.red, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    ) ?? false;

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      backgroundColor: color.withOpacity(0.9),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ));
  }

  @override
  void dispose() {
    _radarController.dispose();
    _pulseController.dispose();
    _connectingTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neighbors = widget.socketManager.connectedDevices;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(neighbors),
          if (_connectionStatus != null) SliverToBoxAdapter(child: _buildStatusBanner()),
          if (neighbors.isNotEmpty) SliverToBoxAdapter(child: _buildNeighborSection(neighbors)),
          SliverToBoxAdapter(child: _buildNearbyHeader()),
          SliverToBoxAdapter(child: _buildBody()),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
      floatingActionButton: _buildFAB(),
    );
  }

  Widget _buildAppBar(List<ConnectedDevice> neighbors) {
    return SliverAppBar(
      expandedHeight: 130,
      floating: false,
      pinned: true,
      backgroundColor: AppTheme.surface,
      elevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF0F0F23), Color(0xFF070714)],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 48, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildLogo(),
                const SizedBox(width: 14),
                Expanded(child: _buildHeaderText()),
                if (neighbors.length >= 2) _buildRelayBadge(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.hub_outlined, color: AppTheme.cyan),
          tooltip: 'Mesh Graph',
          onPressed: _openMeshGraph,
        ),
        if (_isGroupFormed)
          IconButton(
            icon: const Icon(Icons.link_off, color: AppTheme.red),
            tooltip: 'Disconnect',
            onPressed: _disconnect,
          ),
        if (_isScanning)
          const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(color: AppTheme.cyan, strokeWidth: 2)),
          )
        else
          IconButton(
            icon: const Icon(Icons.radar, color: AppTheme.cyan),
            onPressed: _startDiscovery,
          ),
      ],
    );
  }

  Widget _buildLogo() => Container(
    width: 46, height: 46,
    decoration: BoxDecoration(
      gradient: AppTheme.accentGradient,
      borderRadius: BorderRadius.circular(14),
      boxShadow: AppTheme.purpleGlow(),
    ),
    child: const Icon(Icons.hub_rounded, color: Colors.white, size: 26),
  ).animate().scale(duration: 600.ms, curve: Curves.elasticOut);

  Widget _buildHeaderText() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('RelayX', style: TextStyle(color: AppTheme.textPrim, fontSize: 26,
          fontWeight: FontWeight.w900, letterSpacing: 1.5)),
      Text(widget.myDeviceName, style: const TextStyle(color: AppTheme.textSec, fontSize: 12)),
    ],
  );

  Widget _buildRelayBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: AppTheme.orange.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: AppTheme.orange.withOpacity(0.5)),
    ),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.swap_horiz, color: AppTheme.orange, size: 13),
      SizedBox(width: 4),
      Text('RELAY', style: TextStyle(color: AppTheme.orange, fontSize: 10,
          fontWeight: FontWeight.w800, letterSpacing: 1.2)),
    ]),
  );

  Widget _buildStatusBanner() => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
    decoration: BoxDecoration(
      color: (_isGroupOwner ? AppTheme.cyan : AppTheme.green).withOpacity(0.08),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: (_isGroupOwner ? AppTheme.cyan : AppTheme.green).withOpacity(0.35)),
    ),
    child: Row(children: [
      AnimatedBuilder(animation: _pulseAnim, builder: (_, __) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          color: (_isGroupOwner ? AppTheme.cyan : AppTheme.green).withOpacity(_pulseAnim.value),
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: (_isGroupOwner ? AppTheme.cyan : AppTheme.green).withOpacity(0.5), blurRadius: 6)],
        ),
      )),
      const SizedBox(width: 10),
      Text(_connectionStatus ?? '', style: TextStyle(
        color: _isGroupOwner ? AppTheme.cyan : AppTheme.green,
        fontWeight: FontWeight.w700, fontSize: 13,
      )),
    ]),
  ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.2);

  Widget _buildNeighborSection(List<ConnectedDevice> neighbors) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        AnimatedBuilder(animation: _pulseAnim, builder: (_, __) => Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
            color: AppTheme.green.withOpacity(_pulseAnim.value),
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: AppTheme.green.withOpacity(0.6), blurRadius: 8)],
          ),
        )),
        const SizedBox(width: 8),
        Text('${neighbors.length} NEIGHBOR${neighbors.length > 1 ? 'S' : ''} CONNECTED',
            style: const TextStyle(color: AppTheme.green, fontSize: 11,
                fontWeight: FontWeight.w800, letterSpacing: 1.5)),
      ]),
      const SizedBox(height: 10),
      ...neighbors.asMap().entries.map((e) =>
          _buildNeighborCard(e.value).animate(delay: (e.key * 80).ms).fadeIn().slideX(begin: -0.1)),
    ]),
  );

  Widget _buildNeighborCard(ConnectedDevice peer) {
    // Prefer the real WiFi Direct device name cached from discovery scan.
    // Falls back to mesh handshake name if device was never in the scan list.
    final displayName = _wifiDirectNames[peer.address]
        ?? _wifiDirectNames[peer.ipAddress ?? '']
        ?? peer.deviceName;

    return GestureDetector(
      onTap: () => _openChat(peer),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.glowCard(glowColor: AppTheme.green),
        child: Row(children: [
          _peerAvatar(displayName, AppTheme.green),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(displayName, style: const TextStyle(color: AppTheme.textPrim,
                fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 2),
            Text('📶 ${peer.ipAddress ?? peer.address}',
                style: const TextStyle(color: AppTheme.textSec, fontSize: 11)),
            const SizedBox(height: 4),
            Row(children: [
              _badge('● Mesh Node', AppTheme.green),
              const SizedBox(width: 6),
              Text('ID: ${peer.deviceId.substring(0, 8)}',
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 9)),
            ]),
          ])),
          // Disconnect single node
          GestureDetector(
            onTap: () => _disconnectPeer(peer),
            child: Container(
              width: 36, height: 36,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: AppTheme.red.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.red.withOpacity(0.35)),
              ),
              child: const Icon(Icons.link_off, color: AppTheme.red, size: 17),
            ),
          ),
          _glowButton('Chat', AppTheme.green, () => _openChat(peer)),
        ]),
      ),
    );
  }

  Widget _buildNearbyHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Row(children: [
      const Text('NEARBY DEVICES',
          style: TextStyle(color: AppTheme.textSec, fontSize: 11,
              fontWeight: FontWeight.w700, letterSpacing: 1.5)),
      const Spacer(),
      if (_isScanning) Row(children: [
        const SizedBox(width: 10, height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.cyan)),
        const SizedBox(width: 6),
        const Text('Scanning...', style: TextStyle(color: AppTheme.cyan, fontSize: 10)),
      ]),
    ]),
  );

  Widget _buildBody() {
    if (_errorMessage != null) return _buildErrorState();
    if (_isScanning && _discoveredPeers.isEmpty) return _buildScanningState();
    if (_discoveredPeers.isEmpty) return _buildEmptyState();
    return Column(
      children: _discoveredPeers.asMap().entries.map((e) {
        final name = e.value['name'] as String? ?? 'Unknown';
        final address = e.value['address'] as String? ?? '';
        final connected = widget.socketManager.connectedDeviceIds
            .any((id) => id == address || id.contains(address));
        return _buildDiscoveredCard(name, address, connected)
            .animate(delay: (e.key * 60).ms).fadeIn().slideY(begin: 0.1);
      }).toList(),
    );
  }

  Widget _buildDiscoveredCard(String name, String address, bool connected) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: connected ? AppTheme.green.withOpacity(0.4) : AppTheme.border,
      ),
    ),
    child: Row(children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.purple.withOpacity(0.3)),
        ),
        child: const Icon(Icons.phone_android_rounded, color: AppTheme.purple, size: 22),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(color: AppTheme.textPrim,
            fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 2),
        Text(address, style: const TextStyle(color: AppTheme.textSec, fontSize: 11)),
      ])),
      if (_connectingAddress == address)
        const SizedBox(width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.cyan))
      else if (connected)
        _badge('Connected', AppTheme.green)
      else
        _glowButton(
          'Connect',
          AppTheme.cyan,
          _connectingAddress != null ? null : () => _connectToDevice(address, name),
        ),
    ]),
  );

  Widget _buildScanningState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Column(children: [
      AnimatedBuilder(
        animation: _radarController,
        builder: (_, __) => Transform.rotate(
          angle: _radarController.value * 2 * pi,
          child: Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.cyan.withOpacity(0.3), width: 2),
            ),
            child: const Icon(Icons.radar, color: AppTheme.cyan, size: 36),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Text('Scanning for mesh nodes...',
          style: TextStyle(color: AppTheme.textSec, fontSize: 15)),
    ]),
  );

  Widget _buildEmptyState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
    child: Column(children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          color: AppTheme.surface, borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.cyan.withOpacity(0.2)),
        ),
        child: const Icon(Icons.wifi_find, size: 40, color: AppTheme.cyan),
      ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
      const SizedBox(height: 20),
      const Text('No devices found', style: TextStyle(color: AppTheme.textPrim,
          fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('Ensure WiFi Direct is enabled on nearby devices.\nTap Scan to search again.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSec.withOpacity(0.7), fontSize: 13)),
    ]),
  );

  Widget _buildErrorState() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
    child: Column(children: [
      const Icon(Icons.error_outline, size: 64, color: AppTheme.red),
      const SizedBox(height: 16),
      Text(_errorMessage!, textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.red, fontSize: 14)),
      const SizedBox(height: 20),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.purple,
            foregroundColor: Colors.white),
        onPressed: _initializeWifiDirect,
        icon: const Icon(Icons.refresh), label: const Text('Retry'),
      ),
    ]),
  );

  Widget _buildFAB() => FloatingActionButton.extended(
    onPressed: _isScanning ? null : _startDiscovery,
    backgroundColor: AppTheme.purple,
    foregroundColor: Colors.white,
    elevation: 8,
    icon: _isScanning
        ? const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
        : const Icon(Icons.search),
    label: Text(_isScanning ? 'Scanning...' : 'Scan for Devices'),
  );

  Widget _peerAvatar(String name, Color color) => Container(
    width: 44, height: 44,
    decoration: BoxDecoration(
      gradient: LinearGradient(colors: [color, color.withOpacity(0.6)]),
      borderRadius: BorderRadius.circular(12),
      boxShadow: [BoxShadow(color: color.withOpacity(0.3), blurRadius: 10)],
    ),
    child: Center(child: Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
    )),
  );

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
  );

  Widget _glowButton(String label, Color color, VoidCallback? onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        gradient: onTap == null ? null : LinearGradient(colors: [color.withOpacity(0.8), color]),
        color: onTap == null ? AppTheme.textSec.withOpacity(0.2) : null,
        borderRadius: BorderRadius.circular(10),
        boxShadow: onTap == null ? [] : [BoxShadow(color: color.withOpacity(0.35), blurRadius: 10)],
      ),
      child: Text(label, style: TextStyle(
        color: onTap == null ? AppTheme.textSec : Colors.white,
        fontWeight: FontWeight.w700, fontSize: 13,
      )),
    ),
  );
}