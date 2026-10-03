import 'dart:async';

import 'package:flutter/material.dart';

import 'call.dart';
import 'chat_service.dart';
import 'db.dart';
import 'screens/call_overlay.dart';
import 'screens/chats_screen.dart';
import 'screens/register_screen.dart';
import 'session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalDb.instance.open();
  runApp(App(initial: await SessionStore.load()));
}

class App extends StatefulWidget {
  const App({super.key, required this.initial});
  final Session? initial;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  Session? _session;
  ChatService? _service;
  CallController? _call;
  Timer? _cleanupTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.initial;
    if (_session != null) _start(_session!);
  }

  void _start(Session s) {
    final svc = ChatService(s);
    _service = svc;
    _call = CallController(svc);
    svc.cleanup();
    svc.connect();
    _cleanupTimer = Timer.periodic(const Duration(hours: 1), (_) => svc.cleanup());
  }

  Future<void> _onRegistered(Session s) async {
    await SessionStore.save(s);
    if (!mounted) return;
    setState(() {
      _session = s;
      _start(s);
    });
  }

  /// Выход: закрываем соединение, стираем аккаунт и историю на этом устройстве.
  Future<void> _logout() async {
    _cleanupTimer?.cancel();
    _call?.dispose();
    _call = null;
    _service?.dispose();
    _service = null;
    await SessionStore.clear();
    await LocalDb.instance.wipe();
    if (!mounted) return;
    setState(() => _session = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _service?.cleanup();
      _service?.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cleanupTimer?.cancel();
    _call?.dispose();
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Мессенджер',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child ?? const SizedBox.shrink(),
          if (_call != null) Positioned.fill(child: CallOverlay(call: _call!)),
        ],
      ),
      home: _session == null
          ? RegisterScreen(onDone: _onRegistered)
          : ChatsScreen(service: _service!, call: _call!, onLogout: _logout),
    );
  }
}
