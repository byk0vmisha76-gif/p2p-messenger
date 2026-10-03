// Mailbox — Durable Object: один "почтовый ящик" на каждого пользователя.
// Хранит профиль (номер, имя, хэш токена) и очередь сообщений, ПОКА получатель офлайн.
// Если получатель онлайн, сообщение просто пересылается в его сокет и нигде не пишется.
import { DurableObject } from 'cloudflare:workers';

const MAX_TEXT = 4000;                         // символов в сообщении
const MAX_QUEUE = 500;                         // сообщений в очереди на одного человека
const QUEUE_TTL_MS = 14 * 24 * 60 * 60 * 1000; // недоставленное удаляется через 14 дней
const ACK_TIMEOUT_MS = 6000;                   // ждём подтверждение от онлайн-получателя
const MAX_TS_AGE_MS = 3 * 24 * 60 * 60 * 1000; // время создания от клиента принимаем не старше 3 дней
const MAX_SIGNAL_BYTES = 16 * 1024;
const SIGNAL_TYPES = new Set(['call-offer', 'call-answer', 'ice-candidate', 'call-end']);
const OPEN = 1; // WebSocket.READY_STATE_OPEN

export const NUMBER_RE = /^[1-9]\d{7}$/;

export class Mailbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.pending = new Map(); // id сообщения -> функция, будящая deliver() после ack (только в памяти)
    this.sql.exec(`CREATE TABLE IF NOT EXISTS profile (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      number TEXT NOT NULL, name TEXT NOT NULL,
      token_hash TEXT NOT NULL, created_at INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS queue (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT NOT NULL UNIQUE, sender TEXT NOT NULL,
      text TEXT NOT NULL, ts INTEGER NOT NULL)`);
    // "ping" от клиента -> "pong" без пробуждения объекта (дёшево, держит соединение живым)
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  // ---------- вызывается из Worker (RPC) ----------

  /** Создаёт профиль. false, если такой номер уже занят. */
  async init(number, name, token) {
    if (this.#profile()) return false;
    this.sql.exec(
      'INSERT INTO profile (id, number, name, token_hash, created_at) VALUES (1, ?, ?, ?, ?)',
      number, name, await sha256Hex(token), Date.now());
    return true;
  }

  /** Проверка токена (для выдачи ICE-серверов). */
  async verify(token) {
    const p = this.#profile();
    return !!p && typeof token === 'string' && token.length > 0 && safeEqual(await sha256Hex(token), p.token_hash);
  }

  async publicProfile() {
    const p = this.#profile();
    return p ? { number: p.number, name: p.name } : null;
  }

  // ---------- вызывается из Mailbox отправителя (RPC) ----------

  /**
   * Доставка сообщения этому пользователю.
   * Онлайн: отправляем в сокет и ждём ack. Нет ack за ACK_TIMEOUT_MS (соединение "мёртвое") -> в очередь.
   * Офлайн: сразу в очередь. Возвращает 'delivered' | 'stored' | 'queue_full' | 'not_found'.
   */
  async deliver(msg) {
    if (!this.#profile()) return 'not_found';
    for (const ws of this.#openSockets()) {
      try { ws.send(JSON.stringify({ type: 'message', ...msg })); } catch { continue; }
      if (await this.#waitAck(msg.id)) return 'delivered';
      break; // подтверждения нет -> считаем, что сообщение не дошло
    }
    const status = await this.#store(msg);
    if (status === 'stored') {
      // за время ожидания получатель мог переподключиться: отдаём сразу, а не ждём следующего подключения
      for (const ws of this.#openSockets()) {
        try { ws.send(JSON.stringify({ type: 'message', ...msg, queued: true })); break; } catch {}
      }
    }
    return status;
  }

  /** Лежит ли ещё в очереди сообщение от этого отправителя (для проверки статуса). */
  async hasQueued(id, sender) {
    return this.sql.exec('SELECT 1 FROM queue WHERE id = ? AND sender = ?', id, sender).toArray().length > 0;
  }

  /** Уведомление отправителю: его сообщение, лежавшее в очереди, получено. Не хранится. */
  async receipt(msg) {
    for (const ws of this.#openSockets()) {
      try { ws.send(JSON.stringify(msg)); return true; } catch {}
    }
    return false;
  }

  /** Сигнализация звонков (WebRTC). Не хранится никогда. */
  async signal(msg) {
    for (const ws of this.#openSockets()) {
      try { ws.send(JSON.stringify(msg)); return true; } catch {}
    }
    return false;
  }

  // ---------- подключение клиента ----------

  async fetch(request) {
    const profile = this.#profile();
    if (!profile) return new Response('not found', { status: 404 });

    const auth = request.headers.get('Authorization') ?? '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!token || !safeEqual(await sha256Hex(token), profile.token_hash)) {
      return new Response('unauthorized', { status: 401 });
    }
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 });
    }

    // одно активное соединение на аккаунт: старое закрываем
    for (const old of this.ctx.getWebSockets()) {
      try { old.close(4000, 'replaced by new connection'); } catch {}
    }

    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server); // hibernation API: объект может "спать", пока сокет молчит
    this.#flush(server);              // отдаём всё, что накопилось, пока был офлайн
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, raw) {
    if (typeof raw !== 'string') return;
    const me = this.#profile()?.number;
    if (!me) return;

    let data;
    try { data = JSON.parse(raw); } catch { return reply(ws, { type: 'error', code: 'bad_json' }); }
    if (!data || typeof data !== 'object') return reply(ws, { type: 'error', code: 'bad_json' });

    if (data.type === 'message') {
      const { id, to, text } = data;
      if (typeof id !== 'string' || id.length < 1 || id.length > 64) return reply(ws, { type: 'error', code: 'bad_id' });
      if (!NUMBER_RE.test(to) || to === me) return reply(ws, { type: 'error', id, code: 'bad_recipient' });
      if (typeof text !== 'string' || !text || text.length > MAX_TEXT) return reply(ws, { type: 'error', id, code: 'bad_text' });

      // "from" ставит сервер, подделать его нельзя. Время создания берём от клиента (чтобы на обоих экранах совпадало)
      const status = await this.#mailbox(to).deliver({ id, from: me, text, ts: cleanTs(data.ts) });
      if (status === 'delivered' || status === 'stored') return reply(ws, { type: 'sent', id, to, status });
      return reply(ws, { type: 'error', id, code: status }); // not_found | queue_full
    }

    if (data.type === 'ack') {
      // клиент сохранил сообщения у себя
      const ids = Array.isArray(data.ids) ? data.ids.slice(0, 200) : [];
      for (const id of ids) {
        if (typeof id !== 'string') continue;
        const done = this.pending.get(id);
        if (done) { done(); continue; } // онлайн-путь: deliver() ждал именно этого
        const row = this.sql.exec('SELECT sender FROM queue WHERE id = ?', id).toArray()[0];
        if (!row) continue;
        this.sql.exec('DELETE FROM queue WHERE id = ?', id);
        // отправитель увидит вторую галочку (если он сейчас онлайн; квитанции не хранятся)
        try { await this.#mailbox(row.sender).receipt({ type: 'delivered', id, to: me }); } catch {}
      }
      return;
    }

    if (data.type === 'check') {
      // отправитель вернулся в сеть и спрашивает: мои «лежащие на сервере» уже получены?
      const items = Array.isArray(data.items) ? data.items.slice(0, 100) : [];
      await Promise.all(items.map(async (it) => {
        if (!it || typeof it.id !== 'string' || !NUMBER_RE.test(it.to) || it.to === me) return;
        let queued = true;
        try { queued = await this.#mailbox(it.to).hasQueued(it.id, me); } catch {}
        if (!queued) reply(ws, { type: 'delivered', id: it.id, to: it.to });
      }));
      return;
    }

    if (SIGNAL_TYPES.has(data.type)) {
      if (raw.length > MAX_SIGNAL_BYTES) return reply(ws, { type: 'error', code: 'too_big' });
      if (!NUMBER_RE.test(data.to) || data.to === me) return reply(ws, { type: 'error', code: 'bad_recipient' });
      const callId = typeof data.callId === 'string' ? data.callId.slice(0, 64) : undefined;
      const reason = typeof data.reason === 'string' ? data.reason.slice(0, 32) : undefined;
      const ok = await this.#mailbox(data.to).signal({
        type: data.type, from: me, callId, reason, sdp: data.sdp, candidate: data.candidate,
      });
      if (!ok && data.type === 'call-offer') reply(ws, { type: 'call-unavailable', to: data.to, callId });
      return;
    }

    reply(ws, { type: 'error', code: 'unknown_type' });
  }

  async webSocketClose(ws) { try { ws.close(); } catch {} }
  async webSocketError() {}

  // Чистка просроченных недоставленных сообщений
  async alarm() {
    this.sql.exec('DELETE FROM queue WHERE ts < ?', Date.now() - QUEUE_TTL_MS);
    const { t } = this.sql.exec('SELECT MIN(ts) AS t FROM queue').one();
    if (t !== null) await this.ctx.storage.setAlarm(Math.max(t + QUEUE_TTL_MS, Date.now() + 60_000));
  }

  // ---------- внутреннее ----------

  #profile() {
    return this.sql.exec('SELECT number, name, token_hash FROM profile WHERE id = 1').toArray()[0] ?? null;
  }

  #openSockets() {
    return this.ctx.getWebSockets().filter((ws) => ws.readyState === OPEN);
  }

  #mailbox(number) {
    return this.env.MAILBOX.get(this.env.MAILBOX.idFromName(number));
  }

  #waitAck(id) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.pending.delete(id); resolve(false); }, ACK_TIMEOUT_MS);
      this.pending.set(id, () => { clearTimeout(timer); this.pending.delete(id); resolve(true); });
    });
  }

  async #store(msg) {
    const { n } = this.sql.exec('SELECT COUNT(*) AS n FROM queue').one();
    if (n >= MAX_QUEUE) return 'queue_full';
    this.sql.exec('INSERT OR IGNORE INTO queue (id, sender, text, ts) VALUES (?, ?, ?, ?)',
      msg.id, msg.from, msg.text, msg.ts);
    if (n === 0) await this.ctx.storage.setAlarm(Date.now() + QUEUE_TTL_MS);
    return 'stored';
  }

  #flush(ws) {
    const rows = this.sql.exec('SELECT id, sender, text, ts FROM queue ORDER BY seq').toArray();
    for (const r of rows) {
      ws.send(JSON.stringify({ type: 'message', id: r.id, from: r.sender, text: r.text, ts: r.ts, queued: true }));
    }
  }
}

function cleanTs(ts) {
  const now = Date.now();
  if (typeof ts !== 'number' || !Number.isFinite(ts)) return now;
  return Math.min(now, Math.max(ts, now - MAX_TS_AGE_MS));
}

function reply(ws, obj) { try { ws.send(JSON.stringify(obj)); } catch {} }

async function sha256Hex(s) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}
