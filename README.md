# PilahFoto

Aplikasi Flutter untuk memilah foto dan video dari galeri perangkat atau Google
Drive ke folder tujuan.

## Google Drive

1. Gunakan project Google Cloud yang sudah ada dan aktifkan Google Drive API
   serta Google Picker API.
2. Atur OAuth consent screen; jika masih dalam mode Testing, tambahkan akun
   Google yang akan dipakai sebagai test user.
3. Connect menggunakan OAuth client bertipe Desktop dari project yang sama.
   Atur client ID sebagai compile-time define:

   ```powershell
   flutter run --dart-define=GOOGLE_DESKTOP_CLIENT_ID="<desktop-client-id>"
   flutter build apk --release --dart-define=GOOGLE_DESKTOP_CLIENT_ID="<desktop-client-id>"
   ```

   Client secret opsional; jika tidak diberikan, code exchange dan refresh
   berjalan dengan PKCE tanpa parameter `client_secret`. Flow memakai browser
   sistem dan loopback `127.0.0.1`; Google menyatakan loopback untuk aplikasi
   mobile deprecated, jadi uji langsung pada perangkat target.
4. Google Picker folder lama tetap memakai OAuth client bertipe Android.
   Daftarkan package
   `com.example.pilah_foto` dan SHA-1 sertifikat yang menandatangani aplikasi.
   Untuk mengambil SHA-1 debug di Windows:

   ```powershell
   keytool -list -v -keystore "$HOME\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
   ```

Jika menggunakan keystore release yang berbeda, daftarkan SHA-1 release itu
juga. APK debug memakai SHA-1 debug; APK/AAB release memakai SHA-1 dari
signing key release. Saat ini konfigurasi Gradle release project ini masih
menggunakan debug signing.

Connect meminta scope `https://www.googleapis.com/auth/drive.file` dan `email`,
kemudian menyimpan refresh token di secure storage perangkat.
Scope `drive.file` membatasi akses pada file yang dibuat aplikasi atau yang
dibuka/dipilih pengguna melalui aplikasi; scope ini tidak memberi akses penuh
ke semua file Drive. Tombol **Pilih Folder Lama** memakai Google Picker native
Android untuk memberi akses ke folder yang dipilih, tetap dengan scope
`drive.file`. Aplikasi tidak mengirim `serverClientId` khusus.
Google Drive meminta izin saat pengguna menekan **Connect** di Settings.
Pengguna dapat memutuskan koneksi kapan saja dari halaman yang sama.

Connect tidak memakai Google Sign-In/GMS; autentikasi dan refresh token memakai
browser sistem. Tombol Google Picker native untuk memilih folder lama tetap
bergantung pada Google Play Services.

Setelah terhubung:

- Pilih tujuan lokal atau folder Google Drive untuk tiap tombol pemindahan di
  Settings.
- Buka ikon Google Drive di halaman pemilihan album untuk menelusuri folder dan
  foto/video di Drive.
- Pilih tombol pindah pada item Drive untuk memindahkannya ke salah satu folder
  tujuan Google Drive.
- Memilih tujuan Drive langsung mengantrekan media dan menjalankan unggahan di
  latar dengan WorkManager. Setelah batch album selesai diunggah, Android 11+
  meminta izin satu kali untuk menghapus semua media yang berhasil diunggah.
  Android 10 memakai alur izin per-item dari plugin galeri.
