# P2P Messenger — бэкенд (Cloudflare Workers + Durable Objects)

## Как это работает
- У каждого пользователя свой «почтовый ящик» (Durable Object `Mailbox`): профиль + очередь.
- **Оба онлайн:** сообщение пересылается напрямую в сокет получателя и нигде не записывается.
- **Получатель офлайн:** сообщение лежит в очереди на сервере.
  Когда он подключается, сервер отдаёт очередь, клиент сохраняет её у себя и шлёт `ack`, после чего сервер удаляет.
- Недоставленное удаляется само через 14 дней, в очереди максимум 500 сообщений.
- История хранится только на телефоне (и раз в неделю чистится там, это делает клиент).

## Запуск
    npm install
    npm run dev        # локально, http://127.0.0.1:8787
    npm test           # проверка всей схемы (при запущенном dev)
    npx wrangler login
    npm run deploy     # выкатка в Cloudflare

Ничего вставлять в `wrangler.toml` не нужно: KV/D1 не используются.
Нужен только бесплатный аккаунт Cloudflare.

## Протокол
HTTP:
- `POST /register` `{name}` -> `{number, name, token}`. Токен выдаётся один раз, клиент хранит его в защищённом хранилище.
- `GET /user/:number` -> `{found, profile:{number,name}}`

WebSocket: `GET /ws?number=XXXXXXXX`, заголовок `Authorization: Bearer <token>`

Клиент -> сервер:
- `{type:'message', id, to, text, ts}` (`id` — UUID, `ts` — время создания в мс, оба генерирует клиент)
- `{type:'check', items:[{id,to}]}` — «какие из моих сообщений, лежавших на сервере, уже получены?» (ответ: `delivered` по каждому)
- `{type:'ack', ids:[...]}` — «сохранил у себя». На ack сервер считает сообщение доставленным и удаляет его из очереди
- `{type:'call-offer'|'call-answer'|'ice-candidate'|'call-end', to, sdp?, candidate?}`
- звонки: `{type:'call-offer'|'call-answer'|'ice-candidate'|'call-end', to, callId, sdp?, candidate?, reason?}` — сервер только пересылает (с полем `from`); офлайн-абоненту на `call-offer` отвечает `{type:'call-unavailable', to, callId}`
- текст `ping` -> сервер отвечает `pong` (слать раз в ~25 сек)

Сервер -> клиент:
- `{type:'message', id, from, text, ts, queued?}`
- `{type:'sent', id, to, status:'delivered'|'stored'}`: delivered = получатель подтвердил; stored = лежит на сервере
- `{type:'delivered', id, to}` — позже: сообщение из очереди получено (вторая галочка)
- `{type:'error', id?, code}` (`not_found`, `queue_full`, `bad_text`, ...)
- `{type:'call-unavailable', to}` и сигналы звонков

Клиент обязан дедуплицировать сообщения по `id`: после обрыва сервер может прислать очередь повторно.

## Ещё не сделано
- [ ] Клиент (Flutter: Android, потом ПК)
- [ ] Push (FCM), чтобы Android будил приложение, когда оно закрыто
- [ ] E2E-шифрование (сейчас очередь на сервере лежит открытым текстом)
- [ ] Лимиты на /register и на частоту сообщений (Cloudflare Rate Limiting)
- [ ] Звонки: нужен TURN-сервер
