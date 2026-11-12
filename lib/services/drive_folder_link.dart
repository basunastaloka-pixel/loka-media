String? extractDriveFolderId(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !const {'drive.google.com', 'www.drive.google.com'}.contains(uri.host)) {
    return null;
  }

  final segments = uri.pathSegments;
  final foldersIndex = segments.indexOf('folders');
  final folderId = foldersIndex >= 0 && foldersIndex + 1 < segments.length
      ? segments[foldersIndex + 1]
      : uri.queryParameters['id'];
  if (folderId == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(folderId)) {
    return null;
  }
  return folderId;
}
