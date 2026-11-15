import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  english('en', 'English'),
  bahasaIndonesia('id', 'Bahasa Indonesia');

  final String languageCode;
  final String displayName;

  const AppLanguage(this.languageCode, this.displayName);

  Locale get locale => Locale(languageCode);

  static AppLanguage fromLocale(Locale? locale) => locale?.languageCode == 'id'
      ? AppLanguage.bahasaIndonesia
      : AppLanguage.english;

  static AppLanguage fromPreference(String? value) =>
      AppLanguage.values.firstWhere(
        (language) => language.name == value,
        orElse: () => AppLanguage.english,
      );
}

class AppPreferences {
  static const languageKey = 'loka_files_language';
  static const tourCompletedKey = 'tour_completed';
  static const packageMigrationNoticeKey = 'package_migration_notice_seen';

  static Future<AppLanguage> loadLanguage() async {
    final preferences = await SharedPreferences.getInstance();
    return AppLanguage.fromPreference(preferences.getString(languageKey));
  }

  static Future<void> saveLanguage(AppLanguage language) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(languageKey, language.name)) {
      throw StateError('The selected language could not be saved.');
    }
  }

  static Future<bool> hasCompletedTour() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.containsKey(tourCompletedKey)) {
      return preferences.getBool(tourCompletedKey) ?? false;
    }

    const existingAppPreferenceKeys = [
      'saved_target_folders',
      'drive_upload_delete_mode',
      'loka_files_trash_items',
      'loka_files_trash_sort_order',
      'loka_media_last_update_check',
    ];
    if (existingAppPreferenceKeys.any(preferences.containsKey)) {
      if (!await preferences.setBool(tourCompletedKey, true)) {
        throw StateError('The App Tour migration could not be saved.');
      }
      return true;
    }
    return false;
  }

  static Future<void> markTourCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(tourCompletedKey, true)) {
      throw StateError('The App Tour completion could not be saved.');
    }
  }

  static Future<bool> hasSeenPackageMigrationNotice() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(packageMigrationNoticeKey) ?? false;
  }

  static Future<void> markPackageMigrationNoticeSeen() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(packageMigrationNoticeKey, true)) {
      throw StateError('The package migration notice could not be saved.');
    }
  }
}

class AppLocalizations {
  final Locale locale;

  const AppLocalizations(this.locale);

  static const supportedLocales = [Locale('en'), Locale('id')];

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(Locale('en'));

  bool get _isIndonesian => locale.languageCode == 'id';

