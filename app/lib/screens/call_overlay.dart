import 'dart:io';

import 'package:flutter/material.dart';

import '../call.dart';

/// Показывается поверх любого экрана: входящий звонок, идущий звонок, короткие сообщения.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key, required this.call});
  final CallController call;

  static String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  String _status() => switch (call.state) {
        CallState.outgoing => 'Вызов…',
        CallState.incoming => 'Входящий звонок',
        CallState.connecting => 'Соединение…',
        CallState.active => _fmt(call.seconds),
        CallState.idle => '',
      };

  Widget _round(IconData icon, Color bg, Color fg, VoidCallback onTap, String tooltip) {
    // без tooltip: этот слой находится выше Navigator, там нет Overlay для подсказок
    return FloatingActionButton(
      heroTag: null,
      backgroundColor: bg,
      foregroundColor: fg,
      elevation: 0,
      onPressed: onTap,
      child: Icon(icon),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: call,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;

        if (call.state == CallState.idle) {
          if (call.notice == null) return const SizedBox.shrink();
          return IgnorePointer(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Material(
                    elevation: 4,
                    color: cs.inverseSurface,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Text(call.notice!, style: TextStyle(color: cs.onInverseSurface)),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        final incoming = call.state == CallState.incoming;
        final name = call.peerName.isEmpty ? '?' : call.peerName;
        return Material(
          color: cs.surface,
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                CircleAvatar(
                  radius: 56,
                  child: Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 44)),
                ),
                const SizedBox(height: 24),
                Text(name, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text(call.peer ?? '', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 14),
                Text(_status(), style: Theme.of(context).textTheme.titleLarge),
                const Spacer(flex: 3),
                if (incoming)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _round(Icons.call_end, Colors.red, Colors.white, () => call.hangup(reason: 'decline'), 'Отклонить'),
                      _round(Icons.call, Colors.green, Colors.white, call.accept, 'Ответить'),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _round(
                        call.muted ? Icons.mic_off : Icons.mic,
                        call.muted ? cs.primary : cs.surfaceContainerHighest,
                        call.muted ? cs.onPrimary : cs.onSurface,
                        call.toggleMute,
                        call.muted ? 'Включить микрофон' : 'Выключить микрофон',
                      ),
                      _round(Icons.call_end, Colors.red, Colors.white, () => call.hangup(), 'Завершить'),
                      if (Platform.isAndroid)
                        _round(
                          call.speaker ? Icons.volume_up : Icons.volume_down,
                          call.speaker ? cs.primary : cs.surfaceContainerHighest,
                          call.speaker ? cs.onPrimary : cs.onSurface,
                          call.toggleSpeaker,
                          'Громкая связь',
                        ),
                    ],
                  ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        );
      },
    );
  }
}
