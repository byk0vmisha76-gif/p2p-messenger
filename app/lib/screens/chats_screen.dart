import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../chat_service.dart';
import '../config.dart';
import '../db.dart';
import '../models.dart';
import '../util.dart';
import 'chat_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, required this.service, required this.onLogout});
  final ChatService service;
  final Future<void> Function() onLogout;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<ChatPreview> _chats = [];

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.service.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final c = await LocalDb.instance.chats();
    if (mounted) setState(() => _chats = c);
  }

  String get _stateText => switch (widget.service.state) {
        Conn.online => 'в сети',
        Conn.connecting => 'подключение…',
        Conn.offline => 'нет соединения',
        Conn.replaced => 'открыто на другом устройстве',
      };

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openChat(Contact c) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(service: widget.service, contact: c)),
      );

  Future<void> _addContact() async {
    final number = await showDialog<String>(context: context, builder: (_) => const _NumberDialog());
    if (number == null) return;
    if (number == widget.service.session.number) {
      _snack('Это ваш собственный номер');
      return;
    }
    try {
      final c = await Api.lookup(number);
      if (c == null) {
        _snack('Пользователь с таким номером не найден');
        return;
      }
      await LocalDb.instance.upsertContact(c);
      await _reload();
      if (mounted) await _openChat(c);
    } catch (_) {
      _snack('Нет связи с сервером');
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Аккаунт и вся переписка будут удалены с этого устройства. '
          'Вернуться в тот же номер будет нельзя.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok == true) await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.service.session;
    final st = widget.service.state;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Чаты'),
            Text(_stateText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          if (st == Conn.offline || st == Conn.replaced)
            IconButton(
              tooltip: 'Подключиться',
              icon: const Icon(Icons.refresh),
              onPressed: widget.service.connect,
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _confirmLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('Выйти и удалить данные')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContact,
        tooltip: 'Новый чат',
        child: const Icon(Icons.person_add_alt_1),
      ),
      body: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text('Ваш номер: ${me.number}'),
            subtitle: Text('${me.name} · ${Uri.parse(ServerConfig.url).host} · $kAppVersion'),
            trailing: IconButton(
              tooltip: 'Скопировать номер',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: me.number));
                _snack('Номер скопирован');
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _chats.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Пока нет чатов.\nНажмите кнопку справа внизу и введите номер друга.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _chats.length,
                    itemBuilder: (_, i) {
                      final p = _chats[i];
                      final last = p.last;
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(p.contact.name.isEmpty ? '?' : p.contact.name[0].toUpperCase()),
                        ),
                        title: Text(p.contact.name),
                        subtitle: Text(
                          last == null ? 'Нет сообщений' : '${last.mine ? 'Вы: ' : ''}${last.text}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: last == null ? null : Text(fmtTime(last.ts), style: Theme.of(context).textTheme.bodySmall),
                        onTap: () => _openChat(p.contact),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog();

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _ctrl.text.trim();
    if (v.length == 8) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый чат'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
        decoration: const InputDecoration(labelText: 'Номер (8 цифр)'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
        FilledButton(onPressed: _submit, child: const Text('Найти')),
      ],
    );
  }
}
