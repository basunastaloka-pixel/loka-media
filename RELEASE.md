# Automated Android Releases

The GitHub Actions workflow builds and publishes an Android release when a
version tag is pushed. The tag must use a numeric version, for example `v1.0.8`.
The APK version is taken from the tag, and the Android build number is
incremented automatically.

## Configure Google Drive Sign-In

In the Google Cloud project used by the app:

1. Enable the Google Drive API and Google Picker API, and configure the OAuth
   consent screen. While the app is in Testing mode, add
   `basun.astaloka@gmail.com` under **OAuth consent screen > Test users**.
2. In **Google Cloud Console > APIs & Services > Credentials**, create Android
   OAuth clients for package `com.example.pilah_foto`. Register the debug
   certificate SHA-1:

   ```text
   F1:57:12:DC:2F:4A:92:89:29:CD:1D:20:1B:6E:85:8F:D8:D2:10:41
   ```

   Also register the release certificate SHA-1 if it differs. The current
   release Gradle configuration uses debug signing, so compare the SHA-1
   reported by the app's debug log with the certificate for the APK being
   tested. If the console accepts only one SHA-1 per Android OAuth client,
   create a separate Android client for each fingerprint, using the same
   package name. Google selects the Android client using the package and
   signing certificate; the Android client ID is not `serverClientId`.
   To read a keystore fingerprint, run:

   ```powershell
   keytool -list -v -keystore "<keystore-path>" -alias "<key-alias>"
   ```

   Allow up to five minutes for credential changes to propagate.
3. Create a **Web application** OAuth client in the same project. The Android
   `google_sign_in` plugin requires this Web client ID as its
   `serverClientId` when no `google-services.json` is used. Add a repository
   Actions secret named `GOOGLE_SERVER_CLIENT_ID` with this Web client ID; the
   release workflow passes it as
   `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`. Do not use the Android or
   Desktop client ID for this value.
4. Optionally, open **Firebase Console > Project settings > Your apps** in the
   Firebase project linked to the same Google Cloud project. If needed, add an
   Android app with package `com.example.pilah_foto`, register its debug and
   release SHA-1 fingerprints, and download `google-services.json`. Place the
   file at `android/app/google-services.json`. Ensure it contains a Web OAuth
   client (`client_type: 3`). The Google Services Gradle plugin is applied
   only when this file exists. The provided
   `android/app/google-services.json.example` contains placeholders only and
   is not buildable. The real JSON is ignored by Git; do not commit it. The
   GitHub release workflow uses `GOOGLE_SERVER_CLIENT_ID` and does not require
   the JSON file.

Do not use the Android client ID as `serverClientId`, and do not use the
Desktop client for Android. The Desktop OAuth client is reserved for Windows
desktop builds.

The current Android release configuration uses debug signing. The Android
OAuth client must match the signing certificate on the APK being installed.
GitHub-hosted runner debug keys are not stable across runs, so reliable release
sign-in requires a stable release signing key.

## Publish a release

1. Create and push a version tag:

   ```bash
   git tag v1.0.8
   git push origin v1.0.8
   ```

2. Wait for the **Android Release** workflow to finish in GitHub Actions.
3. Open the repository's **Releases** page on Android and download
   `app-arm64-v8a-release.apk`.

Only the arm64 APK is attached to the release. The other ABI APKs are not
uploaded. Android release builds use R8 code shrinking and resource shrinking;
Flutter stable does not provide a `--shrink` option for `flutter build apk`.

The current Android release configuration uses debug signing. GitHub-hosted
runners do not share a signing key between runs, so these APKs may install as
new apps but are not suitable for reliable in-place updates. A stable release
keystore and GitHub Actions secrets are required for signed upgrades; this
workflow intentionally does not add those secrets.

The app's **Check for Update** feature continues to query:
`https://api.github.com/repos/basunastaloka-pixel/loka-media/releases/latest`.
That request is currently unauthenticated. GitHub does not expose private
repository releases to unauthenticated clients, so in-app update checks and
downloads require the repository to be public or a future authenticated
distribution approach. The workflow's `GITHUB_TOKEN` can publish releases but
must not be embedded in the app.