  String text(String english, [Map<String, Object?> values = const {}]) {
    final translated = _isIndonesian
        ? (_indonesianTranslations[english] ?? english)
        : english;
    return values.entries.fold<String>(
      translated,
      (result, entry) =>
          result.replaceAll('{${entry.key}}', entry.value.toString()),
    );
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => AppLocalizations.supportedLocales.any(
    (supportedLocale) => supportedLocale.languageCode == locale.languageCode,
  );

  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture<AppLocalizations>(AppLocalizations(locale));

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationContext on BuildContext {
  String tr(String english, [Map<String, Object?> values = const {}]) =>
      AppLocalizations.of(this).text(english, values);
}

const Map<String, String> _indonesianTranslations = {
  'Welcome to Loka Files': 'Selamat datang di Loka Files',
  'Sort 1000 photos in minutes. 1 tap moves a photo to the Drive folder you chose.': 'Pilah 1.000 foto dalam hitungan menit. Satu ketukan memindahkan foto ke folder Drive yang Anda pilih.',
  'Set your folders first': 'Atur folder tujuan terlebih dahulu',
  'Create Target folders in Target folders screen. Each folder is a button when you sort.': 'Buat folder tujuan di layar Folder tujuan. Setiap folder akan menjadi tombol saat Anda memilah.',
  'Sort with 1 tap': 'Pilah dengan satu ketukan',
  "Open an album, select photos, tap a folder button like 'tes move'. Done.": "Buka album, pilih foto, lalu ketuk tombol folder seperti 'tes move'. Selesai.",
  'Safe Trash': 'Sampah yang aman',
  'After upload to Drive, your local photo moves to Trash for 30 days. You can Restore it.': 'Setelah diunggah ke Drive, foto lokal dipindahkan ke Sampah selama 30 hari. Anda dapat memulihkannya.',
  'Drive Upload is Pro': 'Upload ke Drive tersedia untuk Pro',
  'Connect Drive with your Google email. Free users can sort locally. Pro unlocks Move to Drive.': 'Hubungkan Drive dengan akun Google Anda. Pengguna gratis dapat memilah secara lokal. Pro membuka fitur Pindahkan ke Drive.',
  'Skip': 'Lewati',
  'Next': 'Berikutnya',
  'Get Started': 'Mulai',
  'App Tour': 'Panduan Aplikasi',
  'Unable to save App Tour setting: {error}':
      'Tidak dapat menyimpan pengaturan Panduan Aplikasi: {error}',
  'Unable to load app settings: {error}':
      'Tidak dapat memuat pengaturan aplikasi: {error}',
  'not available': 'tidak tersedia',
  'Folder ID: {id}': 'ID folder: {id}',
  'HTTP status: {status}': 'Status HTTP: {status}',
  'Drive API error: {error}': 'Kesalahan API Drive: {error}',
  'Account: {account}': 'Akun: {account}',
  'This folder was not created by Loka Files, so Drive does not allow access with current permission.': 'Folder ini tidak dibuat oleh Loka Files, sehingga Drive tidak mengizinkan akses dengan izin saat ini.',
  'Drive does not distinguish a missing folder from one hidden by the current permission.': 'Drive tidak membedakan folder yang tidak ditemukan dengan folder yang tersembunyi karena izin saat ini.',
  'Unable to validate this folder.': 'Tidak dapat memvalidasi folder ini.',
  'Retry': 'Coba lagi',
  'Press Back again to exit': 'Tekan Kembali sekali lagi untuk keluar',
  'Unlock Pro': 'Buka Pro',
  'Continue for Free': 'Lanjut Gratis',
  'Lanjut Gratis': 'Lanjut Gratis',
  'Add folder · Pro': 'Tambah folder · Pro',
  'Google Drive · Pro': 'Google Drive · Pro',
  'More move buttons are available in Loka Media Pro.':
      'Tombol pindah tambahan tersedia di Loka Media Pro.',
  'Google Drive features are available in Loka Media Pro.':
      'Fitur Google Drive tersedia di Loka Media Pro.',
  'This is new package version. Please uninstall old Loka Files (com.example.pilah_foto) after backing up your Target folders.': 'Ini adalah versi paket baru. Harap hapus instalasi Loka Files lama (com.example.pilah_foto) setelah mencadangkan folder Target Anda.',
  'OK': 'Oke',
  'Start Over': 'Ulang dari Awal',
  'Start sorting from the first photo again? Current position will be reset.': 'Mulai memilah dari foto pertama lagi? Posisi saat ini akan diatur ulang.',
  'Yes, Start Over': 'Ya, Ulang dari Awal',
  'New Category': 'Kategori Baru',
  'media': 'media',
  'Language': 'Bahasa',
  'Show App Tour again': 'Tampilkan Panduan Aplikasi lagi',
  'Learn the basics of sorting and Drive uploads.':
      'Pelajari dasar-dasar pemilahan dan upload ke Drive.',
  'Unable to save language: {error}': 'Tidak dapat menyimpan bahasa: {error}',
  'Unable to load delete mode: {error}':
      'Tidak dapat memuat Mode Hapus: {error}',
  'Google Drive connection was cancelled.': 'Koneksi Google Drive dibatalkan.',
  'Unable to connect Google Drive: {error}':
      'Tidak dapat menghubungkan Google Drive: {error}',
  'Unable to disconnect Google Drive: {error}':
      'Tidak dapat memutuskan koneksi Google Drive: {error}',
  'Updated to v{version}. Please re-open the app.':
      'Berhasil diperbarui ke v{version}. Silakan buka kembali aplikasi.',
  'Unable to load the app version: {error}':
      'Tidak dapat memuat versi aplikasi: {error}',
  'Install unknown apps is still disabled for Loka Files.': 'Izin Instal aplikasi tidak dikenal masih dinonaktifkan untuk Loka Files.',
  'Unable to continue the update: {error}':
      'Tidak dapat melanjutkan pembaruan: {error}',
  'You are on the latest version.': 'Anda menggunakan versi terbaru.',
  'New version {version} available': 'Versi baru {version} tersedia',
  'Download {asset} and install this update now?':
      'Unduh {asset} dan pasang pembaruan ini sekarang?',
  'Later': 'Nanti',
  'Update': 'Perbarui',
  'Unable to check for updates: {error}':
      'Tidak dapat memeriksa pembaruan: {error}',
  'Download failed. Please try again or download from GitHub Releases.':
      'Unduhan gagal. Silakan coba lagi atau unduh dari GitHub Releases.',
  'Allow app updates': 'Izinkan pembaruan aplikasi',
  'To update inside the app, allow Install unknown apps for Loka Files.': 'Agar dapat memperbarui dari aplikasi, izinkan Instal aplikasi tidak dikenal untuk Loka Files.',
  'Cancel': 'Batal',
  'Open Settings': 'Buka Pengaturan',
  'Unable to install the update: {error}':
      'Tidak dapat memasang pembaruan: {error}',
  'Downloading {percent}% ({received} / {total} MB)':
      'Mengunduh {percent}% ({received} / {total} MB)',
  'Connect Google Drive first.': 'Hubungkan Google Drive terlebih dahulu.',
  'Unable to save Delete Mode: {error}':
      'Tidak dapat menyimpan Mode Hapus: {error}',
  'Target folders': 'Folder tujuan',
  'Save': 'Simpan',
  'Appearance': 'Tampilan',
  'System': 'Sistem',
  'Light': 'Terang',
  'Dark': 'Gelap',
  'Current version: Loading...': 'Versi saat ini: Memuat...',
  'Current version: v{version}': 'Versi saat ini: v{version}',
  'Current version: v{current} | Latest: v{latest}':
      'Versi saat ini: v{current} | Terbaru: v{latest}',
  'Check for Update': 'Periksa Pembaruan',
  'Choose a destination on this device or in Google Drive. Local photos can be moved to either destination.': 'Pilih tujuan di perangkat ini atau di Google Drive. Foto lokal dapat dipindahkan ke salah satu tujuan.',
  'Delete Mode': 'Mode Hapus',
  'Applies only to local files after a successful Google Drive upload.': 'Hanya berlaku untuk file lokal setelah berhasil diunggah ke Google Drive.',
  'Move to Trash': 'Pindahkan ke Sampah',
  'Restorable for 30 days': 'Dapat dipulihkan selama 30 hari',
  'Restorable for 30 days.': 'Dapat dipulihkan selama 30 hari.',
  'Delete Permanently': 'Hapus Permanen',
  'Cannot be undone.': 'Tidak dapat dibatalkan.',
  'Folder name': 'Nama folder',
  'Remove folder': 'Hapus folder',
  'Drive': 'Drive',
  'Selected folder': 'Folder yang dipilih',
  'Local': 'Lokal',
  'Choose Google Drive folder': 'Pilih folder Google Drive',
  'Add folder': 'Tambah folder',
  'Loka Files v{version}': 'Loka Files v{version}',
  'Google Drive': 'Google Drive',
  'Not connected': 'Belum terhubung',
  'Connect': 'Hubungkan',
  'Disconnect': 'Putuskan koneksi',
  'Drive · {folder}': 'Drive · {folder}',
  'No destination selected': 'Belum ada tujuan yang dipilih',
  'Unable to restore the Google Drive session: {error}':
      'Tidak dapat memulihkan sesi Google Drive: {error}',
  'Permission to access the gallery was denied.':
      'Izin untuk mengakses galeri ditolak.',
  'Unable to access this video file.': 'Tidak dapat mengakses file video ini.',
  'Unable to play this video.': 'Tidak dapat memutar video ini.',
  'Folder "{folder}" created.': 'Folder "{folder}" berhasil dibuat.',
  'Create New Folder': 'Buat Folder Baru',
  'Enter a folder name.': 'Masukkan nama folder.',
  'Unable to create folder: {error}': 'Tidak dapat membuat folder: {error}',
  'Create': 'Buat',
  'Parent folder': 'Folder induk',
  'Close': 'Tutup',
  'My Connected Drive': 'Drive Saya yang Terhubung',
  'Add Folder Link': 'Tambahkan Tautan Folder',
  'Select Folder': 'Pilih Folder',
  'Add Google Drive Folder Editor Link':
      'Tambahkan Tautan Editor Folder Google Drive',
  'Paste Google Drive folder link here - https://drive.google.com/drive/folders/...': 'Tempel tautan folder Google Drive di sini - https://drive.google.com/drive/folders/...',
  'Use This Folder': 'Gunakan Folder Ini',
  'Folder link validated': 'Tautan folder berhasil divalidasi',
  'No subfolders in this location.': 'Tidak ada subfolder di lokasi ini.',
  'Select': 'Pilih',
  'Link looks incomplete. Copy the full link from Drive Share.':
      'Tautan tidak lengkap. Salin tautan lengkap dari Drive Share.',
  'My Drive': 'Drive Saya',
  'This file is already in that folder.':
      'File ini sudah berada di folder tersebut.',
  '{file} moved to {folder}.': '{file} dipindahkan ke {folder}.',
  'Unable to move file: {error}': 'Tidak dapat memindahkan file: {error}',
  'Configure Drive destinations': 'Atur tujuan Drive',
  'This Drive folder is empty.': 'Folder Drive ini kosong.',
  'FOLDERS': 'FOLDER',
  'PHOTOS & VIDEOS': 'FOTO & VIDEO',
  'Unnamed folder': 'Folder tanpa nama',
  'Untitled media': 'Media tanpa judul',
  'Set a Drive destination': 'Atur tujuan Drive',
  'Move to Drive folder': 'Pindahkan ke folder Drive',
  'File': 'File',
  'Video': 'Video',
  'Photo': 'Foto',
  'Sorted Folders': 'Folder yang Telah Dipilah',
  '{count} media items': '{count} item media',
  'No photos or videos in this folder yet.':
      'Belum ada foto atau video di folder ini.',
  'Back to albums': 'Kembali ke album',
  'The video is unavailable.': 'Video tidak tersedia.',
  'Unable to access the selected media file.':
      'Tidak dapat mengakses file media yang dipilih.',
  'Google Drive did not return an uploaded file ID.':
      'Google Drive tidak mengembalikan ID file yang diunggah.',
  'The file was uploaded, but could not be removed from this device. A copy remains in Google Drive.': 'File berhasil diunggah, tetapi tidak dapat dihapus dari perangkat ini. Salinannya tetap ada di Google Drive.',
  'Connect Google Drive in Settings first.':
      'Hubungkan Google Drive di Pengaturan terlebih dahulu.',
  'Reconnect Google Drive as {account} to use this destination.': 'Hubungkan kembali Google Drive sebagai {account} untuk menggunakan tujuan ini.',
  'Unable to verify the Drive destination: {error}':
      'Tidak dapat memverifikasi tujuan Drive: {error}',
  'Failed to move file: {error}': 'Gagal memindahkan file: {error}',
  '{file} moved to Trash. Restorable for 30 days.':
      '{file} dipindahkan ke Sampah. Dapat dipulihkan selama 30 hari.',
  '"{file}" moved to Trash. Restorable for 30 days.':
      '"{file}" dipindahkan ke Sampah. Dapat dipulihkan selama 30 hari.',
  'Unable to move this item to Trash: {error}':
      'Tidak dapat memindahkan item ini ke Sampah: {error}',
  'Destination folder not available': 'Folder tujuan tidak tersedia',
  'Unable to save the Drive destination: {error}':
      'Tidak dapat menyimpan tujuan Drive: {error}',
  "Folder '{folder}' was recreated in Drive. Please re-pick the destination.":
      "Folder '{folder}' dibuat ulang di Drive. Pilih kembali tujuan tersebut.",
  'Destination folder not found. It may have been moved or deleted in Drive. Check the folder and try again.': 'Folder tujuan tidak ditemukan. Folder mungkin telah dipindahkan atau dihapus di Drive. Periksa folder tersebut dan coba lagi.',
  'Could not queue {file} for Drive upload: {error}':
      'Tidak dapat menambahkan {file} ke antrean upload Drive: {error}',
  'Moved {count} local item(s) to Trash.':
      '{count} item lokal dipindahkan ke Sampah.',
  'Permanently deleted {count} local item(s).':
      '{count} item lokal dihapus permanen.',
  'The Drive upload finished, but {count} original(s) remain on this device.': 'Upload Drive selesai, tetapi {count} file asli masih ada di perangkat ini.',
  '{count} upload(s) failed; their original files were kept.':
      '{count} upload gagal; file aslinya tetap disimpan.',
  'Bulk deletion could not be completed: {error}':
      'Penghapusan massal tidak dapat diselesaikan: {error}',
  'Choose a destination for "{folder}" in Settings first.':
      'Pilih tujuan untuk "{folder}" di Pengaturan terlebih dahulu.',
  'SETTINGS': 'PENGATURAN',
  'Choose an album to get started': 'Pilih album untuk memulai',
  'Open Trash': 'Buka Sampah',
  'Browse Google Drive': 'Jelajahi Google Drive',
  'Show thumbnails': 'Tampilkan thumbnail',
  'Show as a list': 'Tampilkan sebagai daftar',
  'Target folder settings': 'Pengaturan folder tujuan',
  'Loka Files • Sorting complete': 'Loka Files • Pemilahan selesai',
  'All media in "{album}" have been processed.':
      'Semua media di "{album}" telah diproses.',
  '{count} items': '{count} item',
  'Select Another Folder': 'Pilih Album Lain',
  'No media matching this filter was found in this folder.':
      'Tidak ada media yang sesuai filter ini di album tersebut.',
  '{remaining} of {total} items remaining':
      'Sisa {remaining} dari {total} item',
  'Open Trash - restore items for up to 30 days':
      'Buka Sampah - pulihkan item hingga 30 hari',
  'Item actions': 'Tindakan item',
  'Undo is unavailable for items moved to Trash; restore them from Trash': 'Item yang dipindahkan ke Sampah tidak dapat dibatalkan; pulihkan dari Sampah',
  'Undo is not available for Google Drive transfers':
      'Pemindahan ke Google Drive tidak dapat dibatalkan',
  'Undo Move': 'Batalkan Pemindahan',
  'items': 'item',
  'MOVE TO FOLDER': 'PINDAHKAN KE FOLDER',
  'Edit': 'Ubah',
  'Skip for now': 'Lewati',
  'Configure destination': 'Atur tujuan',
  'OLDEST': 'TERLAMA',
  'NEWEST': 'TERBARU',
  'Filter media type': 'Filter jenis media',
  'All media': 'Semua media',
  'Photos': 'Foto',
  'Videos': 'Video',
  'Unable to play this video. Please try again or open it in your Gallery app.':
      'Tidak dapat memutar video ini. Coba lagi atau buka di aplikasi Galeri.',
  'Unable to save Trash sort order: {error}':
      'Tidak dapat menyimpan urutan Sampah: {error}',
  'Delete permanently?': 'Hapus permanen?',
  'This cannot be undone. Delete {file} permanently?':
      'Tindakan ini tidak dapat dibatalkan. Hapus {file} secara permanen?',
  'This cannot be undone. Delete {count} selected files permanently?': 'Tindakan ini tidak dapat dibatalkan. Hapus {count} file yang dipilih secara permanen?',
  '{file} was restored.': '{file} dipulihkan.',
  '{count} item(s) restored.': '{count} item dipulihkan.',
  '{file} was permanently deleted.': '{file} dihapus permanen.',
  '{count} item(s) permanently deleted.': '{count} item dihapus permanen.',
  'Unable to restore this file: {error}':
      'Tidak dapat memulihkan file ini: {error}',
  'Unable to restore this file': 'Tidak dapat memulihkan file ini',
  'Unable to restore selected files: {error}':
      'Tidak dapat memulihkan file yang dipilih: {error}',
  'Unable to restore selected files':
      'Tidak dapat memulihkan file yang dipilih',
  'Unable to delete this file: {error}':
      'Tidak dapat menghapus file ini: {error}',
  'Unable to delete this file': 'Tidak dapat menghapus file ini',
  'Unable to delete selected files: {error}':
      'Tidak dapat menghapus file yang dipilih: {error}',
  'Unable to delete selected files': 'Tidak dapat menghapus file yang dipilih',
  '"{file}" was restored.': '"{file}" dipulihkan.',
  '"{file}" was permanently deleted.': '"{file}" dihapus permanen.',
  'Unable to preview {file}.': 'Tidak dapat menampilkan pratinjau {file}.',
  'Trash': 'Sampah',
  'Sort Trash': 'Urutkan Sampah',
  'Newest first': 'Terbaru dahulu',
  'Oldest first': 'Terlama dahulu',
  'Newest by original date': 'Tanggal asli terbaru',
  'Oldest by original date': 'Tanggal asli terlama',
  'Show as a grid': 'Tampilkan sebagai kisi',
  'Refresh Trash': 'Segarkan Sampah',
  'Files in Trash are kept for 30 days, then deleted permanently. Tap Restore to bring back.': 'File di Sampah disimpan selama 30 hari, lalu dihapus permanen. Ketuk Pulihkan untuk mengembalikannya.',
  'Your Trash is empty.': 'Sampah Anda kosong.',
  'Restore': 'Pulihkan',
  'Folder: {folder}': 'Folder: {folder}',
  'Deleted {date}': 'Dihapus {date}',
  '{count} day left': 'Sisa {count} hari',
  '{count} days left': 'Sisa {count} hari',
  'Restore ({count})': 'Pulihkan ({count})',
  'Unknown folder': 'Folder tidak diketahui',
  'Unable to load Trash: {error}': 'Tidak dapat memuat Sampah: {error}',
};
