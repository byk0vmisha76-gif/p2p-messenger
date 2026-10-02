import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'session.dart';

class Api {
  static const _timeout = Duration(seconds: 15);

  static Future<Session> register(String name) async {
    final r = await http
        .post(
          Uri.parse('${ServerConfig.url}/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name}),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) throw Exception('register failed: ${r.statusCode}');
    final d = jsonDecode(r.body) as Map<String, dynamic>;
    return Session(
      number: d['number'] as String,
      name: d['name'] as String,
      token: d['token'] as String,
    );
  }

  /// null, если такого номера нет. Бросает исключение, если нет связи.
  static Future<Contact?> lookup(String number) async {
    final r = await http.get(Uri.parse('${ServerConfig.url}/user/$number')).timeout(_timeout);
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw Exception('lookup failed: ${r.statusCode}');
    final p = (jsonDecode(r.body) as Map<String, dynamic>)['profile'] as Map<String, dynamic>;
    return Contact(number: p['number'] as String, name: p['name'] as String);
  }
}
