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

    // WebSocket: GET /ws?number=XXXXXXXX с заголовком Authorization: Bearer <token>
    if (url.pathname === '/ws') {
      if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
      const number = url.searchParams.get('number') ?? '';
      if (!NUMBER_RE.test(number)) return new Response('bad number', { status: 400 });
      return mailbox(env, number).fetch(request);
    }

    if (url.pathname === '/') return json({ status: 'ok', version: '0.4.0' });
    return new Response('Not found', { status: 404 });
  },
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}

function randomHex(bytes) {
  return [...crypto.getRandomValues(new Uint8Array(bytes))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomNumber() {
  return String(10000000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 90000000));
}
