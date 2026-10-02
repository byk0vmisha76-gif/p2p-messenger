// Запуск (после `flutter create`): dart run tool/patch_android.dart
// Добавляет разрешение INTERNET и разрешает http://10.0.2.2 только в debug-сборке.
import 'dart:io';

void main() {
  final main = File('android/app/src/main/AndroidManifest.xml');
  if (!main.existsSync()) {
    stderr.writeln('Не нашёл android/. Сначала: flutter create --project-name messenger --platforms=android .');
    exit(1);
  }
  var s = main.readAsStringSync();
  if (!s.contains('android.permission.INTERNET')) {
    s = s.replaceFirst('<application',
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application');
    main.writeAsStringSync(s);
  }
  final debug = File('android/app/src/debug/AndroidManifest.xml');
  debug.parent.createSync(recursive: true);
  debug.writeAsStringSync('''<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:usesCleartextTraffic="true"/>
</manifest>
''');
  stdout.writeln('Готово: android-манифесты обновлены.');
}
