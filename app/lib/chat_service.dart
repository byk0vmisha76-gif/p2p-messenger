import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'session.dart';

enum Conn { offline, connecting, online, replaced }

/// Держит WebSocket с сервером, принимает/отправляет сообщения, пишет всё в локальную базу.
/// UI подписывается через addListener и перечитывает базу.
class ChatService extends ChangeNotifier {
  ChatService(this.session);

  final Session session;
  final LocalDb _db = LocalDb.instance;

  Conn state = Conn.offline;
  WebSocket? _ws;
  Timer? _ping;
  Timer? _retry;
  int _attempt = 0;
  bool _disposed = false;
  DateTime _lastRx = DateTime.now();

  // ---------- соединение ----------

  Future<void> connect() async {
    if (_disposed || state == Conn.connecting || state == Conn.online) return;
    _retry?.cancel();
    _setState(Conn.connecting);
    try {
      final ws = await WebSocket.connect(
        '${ServerConfig.ws}/ws?number=${session.number}',
        headers: {'Authorization': 'Bearer ${session.token}'},
      ).timeout(const Duration(seconds: 10));
      if (_disposed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _attempt = 0;
      _lastRx = DateTime.now();
      ws.listen(
        _onData,
        onDone: () => _onClosed(ws),
        onError: (_) => _onClosed(ws),
        cancelOnError: true,
      );
      _ping = Timer.periodic(const Duration(seconds: 25), (_) => _tick());
      _setState(Conn.online);
      await _resendPending();
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _tick() {
    final ws = _ws;
    if (ws == null) return;
    // сервер молчит больше ~минуты (нет даже pong) -> соединение мёртвое
    if (DateTime.now().difference(_lastRx) > const Duration(seconds: 65)) {
      ws.close();
      _onClosed(ws);
      return;
    }
    _raw('ping');
  }

  void _onClosed(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ping?.cancel();
    _ws = null;
    if (ws.closeCode == 4000) {
      // этот аккаунт открыли на другом устройстве; не воюем за соединение
      _setState(Conn.replaced);
      return;
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    final secs = min(30, 1 << min(_attempt, 5));
    _attempt++;
    _setState(Conn.offline);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: secs), connect);
  }

  void _setState(Conn c) {
    state = c;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  bool _raw(String s) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- входящее ----------

  Future<void> _onData(dynamic data) async {
    _lastRx = DateTime.now();
    if (data is! String || data == 'pong') return;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    try {
      switch (m['type']) {
        case 'message':
          await _onIncoming(m);
        case 'sent':
          await _db.setStatus(m['id'] as String, m['status'] == 'relayed' ? 'relayed' : 'stored');
          _changed();
        case 'error':
          final id = m['id'];
          if (id is String) {
            await _db.setStatus(id, 'failed');
            _changed();
          }
      }
    } catch (_) {
      // не смогли сохранить -> не подтверждаем, сервер пришлёт ещё раз
    }
  }

  Future<void> _onIncoming(Map<String, dynamic> m) async {
    final id = m['id'] as String;
    final from = m['from'] as String;
    final isNew = await _db.insertMessage(Msg(
      id: id,
      peer: from,
      mine: false,
      text: m['text'] as String,
      ts: (m['ts'] as num).toInt(),
      status: 'received',
    ));
    if (isNew && await _db.getContact(from) == null) {
      Contact? c;
      try {
        c = await Api.lookup(from);
      } catch (_) {}
      await _db.upsertContact(c ?? Contact(number: from, name: from));
    }
    // Сохранили у себя -> сервер может удалить копию из очереди
    _raw(jsonEncode({'type': 'ack', 'ids': [id]}));
    _changed();
  }

  // ---------- исходящее ----------

  Future<void> send(String to, String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final msg = Msg(
      id: const Uuid().v4(),
      peer: to,
      mine: true,
      text: t,
      ts: DateTime.now().millisecondsSinceEpoch,
      status: 'sending',
    );
    await _db.insertMessage(msg);
    _changed();
    _transmit(msg); // если офлайн, останется 'sending' и уйдёт при подключении
  }

  bool _transmit(Msg m) =>
      _raw(jsonEncode({'type': 'message', 'id': m.id, 'to': m.peer, 'text': m.text}));

  Future<void> _resendPending() async {
    for (final m in await _db.pendingOutgoing()) {
      _transmit(m); // id тот же: дубли отсекаются и сервером, и получателем
    }
  }

  // ---------- автоудаление ----------

  Future<void> cleanup() async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - kKeepDays * 24 * 60 * 60 * 1000;
    if (await _db.deleteOlderThan(cutoff) > 0) _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _ping?.cancel();
    _retry?.cancel();
    _ws?.close();
    super.dispose();
  }
}
