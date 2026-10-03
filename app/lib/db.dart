import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi, sqfliteFfiInit;

import 'models.dart';

/// Локальная база на телефоне: контакты и вся история переписки.
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();

  late final Database _db;

  Future<void> open() async {
    final DatabaseFactory factory;
    final String dir;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      factory = databaseFactoryFfi;
      dir = (await getApplicationSupportDirectory()).path;
    } else {
      factory = databaseFactory; // Android: обычный sqflite
      dir = await getDatabasesPath();
    }
    _db = await factory.openDatabase(
      p.join(dir, 'messenger.db'),
      options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE contacts (number TEXT PRIMARY KEY, name TEXT NOT NULL)');
        await db.execute('''CREATE TABLE messages (
          id TEXT PRIMARY KEY, peer TEXT NOT NULL, mine INTEGER NOT NULL,
          text TEXT NOT NULL, ts INTEGER NOT NULL, status TEXT NOT NULL)''');
        await db.execute('CREATE INDEX idx_messages_peer_ts ON messages (peer, ts)');
      },
      ),
    );
  }

  Future<void> upsertContact(Contact c) => _db.insert(
        'contacts',
        {'number': c.number, 'name': c.name},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<Contact?> getContact(String number) async {
    final r = await _db.query('contacts', where: 'number = ?', whereArgs: [number]);
    if (r.isEmpty) return null;
    return Contact(number: r.first['number'] as String, name: r.first['name'] as String);
  }

  /// false, если сообщение с таким id уже есть (защита от дублей после переподключений).
  Future<bool> insertMessage(Msg m) async {
    final exists = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM messages WHERE id = ?', [m.id])) ??
        0;
    if (exists > 0) return false;
    await _db.insert('messages', m.toMap(), conflictAlgorithm: ConflictAlgorithm.ignore);
    return true;
  }

  Future<void> setStatus(String id, String status) => _db.update(
        'messages',
        {'status': status},
        // «на сервере» не должно затирать уже полученное «доставлено»
        where: status == 'stored'
            ? "id = ? AND mine = 1 AND status IN ('sending', 'stored')"
            : 'id = ? AND mine = 1',
        whereArgs: [id],
      );

  Future<List<Msg>> messagesWith(String peer) async {
    final rows = await _db.query('messages', where: 'peer = ?', whereArgs: [peer], orderBy: 'ts ASC');
    return rows.map(Msg.fromMap).toList();
  }

  Future<List<Msg>> pendingOutgoing() async {
    final rows = await _db.query('messages', where: "mine = 1 AND status = 'sending'", orderBy: 'ts ASC');
    return rows.map(Msg.fromMap).toList();
  }

  /// Свои сообщения, которые лежат на сервере и ждут получателя.
  Future<List<Msg>> storedOutgoing() async {
    final rows = await _db.query('messages',
        where: "mine = 1 AND status = 'stored'", orderBy: 'ts ASC', limit: 100);
    return rows.map(Msg.fromMap).toList();
  }

  Future<List<ChatPreview>> chats() async {
    final rows = await _db.rawQuery('''
      SELECT c.number, c.name, m.id, m.mine, m.text, m.ts, m.status
      FROM contacts c
      LEFT JOIN messages m ON m.id =
        (SELECT id FROM messages WHERE peer = c.number ORDER BY ts DESC LIMIT 1)
      ORDER BY COALESCE(m.ts, 0) DESC, c.name''');
    return rows.map((r) {
      final c = Contact(number: r['number'] as String, name: r['name'] as String);
      final id = r['id'] as String?;
      final last = id == null
          ? null
          : Msg(
              id: id,
              peer: c.number,
              mine: (r['mine'] as int) == 1,
              text: r['text'] as String,
              ts: r['ts'] as int,
              status: r['status'] as String,
            );
      return ChatPreview(c, last);
    }).toList();
  }

  /// Полная очистка (выход из аккаунта).
  Future<void> wipe() async {
    await _db.delete('messages');
    await _db.delete('contacts');
  }

  /// Удаляет сообщения старше cutoff (мс). Возвращает, сколько удалено.
  Future<int> deleteOlderThan(int cutoff) =>
      _db.delete('messages', where: 'ts < ?', whereArgs: [cutoff]);
}
