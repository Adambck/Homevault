# HomeVault Flutter App

Companion app voor iOS + Android. Pairing via QR (getoond in dashboard
Settings tab) of handmatig met IP + token.

## Setup

```bash
flutter create homevault_app
cd homevault_app
# Vervang lib/main.dart en pubspec.yaml door de bestanden hier
# Kopieer lib/api/ en lib/screens/ er in
flutter pub get
flutter run
```

## Structuur

```
lib/
├── main.dart                  — entry + theme + routing
├── api/
│   └── homevault_api.dart     — HTTP client + models
└── screens/
    ├── pairing_screen.dart    — QR scan + handmatige input
    └── dashboard_screen.dart  — services + system stats
```

## QR-code formaat

Dashboard toont een QR met deze payload:

```
homevault://192.168.1.201?token=<API_TOKEN>
```

## Nog te doen

- Nextcloud file browser (WebDAV via `http` package of `nextcloud` pub)
- Push notificaties: FCM setup + endpoint op API die het device token registreert
- iOS: `Info.plist` toevoegen: `NSCameraUsageDescription` voor QR scanner
- Android: `AndroidManifest.xml` toevoegen: `<uses-permission android:name="android.permission.CAMERA"/>`
- App icon + splash screen (gebruik `flutter_launcher_icons`)
- Build voor release: `flutter build apk --release` / `flutter build ipa`
