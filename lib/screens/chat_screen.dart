import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/message.dart';
import '../models/connected_device.dart';
import '../services/mesh_router.dart';
import '../services/socket_manager.dart';
import '../services/database_service.dart';
import '../utils/app_theme.dart';

class ChatScreen extends StatefulWidget {
  final ConnectedDevice peer;
  final MeshRouter meshRouter;
  final SocketManager socketManager;
  final String myDeviceId;
  final String myDeviceName;

  const ChatScreen({
    super.key,
    required this.peer,
    required this.meshRouter,
    required this.socketManager,
    required this.myDeviceId,
    required this.myDeviceName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  List<_Msg> _messages = [];
  bool _isSending = false;
  bool _showEncryptedBadge = false;

  late AnimationController _sendAnim;

  @override
  void initState() {
    super.initState();
    _sendAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _loadHistory();
    _setupListener();
  }

  void _loadHistory() {
    final stored = DatabaseService().loadMessages();
    setState(() {
      _messages = stored.map((m) => _Msg.fromChat(m)).toList();
    });
    _scrollToBottom();
  }

  void _setupListener() {
    widget.meshRouter.onMessageForMe = (MeshMessage msg) {
      if (!mounted) return;
      setState(() => _messages.add(_Msg(
        text: msg.content, isMe: false,
        timestamp: msg.timestamp, senderId: msg.senderId,
        relayedBy: msg.relayedBy, hopCount: msg.hopCount,
      )));
      _scrollToBottom();
    };
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    _sendAnim.forward().then((_) => _sendAnim.reverse());

    final msg = _Msg(text: text, isMe: true, timestamp: DateTime.now(),
        senderId: widget.myDeviceId);
    setState(() { _isSending = true; _messages.add(msg); _showEncryptedBadge = true; });
    _controller.clear();
    _scrollToBottom();

    // Hide badge after 2s
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showEncryptedBadge = false);
    });

