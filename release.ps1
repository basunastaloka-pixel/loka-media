$env:GRADLE_USER_HOME="D:\Gradle"
$env:TEMP="D:\Temp"
$env:TMP="D:\Temp"

$versionLine = (Get-Content pubspec.yaml | Select-String "version:").ToString()
$version = $versionLine.Split(":")[1].Trim().Split("+")[0]
$tag = "v$version"

Write-Host "Building Loka Files $version ($tag) ..."
& "D:\Program Files\BASUN DEV\flutter\bin\flutter.bat" build apk --release --split-per-abi --dart-define=GOOGLE_SERVER_CLIENT_ID=780518349223-2tjm0u5d403jutqetq09rchm3fjqlhtp.apps.googleusercontent.com

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build gagal, upload dibatalkan."
    exit 1
}

$apkDir = "build\app\outputs\flutter-apk"
$arm64Src = Join-Path $apkDir "app-arm64-v8a-release.apk"
$v7aSrc = Join-Path $apkDir "app-armeabi-v7a-release.apk"
$arm64Dst = Join-Path $apkDir "Loka-Files-v$version.apk"
$v7aDst = Join-Path $apkDir "Loka-Files-v$version-armeabi-v7a.apk"

if (Test-Path $arm64Dst) { Remove-Item $arm64Dst -Force }
if (Test-Path $v7aDst) { Remove-Item $v7aDst -Force }

Rename-Item $arm64Src "Loka-Files-v$version.apk"
Rename-Item $v7aSrc "Loka-Files-v$version-armeabi-v7a.apk"

Write-Host "Renamed to:"
Write-Host " - Loka-Files-v$version.apk"
Write-Host " - Loka-Files-v$version-armeabi-v7a.apk"

Write-Host "Uploading to GitHub Release $tag ..."
gh release upload $tag $arm64Dst $v7aDst --clobber

if ($LASTEXITCODE -ne 0) {
    Write-Host "Upload gagal. Pastikan gh auth login sudah jalan dan Release $tag sudah dibuat."
    exit 1
}

Write-Host "Selesai: $tag sudah berisi 2 APK PC (signing sama, Connect aman)."
