# Loka Media

A Flutter app for organizing photos and videos from a device gallery or Google
Drive.

## Google Drive setup

1. Enable the Google Drive API and Google Picker API in the Google Cloud
   project used by the app.
2. Configure the OAuth consent screen and add test accounts if the app remains
   in Testing mode.
3. Create an **Android** OAuth client for package
   `com.example.pilah_foto`. Register the SHA-1 certificate fingerprint of the
   key that signs the APK. Google Sign-In selects this Android client from the
   package name and signing certificate; the Android client ID is not a Dart
   `serverClientId`.
   To read a keystore fingerprint, run:

   ```powershell
   keytool -list -v -keystore "<keystore-path>" -alias "<key-alias>"
   ```
4. Create a **Web application** OAuth client in the same project. The Android
   `google_sign_in` plugin requires this Web client ID as its `serverClientId`
   when the project does not use `google-services.json`. Set it as the
   `GOOGLE_SERVER_CLIENT_ID` compile-time define:

   ```powershell
   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID="<web-client-id>"
   flutter build apk --release --dart-define=GOOGLE_SERVER_CLIENT_ID="<web-client-id>"
   ```

   The GitHub Android Release workflow reads the same value from the
   `GOOGLE_SERVER_CLIENT_ID` Actions secret. Do not pass an Android client ID
   as `serverClientId`.
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

The current Android release configuration uses debug signing. Register the
SHA-1 fingerprint for the certificate that actually signs the APK. GitHub-hosted
runner debug keys are not stable across runs, so reliable release sign-in
requires a stable release signing key.

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
