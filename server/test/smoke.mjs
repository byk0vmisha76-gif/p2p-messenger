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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
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

// ---- Боря офлайн ----
let wa = await open(a.number, a.token);
const t1 = Date.now() - 60_000;
send(wa, { type: 'message', id: 'm1', to: b.number, text: 'привет, ты офлайн', ts: t1 });
send(wa, { type: 'message', id: 'm2', to: b.number, text: 'второе' });
assert.deepEqual(await next(wa), { type: 'sent', id: 'm1', to: b.number, status: 'stored' });
assert.equal((await next(wa)).status, 'stored');
step('получатель офлайн -> сообщения на сервере (stored)');

let wb = await open(b.number, b.token);
const q1 = await next(wb), q2 = await next(wb);
assert.deepEqual([q1.text, q2.text], ['привет, ты офлайн', 'второе']);
assert.equal(q1.from, a.number); assert.equal(q1.queued, true);
assert.equal(q1.ts, t1, 'время создания сохраняется (на обоих экранах одинаковое)');
step('Боря онлайн -> очередь по порядку; from ставит сервер; время создания сохранено');

wb.close(); await sleep(300);
wb = await open(b.number, b.token);
assert.equal((await next(wb)).id, 'm1'); assert.equal((await next(wb)).id, 'm2');
step('без ack очередь не потеряна (переподключение)');

send(wb, { type: 'ack', ids: ['m1', 'm2'] });
const r1 = await next(wa), r2 = await next(wa);
assert.deepEqual([r1.type, r1.id, r1.to], ['delivered', 'm1', b.number]);
assert.deepEqual([r2.type, r2.id], ['delivered', 'm2']);
step('ack -> отправитель получает квитанции (вторая галочка у «stored»)');

wb.close(); await sleep(300);
wb = await open(b.number, b.token);
await assert.rejects(next(wb, 700), /timeout/);
step('после ack на сервере пусто');

// ---- оба онлайн ----
send(wa, { type: 'message', id: 'm3', to: b.number, text: 'live' });
const live = await next(wb);
assert.equal(live.text, 'live'); assert.ok(!live.queued);
send(wb, { type: 'ack', ids: ['m3'] });
assert.deepEqual(await next(wa), { type: 'sent', id: 'm3', to: b.number, status: 'delivered' });
step('оба онлайн -> delivered только после ack получателя');

// ---- ТВОЙ СЛУЧАЙ: соединение «мёртвое», получатель не подтверждает ----
const t0 = Date.now();
send(wa, { type: 'message', id: 'm4', to: b.number, text: 'у меня тож' });
assert.equal((await next(wb)).id, 'm4');                    // ушло в сокет, но ack не будет
const sent4 = await next(wa, 10_000);
assert.equal(sent4.status, 'stored');
assert.ok(Date.now() - t0 >= 5000, 'ждали подтверждение ~6 секунд');
step('нет ack за 6 с -> НЕ «доставлено», сообщение сохранено на сервере (одна галочка)');

wb.close(); await sleep(300);
wb = await open(b.number, b.token);
const again = await next(wb);
assert.equal(again.id, 'm4'); assert.equal(again.queued, true);
send(wb, { type: 'ack', ids: ['m4'] });
assert.deepEqual(await next(wa), { type: 'delivered', id: 'm4', to: b.number });
step('получатель вернулся -> получил потерянное сообщение, отправитель получил вторую галочку');

// ---- отправитель был офлайн в момент ack -> «check» при подключении ----
wb.close(); await sleep(300);
send(wa, { type: 'message', id: 'm6', to: b.number, text: 'пока ты офлайн' });
assert.equal((await next(wa)).status, 'stored');
wa.close(); await sleep(300);
wb = await open(b.number, b.token);
assert.equal((await next(wb)).id, 'm6');
send(wb, { type: 'ack', ids: ['m6'] }); await sleep(500);          // квитанция уходит «в пустоту»
wa = await open(a.number, a.token);
send(wa, { type: 'check', items: [{ id: 'm6', to: b.number }] });
assert.deepEqual(await next(wa), { type: 'delivered', id: 'm6', to: b.number });
wb.close(); await sleep(300);
send(wa, { type: 'message', id: 'm7', to: b.number, text: 'ещё лежит' });
assert.equal((await next(wa)).status, 'stored');
send(wa, { type: 'check', items: [{ id: 'm7', to: b.number }] });
await assert.rejects(next(wa, 700), /timeout/);                     // ещё не получено -> молчим
wb = await open(b.number, b.token);
assert.equal((await next(wb)).id, 'm7');
send(wb, { type: 'ack', ids: ['m7'] });
assert.equal((await next(wa)).type, 'delivered');
step('квитанция потерялась (отправитель офлайн) -> check при подключении даёт вторую галочку');

// ---- получатель переподключился, пока сервер ждал ack ----
send(wa, { type: 'message', id: 'm8', to: b.number, text: 'переподключение' });
assert.equal((await next(wb)).id, 'm8');                            // ушло в старый сокет, ack не будет
const wb3 = await open(b.number, b.token);                          // получатель переподключился
assert.equal((await next(wa, 10_000)).status, 'stored');
const m8 = await next(wb3, 10_000);
assert.equal(m8.id, 'm8');                                          // не застряло в очереди
send(wb3, { type: 'ack', ids: ['m8'] });
assert.equal((await next(wa)).type, 'delivered');
wb = wb3;
step('переподключение во время ожидания ack -> сообщение не застревает');

// ---- ошибки ----
send(wa, { type: 'message', id: 'x', to: '12345678', text: 'в никуда' });
assert.equal((await next(wa)).code, 'not_found');
send(wa, { type: 'message', id: 'y', to: a.number, text: 'себе' });
assert.equal((await next(wa)).code, 'bad_recipient');
send(wa, { type: 'message', id: 'z', to: b.number, text: 'из будущего', ts: Date.now() + 10 ** 9 });
assert.equal((await next(wb)).ts <= Date.now(), true);
send(wb, { type: 'ack', ids: ['z'] }); await next(wa);
step('ошибки: несуществующий номер / сам себе; время «из будущего» обрезается');

// ---- звонки ----
send(wa, { type: 'call-offer', to: b.number, sdp: 'SDP' });
const offer = await next(wb);
assert.equal(offer.type, 'call-offer'); assert.equal(offer.from, a.number);
wb.close(); await sleep(300);
send(wa, { type: 'call-offer', to: b.number, sdp: 'SDP' });
assert.equal((await next(wa)).type, 'call-unavailable');
step('звонки: сигнал доходит онлайн, офлайн -> call-unavailable');

wa.close();
console.log('\nВсё работает');
process.exit(0);
