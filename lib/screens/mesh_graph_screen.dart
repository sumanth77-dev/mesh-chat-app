import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/socket_manager.dart';
import '../utils/app_theme.dart';

class MeshGraphScreen extends StatefulWidget {
  final SocketManager socketManager;
  final String myDeviceId;
  final String myDeviceName;

  const MeshGraphScreen({
    super.key,
    required this.socketManager,
    required this.myDeviceId,
    required this.myDeviceName,
  });

  @override
  State<MeshGraphScreen> createState() => _MeshGraphScreenState();
}

class _MeshGraphScreenState extends State<MeshGraphScreen>
    with TickerProviderStateMixin {

  late AnimationController _pulseCtrl;
  late AnimationController _rotateCtrl;
  late AnimationController _packetCtrl;
  Timer? _refreshTimer;
  int _activePacketEdge = 0;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _rotateCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
    _packetCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() { _activePacketEdge = (_activePacketEdge + 1) % max(1, widget.socketManager.neighborCount); });
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _rotateCtrl.dispose();
    _packetCtrl.dispose();
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neighbors = widget.socketManager.connectedDevices;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: AppTheme.textPrim, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Mesh Network', style: TextStyle(color: AppTheme.textPrim)),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.green.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.green.withOpacity(0.4)),
            ),
            child: Text('${neighbors.length + 1} NODES',
                style: const TextStyle(color: AppTheme.green, fontSize: 10, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([_pulseCtrl, _rotateCtrl, _packetCtrl]),
            builder: (ctx, _) => CustomPaint(
              painter: _MeshPainter(
                neighbors: neighbors,
                myName: widget.myDeviceName,
                pulse: _pulseCtrl.value,
                rotate: _rotateCtrl.value,
                packetProgress: _packetCtrl.value,
                activeEdge: _activePacketEdge,
              ),
              child: Container(),
            ),
          ),
        ),
        _buildLegend(neighbors),
      ]),
    );
  }

  Widget _buildLegend(List neighbors) => Container(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
    decoration: BoxDecoration(
      color: AppTheme.surface,
      border: Border(top: BorderSide(color: AppTheme.border)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('LIVE NODES', style: TextStyle(color: AppTheme.textSec, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.5)),
      const SizedBox(height: 12),
      Row(children: [
        _legendDot(AppTheme.cyan),
        const SizedBox(width: 6),
        Text('${widget.myDeviceName} (You)', style: const TextStyle(color: AppTheme.textPrim, fontSize: 12)),
        const Spacer(),
        const Text('Group Owner', style: TextStyle(color: AppTheme.cyan, fontSize: 11)),
      ]),
      ...widget.socketManager.connectedDevices.map((d) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          _legendDot(AppTheme.green),
          const SizedBox(width: 6),
          Expanded(child: Text(d.deviceName, style: const TextStyle(color: AppTheme.textPrim, fontSize: 12))),
          Text(d.ipAddress ?? d.address, style: const TextStyle(color: AppTheme.textSec, fontSize: 10)),
        ]),
      )),
      if (neighbors.isEmpty)
        const Padding(padding: EdgeInsets.only(top: 8),
          child: Text('No peers connected. Scan to discover devices.',
              style: TextStyle(color: AppTheme.textSec, fontSize: 12))),
    ]),
  );

  Widget _legendDot(Color color) => Container(
    width: 10, height: 10,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)],
    ),
  );
}

class _MeshPainter extends CustomPainter {
  final List neighbors;
  final String myName;
  final double pulse;
  final double rotate;
  final double packetProgress;
  final int activeEdge;

