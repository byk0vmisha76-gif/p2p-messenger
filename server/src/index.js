// P2P Messenger — точка входа (Cloudflare Worker)
import { Mailbox, NUMBER_RE } from './mailbox.js';
export { Mailbox };

const mailbox = (env, number) => env.MAILBOX.get(env.MAILBOX.idFromName(number));

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Регистрация: сервер выдаёт номер и секретный токен (токен показывается ОДИН раз)
    if (url.pathname === '/register' && request.method === 'POST') {
      let body = {};
      try { body = await request.json(); } catch {}
      const name = String(body.name ?? '').trim().slice(0, 40) || 'Аноним';
      const token = randomHex(32);
      for (let i = 0; i < 10; i++) {
        const number = randomNumber();
        if (await mailbox(env, number).init(number, name, token)) {
          return json({ number, name, token });
        }
      }
      return json({ error: 'try_again' }, 503);
    }

    // Поиск человека по номеру (имя и номер, больше ничего не отдаётся)
    if (url.pathname.startsWith('/user/') && request.method === 'GET') {
      const number = url.pathname.slice('/user/'.length);
      if (!NUMBER_RE.test(number)) return json({ found: false }, 404);
      const profile = await mailbox(env, number).publicProfile();
      return profile ? json({ found: true, profile }) : json({ found: false }, 404);
    }

    // ICE-серверы для звонков: POST /turn?number=XXXXXXXX с заголовком Authorization: Bearer <token>
    if (url.pathname === '/turn' && request.method === 'POST') {
      const number = url.searchParams.get('number') ?? '';
      const auth = request.headers.get('Authorization') ?? '';
      const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
      if (!NUMBER_RE.test(number) || !(await mailbox(env, number).verify(token))) {
        return json({ error: 'unauthorized' }, 401);
      }
      return json(await iceServers(env));
    }

    // WebSocket: GET /ws?number=XXXXXXXX с заголовком Authorization: Bearer <token>
    if (url.pathname === '/ws') {
      if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
      const number = url.searchParams.get('number') ?? '';
      if (!NUMBER_RE.test(number)) return new Response('bad number', { status: 400 });
      return mailbox(env, number).fetch(request);
    }

    if (url.pathname === '/') return json({ status: 'ok', version: '0.5.0' });
    return new Response('Not found', { status: 404 });
  },
};

const FALLBACK_ICE = [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }];

/** Короткоживущие данные Cloudflare TURN. Если ключ не задан или сервис недоступен, отдаём только STUN. */
async function iceServers(env) {
  if (env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN) {
    try {
      const r = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
        {
          method: 'POST',
          headers: { Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ ttl: 86400 }),
        });
      if (r.ok) {
        const d = await r.json();
        const list = Array.isArray(d.iceServers) ? d.iceServers : d.iceServers ? [d.iceServers] : [];
        if (list.length) return { iceServers: list, turn: true };
      }
    } catch {}
  }
  return { iceServers: FALLBACK_ICE, turn: false };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}

function randomHex(bytes) {
  return [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomNumber() {
  return String(10000000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 90000000));
}