    try {
      await widget.meshRouter.sendMessage(
          content: text, receiverId: widget.peer.deviceId, ttl: 5);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Send failed: $e'),
          backgroundColor: AppTheme.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    _sendAnim.dispose();
    widget.meshRouter.onMessageForMe = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: _buildAppBar(),
      body: Column(children: [
        if (widget.socketManager.neighborCount > 1) _buildRelayBanner(),
        if (_showEncryptedBadge) _buildEncryptedBanner(),
        Expanded(child: _messages.isEmpty ? _buildEmpty() : _buildMessageList()),
        _buildInputBar(),
      ]),
    );
  }

  AppBar _buildAppBar() => AppBar(
    backgroundColor: AppTheme.surface,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_new, color: AppTheme.textPrim, size: 18),
      onPressed: () => Navigator.pop(context),
    ),
    title: Row(children: [
      _avatar(widget.peer.deviceName),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.peer.deviceName,
            style: const TextStyle(color: AppTheme.textPrim, fontSize: 15,
                fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis),
        Text('Mesh · ${widget.peer.deviceId.substring(0, 8)}...',
            style: const TextStyle(color: AppTheme.textSec, fontSize: 10)),
      ])),
    ]),
    actions: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.green.withOpacity(0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.green.withOpacity(0.4)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock, color: AppTheme.green, size: 12),
          SizedBox(width: 4),
          Text('E2E', style: TextStyle(color: AppTheme.green, fontSize: 10,
              fontWeight: FontWeight.w700)),
        ]),
      ),
      PopupMenuButton<String>(
        color: AppTheme.card,
        icon: const Icon(Icons.more_vert, color: AppTheme.textSec),
        onSelected: (v) async {
          if (v == 'clear') {
            await DatabaseService().clearMessages();
            setState(() => _messages.clear());
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'clear', child: Row(children: [
            Icon(Icons.delete_outline, color: AppTheme.red, size: 18),
            SizedBox(width: 8),
            Text('Clear History', style: TextStyle(color: AppTheme.red)),
          ])),
        ],
      ),
    ],
  );

  Widget _buildRelayBanner() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    color: AppTheme.orange.withOpacity(0.08),
    child: Row(children: [
      const Icon(Icons.swap_horiz, size: 13, color: AppTheme.orange),
      const SizedBox(width: 6),
      Text('Relaying through ${widget.socketManager.neighborCount} mesh peers',
          style: const TextStyle(color: AppTheme.orange, fontSize: 11,
              fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _buildEncryptedBanner() => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    color: AppTheme.green.withOpacity(0.06),
    child: const Row(children: [
      Icon(Icons.verified_user, size: 13, color: AppTheme.green),
      SizedBox(width: 6),
      Text('Message encrypted & routed securely through the mesh',
          style: TextStyle(color: AppTheme.green, fontSize: 11, fontWeight: FontWeight.w600)),
    ]),
  ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.5);

  Widget _buildEmpty() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 90, height: 90,
        decoration: BoxDecoration(
          color: AppTheme.surface, borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppTheme.purple.withOpacity(0.3)),
          boxShadow: AppTheme.purpleGlow(opacity: 0.2),
        ),
        child: const Icon(Icons.chat_bubble_outline_rounded, size: 40, color: AppTheme.purple),
      ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
      const SizedBox(height: 24),
      const Text('No messages yet', style: TextStyle(color: AppTheme.textPrim,
          fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('End-to-end encrypted mesh communication',
          style: TextStyle(color: AppTheme.textSec, fontSize: 13)),
    ]),
  );

  Widget _buildMessageList() => ListView.builder(
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    itemCount: _messages.length,
    itemBuilder: (_, i) => _buildBubble(_messages[i], i),
  );

  Widget _buildBubble(_Msg msg, int index) {
    final isMe = msg.isMe;
    final hasRelay = msg.relayedBy != null && msg.relayedBy!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (hasRelay && !isMe)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 3),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.route, size: 10, color: AppTheme.orange),
                    const SizedBox(width: 3),
                    Text('Relayed · ${msg.relayedBy}',
                        style: const TextStyle(color: AppTheme.orange, fontSize: 9,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  gradient: isMe ? AppTheme.sentBubbleGradient : null,
                  color: isMe ? null : AppTheme.card,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isMe ? 18 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 18),
                  ),
                  border: isMe ? null : Border.all(color: AppTheme.border),
                  boxShadow: isMe ? [
                    BoxShadow(color: AppTheme.purple.withOpacity(0.3),
                        blurRadius: 12, offset: const Offset(0, 4))
                  ] : [],
                ),
                child: Column(
                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(msg.text, style: TextStyle(
                        color: isMe ? Colors.white : AppTheme.textPrim,
                        fontSize: 14.5, height: 1.4)),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (msg.hopCount > 0) ...[
                        Icon(Icons.alt_route, size: 9,
                            color: isMe ? Colors.white54 : AppTheme.textSec),
                        const SizedBox(width: 2),
                        Text('${msg.hopCount} hop${msg.hopCount > 1 ? 's' : ''}',
                            style: TextStyle(fontSize: 9,
                                color: isMe ? Colors.white54 : AppTheme.textSec)),
                        const SizedBox(width: 6),
                      ],
                      Text(_formatTime(msg.timestamp), style: TextStyle(
                          fontSize: 10,
                          color: isMe ? Colors.white60 : AppTheme.textSec)),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.done_all, size: 12, color: Colors.white60),
                      ],
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ).animate(delay: Duration(milliseconds: index < 5 ? index * 40 : 0))
        .fadeIn(duration: 250.ms)
        .slideY(begin: 0.15, duration: 250.ms, curve: Curves.easeOut);
  }

  Widget _buildInputBar() => Container(
    decoration: BoxDecoration(
      color: AppTheme.surface,
      border: Border(top: BorderSide(color: AppTheme.border)),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, -4))],
    ),
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    child: SafeArea(top: false, child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.bg,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AppTheme.border),
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !_isSending,
              maxLines: 5, minLines: 1,
              style: const TextStyle(color: AppTheme.textPrim, fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Send encrypted message...',
                hintStyle: TextStyle(color: AppTheme.textSec.withOpacity(0.5), fontSize: 14),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ScaleTransition(
          scale: Tween(begin: 1.0, end: 0.92).animate(
              CurvedAnimation(parent: _sendAnim, curve: Curves.easeInOut)),
          child: GestureDetector(
            onTap: _isSending ? null : _sendMessage,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 50, height: 50,
              decoration: BoxDecoration(
                gradient: _isSending ? null : AppTheme.accentGradient,
                color: _isSending ? AppTheme.textSec.withOpacity(0.3) : null,
                shape: BoxShape.circle,
                boxShadow: _isSending ? [] :
                    [BoxShadow(color: AppTheme.purple.withOpacity(0.5), blurRadius: 14)],
              ),
              child: Center(child: _isSending
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, color: Colors.white, size: 20)),
            ),
          ),
        ),
      ],
    )),
  );

  Widget _avatar(String name) => Container(
    width: 36, height: 36,
    decoration: BoxDecoration(
      gradient: AppTheme.accentGradient,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Center(child: Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
    )),
  );
}

class _Msg {
  final String text;
  final bool isMe;
  final DateTime timestamp;
  final String? senderId;
  final String? relayedBy;
  final int hopCount;

  _Msg({required this.text, required this.isMe, required this.timestamp,
      this.senderId, this.relayedBy, this.hopCount = 0});

  factory _Msg.fromChat(ChatMessage m) => _Msg(
    text: m.text, isMe: m.isMe, timestamp: m.timestamp, relayedBy: m.relayedBy);
}