class TargetFolder {
  String label;
  String path;
  String? driveFolderId;
  String? driveFolderName;
  String? driveAccountEmail;

  TargetFolder({
    required this.label,
    required this.path,
    this.driveFolderId,
    this.driveFolderName,
    this.driveAccountEmail,
  });

  bool get isDriveDestination => driveFolderId?.isNotEmpty ?? false;
  bool get isConfigured => path.isNotEmpty || isDriveDestination;

  Map<String, dynamic> toJson() => {
    'label': label,
    'path': path,
    'driveFolderId': driveFolderId,
    'driveFolderName': driveFolderName,
    'driveAccountEmail': driveAccountEmail,
  };

  factory TargetFolder.fromJson(Map<String, dynamic> json) {
    return TargetFolder(
      label: json['label'] ?? 'Unnamed',
      path: json['path'] ?? '',
      driveFolderId: json['driveFolderId'],
      driveFolderName: json['driveFolderName'],
      driveAccountEmail: json['driveAccountEmail'],
    );
  }
}
