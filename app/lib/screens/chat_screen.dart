import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat_service.dart';
import '../config.dart';
import '../db.dart';
import '../models.dart';
import '../util.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.service, required this.contact});
  final ChatService service;
  final Contact contact;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  List<Msg> _msgs = [];

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.service.removeListener(_reload);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final m = await LocalDb.instance.messagesWith(widget.contact.number);
    if (mounted) setState(() => _msgs = m);
  }

  Future<void> _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    await widget.service.send(widget.contact.number, t);
  }

  static final bool _desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// На ПК: Enter отправляет, Shift+Enter — новая строка.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_desktop &&
        e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _statusIcon(String status, ColorScheme cs) {
    const size = 14.0;
    return switch (status) {
      'sending' => Icon(Icons.schedule, size: size, color: cs.outline),
      'stored' => Icon(Icons.check, size: size, color: cs.outline),
      'relayed' => Icon(Icons.done_all, size: size, color: cs.primary),
      'failed' => Icon(Icons.error_outline, size: size, color: cs.error),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _bubble(BuildContext context, Msg m) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: min(MediaQuery.of(context).size.width * 0.78, 520.0)),
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: m.mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(m.text),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fmtTime(m.ts), style: TextStyle(fontSize: 11, color: cs.outline)),
                if (m.mine) ...[const SizedBox(width: 4), _statusIcon(m.status, cs)],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.contact.name),
            Text(widget.contact.number, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: Text(
              'Сообщения хранятся на этом телефоне $kKeepDays дней',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              itemCount: _msgs.length,
              itemBuilder: (ctx, i) => _bubble(ctx, _msgs[_msgs.length - 1 - i]),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [LengthLimitingTextInputFormatter(4000)],
                      decoration: const InputDecoration(
                        hintText: 'Сообщение',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    ),
                  ),
                  IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
