// Проверка всей схемы на локальном `wrangler dev`
import assert from 'node:assert/strict';
import WebSocket from 'ws';

const HTTP = process.env.API ?? 'http://127.0.0.1:8787';
const WS = HTTP.replace('http', 'ws');

const post = async (path, body) => (await fetch(HTTP + path, {
  method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
})).json();

function open(number, token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS}/ws?number=${number}`, { headers: { Authorization: `Bearer ${token}` } });
    ws.inbox = []; ws.waiters = [];
    ws.on('message', (d) => { const m = JSON.parse(d); const w = ws.waiters.shift(); w ? w(m) : ws.inbox.push(m); });
    ws.on('open', () => resolve(ws));
    ws.on('unexpected-response', (_, res) => reject(new Error('HTTP ' + res.statusCode)));
    ws.on('error', reject);
  });
}
const next = (ws, ms = 3000) => new Promise((res, rej) => {
  if (ws.inbox.length) return res(ws.inbox.shift());
  const w = (m) => { clearTimeout(t); res(m); };
  const t = setTimeout(() => { ws.waiters = ws.waiters.filter((x) => x !== w); rej(new Error('timeout')); }, ms);
  ws.waiters.push(w);
});
const send = (ws, o) => ws.send(JSON.stringify(o));
const step = (s) => console.log('✓', s);

const a = await post('/register', { name: 'Аня' });
const b = await post('/register', { name: 'Боря' });
assert.match(a.number, /^\d{8}$/); assert.ok(a.token.length === 64);
step('регистрация: номер + токен');

const found = await (await fetch(`${HTTP}/user/${b.number}`)).json();
assert.deepEqual(found.profile, { number: b.number, name: 'Боря' });
assert.equal((await fetch(`${HTTP}/user/12345678`)).status, 404);
step('поиск по номеру (токен/хэш не утекает)');

await assert.rejects(open(b.number, 'wrong'), /401/);
await assert.rejects(open(b.number, a.token), /401/);
step('чужой/неверный токен -> 401');

// Боря офлайн
const wa = await open(a.number, a.token);
send(wa, { type: 'message', id: 'm1', to: b.number, text: 'привет, ты офлайн' });
send(wa, { type: 'message', id: 'm2', to: b.number, text: 'второе' });
assert.deepEqual(await next(wa), { type: 'sent', id: 'm1', to: b.number, status: 'stored' });
assert.equal((await next(wa)).status, 'stored');
step('получатель офлайн -> сообщения на сервере (stored)');

// Боря приходит онлайн -> получает накопленное
let wb = await open(b.number, b.token);
const q1 = await next(wb), q2 = await next(wb);
assert.deepEqual([q1.text, q2.text], ['привет, ты офлайн', 'второе']);
assert.equal(q1.from, a.number); assert.equal(q1.queued, true);
step('Боря онлайн -> получил очередь по порядку, from выставил сервер');

// Без ack сообщения остаются; Боря переподключается
wb.close(); await new Promise((r) => setTimeout(r, 300));
wb = await open(b.number, b.token);
assert.equal((await next(wb)).id, 'm1'); assert.equal((await next(wb)).id, 'm2');
step('без ack очередь не потеряна (переподключение)');

// ack -> удалено с сервера
send(wb, { type: 'ack', ids: ['m1', 'm2'] });
await new Promise((r) => setTimeout(r, 300));
wb.close(); await new Promise((r) => setTimeout(r, 300));
wb = await open(b.number, b.token);
await assert.rejects(next(wb, 700), /timeout/);
step('после ack на сервере пусто');

// Оба онлайн -> напрямую
send(wa, { type: 'message', id: 'm3', to: b.number, text: 'live' });
assert.equal((await next(wa)).status, 'relayed');
const live = await next(wb);
assert.equal(live.text, 'live'); assert.ok(!live.queued);
step('оба онлайн -> relayed, ничего не хранится');

// Ошибки
send(wa, { type: 'message', id: 'x', to: '12345678', text: 'в никуда' });
assert.equal((await next(wa)).code, 'not_found');
send(wa, { type: 'message', id: 'y', to: a.number, text: 'себе' });
assert.equal((await next(wa)).code, 'bad_recipient');
step('несуществующий номер / сам себе -> ошибка');

// Сигнализация звонка
send(wa, { type: 'call-offer', to: b.number, sdp: 'SDP' });
const offer = await next(wb);
assert.equal(offer.type, 'call-offer'); assert.equal(offer.from, a.number);
wb.close(); await new Promise((r) => setTimeout(r, 300));
send(wa, { type: 'call-offer', to: b.number, sdp: 'SDP' });
assert.equal((await next(wa)).type, 'call-unavailable');
step('звонки: сигнал доходит онлайн, офлайн -> call-unavailable');

wa.close();
console.log('\nВсё работает');
process.exit(0);
