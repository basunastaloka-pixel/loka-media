# Automated Android Releases

The GitHub Actions workflow builds and publishes an Android release when a
version tag is pushed. The tag must use a numeric version, for example `v1.0.8`.
The APK version is taken from the tag, and the Android build number is
incremented automatically.

## Configure Google Drive Sign-In

In the Google Cloud project used by the app:

1. Enable the Google Drive API and Google Picker API, and configure the OAuth
   consent screen.
2. Create an **Android** OAuth client for package `com.example.pilah_foto`.
   Register the SHA-1 fingerprint of the certificate that signs the APK.
   Android selects this client using the package name and signing certificate;
   its client ID is not passed to Flutter as `serverClientId`.
   Get a keystore fingerprint with
   `keytool -list -v -keystore "<keystore-path>" -alias "<key-alias>"`.
3. Create a **Web application** OAuth client in the same project. The
   `google_sign_in` Android plugin requires this Web client ID as its
   `serverClientId` when `google-services.json` is not used.
4. Add a repository Actions secret named `GOOGLE_SERVER_CLIENT_ID` and set its
   value to that Web application client ID. The release workflow passes it to
   Flutter as `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`.

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
