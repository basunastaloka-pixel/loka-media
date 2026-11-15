# Loka Media

A Flutter app for organizing photos and videos from a device gallery or Google
Drive.

## App tour and language

The App Tour appears on first install. Finish or skip it to continue to the app;
you can open it again from Settings. Choose English or Bahasa Indonesia in
Settings, and the language preference is saved on the device.

## Google Drive setup

1. Enable the Google Drive API and Google Picker API in the Google Cloud
   project used by the app.
2. Configure the OAuth consent screen and add test accounts if the app remains
   in Testing mode.
3. Keep the existing Android OAuth clients for `com.example.pilah_foto` while
   creating two new Android OAuth clients for `com.lokamedia.app`: one named
   **Kantor** and one named **Laptop**. Use the same SHA-1 fingerprints as the
   corresponding old clients. Do not delete the old clients; existing installs
   still use the old package. Google Sign-In selects the Android client from
   the package name and signing certificate; the Android client ID is not a
   Dart `serverClientId`.
   To read a keystore fingerprint, run:

   ```powershell
   keytool -list -v -keystore "<keystore-path>" -alias "<key-alias>"
   ```
4. Create a **Web application** OAuth client in the same project. The Android
   `google_sign_in` plugin requires this Web client ID as its `serverClientId`
   when no Google Services configuration is available. Set it as the
   `GOOGLE_SERVER_CLIENT_ID` compile-time define:

   ```powershell
   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID="<web-client-id>"
   flutter build apk --release --dart-define=GOOGLE_SERVER_CLIENT_ID="<web-client-id>"
   ```

   The GitHub Android Release workflow reads the same value from the
   `GOOGLE_SERVER_CLIENT_ID` Actions secret. Do not pass an Android client ID
   as `serverClientId`. When a local `google-services.json` is configured, the
   generated Web client ID is used if this define is omitted.
5. Windows desktop builds may use a separate Desktop OAuth client with
   `--dart-define=GOOGLE_DESKTOP_CLIENT_ID="<windows-desktop-client-id>"`.
   The Android build does not use that client.

The app requests only `drive.file`, `openid`, `email`, and `profile`; it does
not request full Drive access. Access tokens and account details are stored
with `flutter_secure_storage`; tokens are not stored in SharedPreferences or
written to logs. The `drive.file` scope limits access to files created by the
app or explicitly opened or selected by the user. The native Android folder
picker continues to use the Android OAuth client registered above. Google
Sign-In uses Google Play Services on Android, and users can disconnect their
account from Settings.

### Optional local Google Services configuration

The app supports an optional Firebase `google-services.json` for local Android
builds. In **Firebase Console > Project settings > Your apps**, select the
Firebase project linked to the same Google Cloud project as the OAuth clients.
If there is no Android app yet, add one with package `com.lokamedia.app`,
register the debug and release SHA-1 fingerprints, then download its
`google-services.json`. Place the downloaded file at
`android/app/google-services.json`. The Google Services Gradle plugin is
applied only when this file exists, and the file must include a Web OAuth
client.

`android/app/google-services.json.example` is a placeholder template, not a
valid build configuration. Do not copy it unchanged. The real file is ignored
by Git and must not be committed. GitHub Actions builds do not need this file;
they use the `GOOGLE_SERVER_CLIENT_ID` Actions secret instead.

The current Android release configuration uses debug signing. Register the
SHA-1 fingerprint for the certificate that actually signs the APK. GitHub-hosted
runner debug keys are not stable across runs, so reliable release sign-in
requires a stable release signing key.

The Android package changed from `com.example.pilah_foto` to
`com.lokamedia.app`; Android treats these as separate apps. The new app displays
a first-launch reminder to back up Target folders and uninstall the old app.
To sign in to Drive, add the two new Android OAuth clients described above and
keep the old clients until old-package installs are no longer in use.

## Pro access and payments

The public Loka Files repository contains the Free app, Pro gating UI, and a
client for a separately deployed license API. It does not contain Midtrans
server keys, Apps Script secrets, Sheet IDs, or Sheet data. Keep the Apps
Script/payment implementation and its configuration in a private Pro
repository. Android APK releases remain in this public repository so the
in-app updater can continue to find them.

The app starts a three-day local trial only when the user chooses **Start
3-Day Free Trial**. It remembers the last confirmed Pro entitlements for
offline access and checks the private API when a locked Pro feature is tapped.
The API should accept JSON POST requests:

- `{"action":"status","installId":"..."}` and return only
  `{"addButtons":true|false,"drive":true|false}`.
- `{"action":"createPayment","installId":"...","product":"add_buttons|drive|bundle","midtransMode":"sandbox|production"}`
  and return `{"paymentUrl":"https://..."}` for a Midtrans Snap QRIS checkout.

The private backend must assign the published prices (Rp 30,000, Rp 35,000,
and Rp 59,000), create Snap transactions with QRIS enabled, verify Midtrans
webhook signatures, update the private Sheet automatically, and return only
the two entitlement booleans to the app. Do not return Sheet rows or payment
secrets to the app.

Configure the Apps Script deployment URL at build time; leave it unset until
the private service is deployed:

```powershell
flutter build apk --release `
  --dart-define=PRO_LICENSE_API_URL="https://script.google.com/macros/s/<deployment-id>/exec" `
  --dart-define=MIDTRANS_MODE="sandbox"
```

In the private backend repository, configure `MIDTRANS_SERVER_KEY`,
`MIDTRANS_MODE` (`sandbox` or `production`), and the private Sheet ID through
Apps Script Script Properties or that private repository's secret store.
Never pass the Midtrans server key as a Flutter `--dart-define`. Switch to
production only after the Midtrans account, webhook, and production credentials
are ready. The current repository does not include or deploy that private
backend; without its URL, payment checkout stays unavailable and the app
continues to provide Free access and the local trial.

## Google Drive features

- Choose a local folder or Google Drive folder as a destination for each move
  action in Settings.
- Open Google Drive from the album selection screen to browse folders and
  photos or videos.
- Move Drive items to a configured Google Drive destination.
- Select an existing folder with the native Android Google Picker.
- Choosing a Drive destination queues media for background upload with
  WorkManager. After an album batch completes, Android 11+ requests permission
  once to remove successfully uploaded media. Android 10 uses the gallery
  plugin's per-item permission flow.
