import 'dart:io';

/// Сколько дней хранить сообщения на телефоне/компьютере. Старше удаляются автоматически.
const int kKeepDays = 7;

/// Адрес сервера. Вводится на экране регистрации и запоминается.
/// Значение по умолчанию можно задать при сборке: --dart-define=API_URL=https://...
class ServerConfig {
  static const String _env = String.fromEnvironment('API_URL');

  /// true, если адрес сервера вшит в сборку (--dart-define=API_URL=...)
  static bool get hasDefault => _env.isNotEmpty;

  static String get defaultUrl {
    if (_env.isNotEmpty) return _env;
    // 10.0.2.2 = «компьютер» из эмулятора Android; на ПК — localhost
    return Platform.isAndroid ? 'http://10.0.2.2:8787' : 'http://127.0.0.1:8787';
  }

  static String url = defaultUrl;

  /// http -> ws, https -> wss
  static String get ws => url.replaceFirst('http', 'ws');

  /// "my.workers.dev/" -> "https://my.workers.dev"; локальные адреса остаются http.
  static String normalize(String input) {
    var v = input.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    if (v.isEmpty) return v;
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      final local = RegExp(r'^(localhost|127\.|10\.|192\.168\.)').hasMatch(v);
      v = '${local ? 'http' : 'https'}://$v';
    }
    return v;
  }
}