  _MeshPainter({
    required this.neighbors,
    required this.myName,
    required this.pulse,
    required this.rotate,
    required this.packetProgress,
    required this.activeEdge,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = min(cx, cy) * 0.58;

    // Background grid
    _drawGrid(canvas, size);

    // Center node (this device) glow rings
    _drawPulseRings(canvas, Offset(cx, cy), pulse);

    // Node positions
    final positions = <Offset>[Offset(cx, cy)];
    final n = neighbors.length;
    for (int i = 0; i < n; i++) {
      final angle = (2 * pi * i / max(1, n)) - pi / 2 + rotate * 0.15;
      positions.add(Offset(cx + radius * cos(angle), cy + radius * sin(angle)));
    }

    // Draw edges with animated packet
    for (int i = 1; i < positions.length; i++) {
      _drawEdge(canvas, positions[0], positions[i]);
      if (i - 1 == activeEdge % max(1, n)) {
        _drawPacket(canvas, positions[0], positions[i], packetProgress);
      }
    }

    // Draw peer-to-peer edges between neighbors
    for (int i = 1; i < positions.length; i++) {
      for (int j = i + 1; j < positions.length; j++) {
        _drawEdgeDashed(canvas, positions[i], positions[j]);
      }
    }

    // Draw peer nodes
    for (int i = 1; i < positions.length; i++) {
      final name = neighbors[i - 1].deviceName as String;
      _drawNode(canvas, positions[i], AppTheme.green, name, false);
    }

    // Draw center node (on top)
    _drawNode(canvas, Offset(cx, cy), AppTheme.cyan, myName, true);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppTheme.border.withOpacity(0.3)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _drawPulseRings(Canvas canvas, Offset center, double pulse) {
    for (int i = 0; i < 3; i++) {
      final t = (pulse + i / 3) % 1.0;
      canvas.drawCircle(center, 40 + t * 80,
        Paint()
          ..color = AppTheme.cyan.withOpacity((1 - t) * 0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _drawEdge(Canvas canvas, Offset a, Offset b) {
    canvas.drawLine(a, b,
      Paint()
        ..color = AppTheme.cyan.withOpacity(0.25)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );
    // Glow
    canvas.drawLine(a, b,
      Paint()
        ..color = AppTheme.cyan.withOpacity(0.08)
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  void _drawEdgeDashed(Canvas canvas, Offset a, Offset b) {
    final paint = Paint()
      ..color = AppTheme.green.withOpacity(0.2)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    const dashLen = 6.0;
    const gapLen = 5.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final dist = sqrt(dx * dx + dy * dy);
    final nx = dx / dist;
    final ny = dy / dist;
    double d = 0;
    while (d < dist) {
      final end = min(d + dashLen, dist);
      canvas.drawLine(
        Offset(a.dx + nx * d, a.dy + ny * d),
        Offset(a.dx + nx * end, a.dy + ny * end), paint);
      d += dashLen + gapLen;
    }
  }

  void _drawPacket(Canvas canvas, Offset a, Offset b, double t) {
    final x = a.dx + (b.dx - a.dx) * t;
    final y = a.dy + (b.dy - a.dy) * t;
    canvas.drawCircle(Offset(x, y), 5,
        Paint()..color = AppTheme.cyan..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(Offset(x, y), 3, Paint()..color = Colors.white);
  }

  void _drawNode(Canvas canvas, Offset pos, Color color, String label, bool isCenter) {
    final r = isCenter ? 32.0 : 26.0;

    // Glow
    canvas.drawCircle(pos, r + 8,
        Paint()..color = color.withOpacity(0.15)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));

    // Ring
    canvas.drawCircle(pos, r,
        Paint()..color = color.withOpacity(0.3)..style = PaintingStyle.stroke..strokeWidth = 2);

    // Fill
    canvas.drawCircle(pos, r - 3,
        Paint()..color = AppTheme.card);

    // Icon letter
    final tp = TextPainter(
      text: TextSpan(
        text: label.isNotEmpty ? label[0].toUpperCase() : '?',
        style: TextStyle(color: color, fontSize: isCenter ? 18 : 14, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));

    // Label below
    final labelLen = label.length > 10 ? '${label.substring(0, 9)}…' : label;
    final lp = TextPainter(
      text: TextSpan(text: labelLen,
          style: TextStyle(color: AppTheme.textSec, fontSize: 10, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    lp.paint(canvas, Offset(pos.dx - lp.width / 2, pos.dy + r + 6));
  }

  @override
  bool shouldRepaint(_MeshPainter old) => true;
}
