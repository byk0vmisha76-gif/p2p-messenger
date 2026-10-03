# P2P Messenger

    server/   бэкенд: Cloudflare Workers + Durable Objects
    app/      клиент: Flutter (Android и Windows)
    .github/  автосборка и автотесты

Схема: оба онлайн -> сообщение сразу получателю, на сервере не хранится.
Получатель офлайн -> ждёт на сервере (макс. 14 дней), после доставки и подтверждения удаляется.
История хранится только на устройстве, старше 7 дней стирается.

## 1. Залить на GitHub
1. На github.com создай **пустой приватный** репозиторий (без README).
2. В папке проекта:

        git init
        git add .
        git commit -m "first version"
        git branch -M main
        git remote add origin https://github.com/ТВОЙ_ЛОГИН/ИМЯ_РЕПО.git
        git push -u origin main

После пуша во вкладке **Actions** сами запустятся «Server tests» и «Build app».

## 2. Windows-версия
Actions -> «Build app» -> последний запуск -> внизу **Artifacts** -> `messenger-windows` -> скачать, распаковать,
запустить `messenger.exe`. Для Android там же `messenger-android` (APK).
Пока сервер не настроен, на экране регистрации можно указать локальный адрес (см. ниже).

## 3. Настроить сервер (Cloudflare)
Вариант А, без установки чего-либо (через GitHub):
1. dash.cloudflare.com -> My Profile -> API Tokens -> Create Token -> шаблон **Edit Cloudflare Workers** -> создать, скопировать.
2. ID аккаунта: dash.cloudflare.com -> Workers & Pages -> справа «Account ID».
3. В репозитории: Settings -> Secrets and variables -> Actions -> Secrets: `CLOUDFLARE_API_TOKEN` и `CLOUDFLARE_ACCOUNT_ID`.
4. Actions -> «Deploy server» -> Run workflow. В логе будет адрес вида `https://p2p-messenger.xxxx.workers.dev`.

Вариант Б, локально: `cd server`, `npm install`, `npx wrangler login`, `npm run deploy`.

Проверка: открой адрес в браузере, должно быть `{"status":"ok",...}`.

## 4. Проверка
- В приложении (Windows/Android) на экране регистрации впиши адрес сервера, создай аккаунт.
- Второй аккаунт: на телефоне. Обменяйтесь номерами, «Новый чат».
- Проверь офлайн: закрой одно приложение, напиши ему с другого, открой — сообщение должно прийти.
- Хочешь вшить адрес по умолчанию: Settings -> Secrets and variables -> Actions -> **Variables** -> `API_URL`.

## Звонки
Голосовые звонки (WebRTC): кнопка с трубкой в чате. Звук идёт напрямую между устройствами; сервер только передаёт сигналы.
Если прямая связь невозможна, нужен ретранслятор TURN (Cloudflare, бесплатно до 1000 ГБ/мес):
1. dash.cloudflare.com -> Realtime (или Calls) -> TURN Server -> Create -> скопировать **Turn Token ID** и **API Token**.
2. GitHub -> Settings -> Secrets and variables -> Actions -> секреты `TURN_KEY_ID` и `TURN_KEY_API_TOKEN`.
3. Actions -> «Deploy server» -> Run workflow.
Без этих секретов звонки работают через бесплатный STUN (в большинстве сетей этого достаточно).

## Локальный сервер для отладки
    cd server && npm install && npm run dev
В приложении на ПК адрес по умолчанию уже `http://127.0.0.1:8787` (с эмулятора Android: `http://10.0.2.2:8787`).
