import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import 'chat_service.dart';
import 'db.dart';
import 'models.dart';

enum CallState { idle, outgoing, incoming, connecting, active }

/// Голосовой звонок поверх WebRTC. Через наш сервер идут только сигналы
/// (кто кому звонит, SDP, ICE); сам звук идёт напрямую между устройствами
/// или через ретранслятор TURN, если прямой связи нет.
class CallController extends ChangeNotifier {
  CallController(this.chat) {
    _sub = chat.signals.listen(_onSignal);
  }

  final ChatService chat;
  late final StreamSubscription<Map<String, dynamic>> _sub;

  CallState state = CallState.idle;
  String? peer; // номер собеседника
  String peerName = '';
  bool muted = false;
  bool speaker = false;
  int seconds = 0;

  /// Короткая подпись под экраном после завершения («Нет ответа», «Занято»…)
  String? notice;

  String? _callId;
  String? _offerSdp;
  RTCPeerConnection? _pc;
  MediaStream? _local;
  final List<RTCIceCandidate> _early = [];
  bool _remoteSet = false;
  bool _disposed = false;
  Timer? _ringTimer, _tick, _lostTimer, _noticeTimer, _vibe;

  // ---------- действия пользователя ----------

  Future<void> start(String number) async {
    if (state != CallState.idle) return;
    if (chat.state != Conn.online) {
      _flash('Нет соединения с сервером');
      return;
    }
    final c = await LocalDb.instance.getContact(number);
    _begin(number, c?.name ?? number, const Uuid().v4(), CallState.outgoing);
    try {
      await _openPeer();
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      chat.sendSignal({'type': 'call-offer', 'to': number, 'callId': _callId, 'sdp': offer.sdp});
      _ringTimer = Timer(const Duration(seconds: 45), () => hangup(reason: 'no_answer'));
    } catch (_) {
      await _finish('Не удалось начать звонок (проверьте доступ к микрофону)');
    }
  }

  Future<void> accept() async {
    if (state != CallState.incoming || _offerSdp == null) return;
    _ringTimer?.cancel();
    _stopVibration();
    state = CallState.connecting;
    _notify();
    try {
      await _openPeer();
      await _pc!.setRemoteDescription(RTCSessionDescription(_offerSdp, 'offer'));
      await _flushEarly();
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      chat.sendSignal({'type': 'call-answer', 'to': peer, 'callId': _callId, 'sdp': answer.sdp});
    } catch (_) {
      await hangup(reason: 'error');
    }
  }

  Future<void> hangup({String reason = 'hangup'}) async {
    if (state == CallState.idle) return;
    final to = peer;
    final id = _callId;
    final missed = state == CallState.incoming && reason == 'no_answer';
    if (to != null && id != null) {
      chat.sendSignal({'type': 'call-end', 'to': to, 'callId': id, 'reason': reason});
    }
    await _finish(_noticeFor(reason, remote: false), missed: missed);
  }

