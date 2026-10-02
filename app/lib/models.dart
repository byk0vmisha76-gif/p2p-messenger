class Contact {
  const Contact({required this.number, required this.name});
  final String number;
  final String name;
}

class Msg {
  const Msg({
    required this.id,
    required this.peer,
    required this.mine,
    required this.text,
    required this.ts,
    required this.status,
  });

  final String id;
  final String peer; // номер собеседника
  final bool mine;
  final String text;
  final int ts; // миллисекунды
  /// sending (ещё не ушло) | stored (на сервере, получатель офлайн) |
  /// relayed (доставлено получателю) | failed | received (входящее)
  final String status;

  Map<String, Object?> toMap() => {
        'id': id,
        'peer': peer,
        'mine': mine ? 1 : 0,
        'text': text,
        'ts': ts,
        'status': status,
      };

  static Msg fromMap(Map<String, Object?> r) => Msg(
        id: r['id'] as String,
        peer: r['peer'] as String,
        mine: (r['mine'] as int) == 1,
        text: r['text'] as String,
        ts: r['ts'] as int,
        status: r['status'] as String,
      );
}

class ChatPreview {
  const ChatPreview(this.contact, this.last);
  final Contact contact;
  final Msg? last;
}
