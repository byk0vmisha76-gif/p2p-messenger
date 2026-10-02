import 'package:flutter/material.dart';

import '../api.dart';
import '../config.dart';
import '../session.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.onDone});
  final Future<void> Function(Session) onDone;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController(text: ServerConfig.url);
  bool _busy = false;
  bool _showServer = !ServerConfig.hasDefault; // при вшитом адресе поле спрятано
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final url = ServerConfig.normalize(_url.text);
    if (url.isEmpty) {
      setState(() => _error = 'Укажите адрес сервера');
      return;
    }
    ServerConfig.url = url;
    _url.text = url;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await Api.register(_name.text.trim());
      await widget.onDone(s); // дальше экран заменится, setState не нужен
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Не удалось связаться с сервером. Проверьте интернет и адрес сервера.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Добро пожаловать', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  const Text('Придумайте имя. Номер для связи вам выдаст сервер.'),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Ваше имя', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  if (!_showServer)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _showServer = true),
                        child: const Text('Настройки сервера'),
                      ),
                    ),
                  if (_showServer)
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Адрес сервера',
                      helperText: 'Например: https://p2p-messenger.имя.workers.dev',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _busy ? null : _go(),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _go,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Создать аккаунт'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
