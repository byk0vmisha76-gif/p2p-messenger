# Клиент (Flutter): Android и Windows

Здесь только код. Служебные папки платформ (android/, windows/) создаёт `flutter create`;
в GitHub Actions это делается автоматически, локально — командами ниже.

## Локальная сборка (если нужен Flutter у себя)
    flutter create --project-name messenger --platforms=android,windows .
    dart run tool/patch_android.dart     # только для Android
    flutter pub get
    flutter run -d windows               # или: flutter run (Android)

Для Windows нужен Visual Studio с компонентами «Разработка классических приложений на C++»
и «C++ ATL». Включи также режим разработчика Windows (Параметры → Для разработчиков).

## Адрес сервера
Вводится на экране регистрации и запоминается. «Выйти и удалить данные» (меню ⋮) стирает аккаунт на устройстве,
после этого можно указать другой сервер.
