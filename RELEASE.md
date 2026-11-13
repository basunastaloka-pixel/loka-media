# Automated Android Releases

The GitHub Actions workflow builds and publishes an Android release when a
version tag is pushed. The tag must use a numeric version, for example `v1.0.2`.
The APK version is taken from the tag, and the Android build number is
incremented automatically.

## Configure Google Drive OAuth

Before running the Android Release workflow, add a repository Actions secret:

1. Open **Settings > Secrets and variables > Actions**.
2. Select **New repository secret**.
3. Set the name to `GOOGLE_DESKTOP_CLIENT_ID`.
4. Set the value to
   `780518349223-pq1n7od59vgj8f4jqsvej4vgurl6gmqq.apps.googleusercontent.com`
   (the **Loka Media Desktop** OAuth client ID).

The workflow passes this secret to Flutter as the
`GOOGLE_DESKTOP_CLIENT_ID` compile-time define. Do not hardcode the client ID
in the application source.

## Publish a release

1. Create and push a version tag:

   ```bash
   git tag v1.0.2
   git push origin v1.0.2
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
