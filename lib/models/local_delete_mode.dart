enum LocalDeleteMode {
  moveToTrash,
  deletePermanently;

  static const preferenceKey = 'drive_upload_delete_mode';

  String get preferenceValue => switch (this) {
    LocalDeleteMode.moveToTrash => 'moveToTrash',
    LocalDeleteMode.deletePermanently => 'deletePermanently',
  };

  static bool isValidPreferenceKey(String key) =>
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(key);

  static LocalDeleteMode fromPreference(String? value) {
    return switch (value) {
      'deletePermanently' => LocalDeleteMode.deletePermanently,
      _ => LocalDeleteMode.moveToTrash,
    };
  }
}
