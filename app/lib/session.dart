import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config.dart';

class Session {
  const Session({required this.number, required this.name, required this.token});
  final String number;
  final String name;
  final String token; // секрет: хранится только в защищённом хранилище
}

class SessionStore {
  static const _s = FlutterSecureStorage();

  /// Заодно восстанавливает адрес сервера, с которым создан аккаунт.
  static Future<Session?> load() async {
    final url = await _s.read(key: 'server_url');
    if (url != null && url.isNotEmpty) ServerConfig.url = url;
    final number = await _s.read(key: 'number');
    final name = await _s.read(key: 'name');
    final token = await _s.read(key: 'token');
    if (number == null || name == null || token == null) return null;
    return Session(number: number, name: name, token: token);
  }

  static Future<void> save(Session s) async {
    await _s.write(key: 'server_url', value: ServerConfig.url);
    await _s.write(key: 'number', value: s.number);
    await _s.write(key: 'name', value: s.name);
    await _s.write(key: 'token', value: s.token);
  }

  static Future<void> clear() => _s.deleteAll();
}