  void toggleMute() {
    muted = !muted;
    for (final t in _local?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    _notify();
  }

  void toggleSpeaker() {
    speaker = !speaker;
    _applySpeaker();
    _notify();
  }

  // ---------- сигналы от сервера ----------

  Future<void> _onSignal(Map<String, dynamic> m) async {
    try {
      final from = m['from'] as String?;
      final id = m['callId'] as String?;
      switch (m['type']) {
        case 'call-offer':
          {
            if (from == null || id == null || m['sdp'] is! String) return;
            if (state != CallState.idle) {
              chat.sendSignal({'type': 'call-end', 'to': from, 'callId': id, 'reason': 'busy'});
              return;
            }
            final c = await LocalDb.instance.getContact(from);
            _offerSdp = m['sdp'] as String;
            _begin(from, c?.name ?? from, id, CallState.incoming);
          }
        case 'call-answer':
          {
            if (id != _callId || state != CallState.outgoing || m['sdp'] is! String) return;
            _ringTimer?.cancel();
            state = CallState.connecting;
            _notify();
            await _pc!.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, 'answer'));
            await _flushEarly();
          }
        case 'ice-candidate':
          {
            if (id == null || id != _callId) return;
            final c = m['candidate'];
            if (c is! Map) return;
            final cand = RTCIceCandidate(
              c['candidate'] as String?,
              c['sdpMid'] as String?,
              c['sdpMLineIndex'] as int?,
            );
            if (_remoteSet && _pc != null) {
              await _pc!.addCandidate(cand);
            } else {
              _early.add(cand);
            }
          }
        case 'call-end':
          {
            if (id == null || id != _callId || state == CallState.idle) return;
            final missed = state == CallState.incoming;
            await _finish(
              missed ? 'Пропущенный звонок' : _noticeFor(m['reason'] as String?, remote: true),
              missed: missed,
            );
          }
        case 'call-unavailable':
          {
            if (m['callId'] != _callId || state != CallState.outgoing) return;
            await _finish('Абонент не в сети');
          }
      }
    } catch (_) {
      // повреждённый сигнал не должен ронять приложение
    }
  }

  // ---------- внутреннее ----------

  void _begin(String number, String name, String id, CallState s) {
    _noticeTimer?.cancel();
    notice = null;
    peer = number;
    peerName = name;
    _callId = id;
    state = s;
    muted = false;
    speaker = false;
    seconds = 0;
    _early.clear();
    _remoteSet = false;
    if (s == CallState.incoming) {
      HapticFeedback.vibrate();
      _vibe = Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.vibrate());
      _ringTimer = Timer(const Duration(seconds: 50), () => hangup(reason: 'no_answer'));
    }
    _notify();
  }

  Future<void> _openPeer() async {
    final servers = await chat.iceServers();
    _local = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final pc = await createPeerConnection({'iceServers': servers, 'sdpSemantics': 'unified-plan'});
    _pc = pc;
    for (final t in _local!.getAudioTracks()) {
      await pc.addTrack(t, _local!);
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      final to = peer;
      final id = _callId;
      if (c.candidate == null || to == null || id == null) return;
      chat.sendSignal({
        'type': 'ice-candidate',
        'to': to,
        'callId': id,
        'candidate': {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex},
      });
    };
    pc.onIceConnectionState = _onIce;
  }

  void _onIce(RTCIceConnectionState s) {
    switch (s) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _lostTimer?.cancel();
        if (state == CallState.connecting) _activate();
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        _lostTimer?.cancel();
        _lostTimer = Timer(const Duration(seconds: 10), () => hangup(reason: 'lost'));
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        hangup(reason: 'lost');
      default:
        break;
    }
  }

  void _activate() {
    _ringTimer?.cancel();
    state = CallState.active;
    seconds = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      seconds++;
      _notify();
    });
    _applySpeaker();
    _notify();
  }

  Future<void> _flushEarly() async {
    _remoteSet = true;
    final list = List<RTCIceCandidate>.from(_early);
    _early.clear();
    for (final c in list) {
      await _pc?.addCandidate(c);
    }
  }

  void _applySpeaker() {
    if (Platform.isAndroid) {
      Helper.setSpeakerphoneOn(speaker).catchError((_) {});
    }
  }

  String? _noticeFor(String? reason, {required bool remote}) {
    switch (reason) {
      case 'decline':
        return remote ? 'Вызов отклонён' : null;
      case 'busy':
        return 'Абонент занят';
      case 'no_answer':
        return remote ? null : 'Нет ответа';
      case 'lost':
        return 'Связь потеряна';
      case 'error':
        return 'Ошибка звонка';
      default:
        return remote ? 'Звонок завершён' : null;
    }
  }

  Future<void> _finish(String? text, {bool missed = false}) async {
    final p = peer;
    _ringTimer?.cancel();
    _tick?.cancel();
    _lostTimer?.cancel();
    _stopVibration();
    final pc = _pc;
    final local = _local;
    _pc = null;
    _local = null;
    state = CallState.idle;
    peer = null;
    _callId = null;
    _offerSdp = null;
    _early.clear();
    _remoteSet = false;
    muted = false;
    speaker = false;
    seconds = 0;
    if (text != null) {
      _flash(text);
    } else {
      _notify();
    }
    if (missed && p != null) {
      try {
        await LocalDb.instance.insertMessage(Msg(
          id: const Uuid().v4(),
          peer: p,
          mine: false,
          text: '📞 Пропущенный звонок',
          ts: DateTime.now().millisecondsSinceEpoch,
          status: 'received',
        ));
        chat.refreshUi();
      } catch (_) {}
    }
    try {
      for (final t in local?.getTracks() ?? <MediaStreamTrack>[]) {
        await t.stop();
      }
      await local?.dispose();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
  }

  void _flash(String text) {
    notice = text;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      notice = null;
      _notify();
    });
    _notify();
  }

  void _stopVibration() {
    _vibe?.cancel();
    _vibe = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub.cancel();
    _ringTimer?.cancel();
    _tick?.cancel();
    _lostTimer?.cancel();
    _noticeTimer?.cancel();
    _stopVibration();
    try {
      _pc?.close();
      for (final t in _local?.getTracks() ?? <MediaStreamTrack>[]) {
        t.stop();
      }
      _local?.dispose();
    } catch (_) {}
    super.dispose();
  }
}
