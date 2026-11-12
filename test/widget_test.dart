import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:pilah_foto/models/target_folder.dart';
import 'package:pilah_foto/services/drive_oauth_pkce.dart';
import 'package:pilah_foto/services/google_drive_service.dart';
import 'package:pilah_foto/settings_screen.dart';
import 'package:pilah_foto/widgets/drive_folder_picker.dart';

class _FakeGoogleDriveService extends GoogleDriveService {
  String? createdFolderParentId;

  @override
  DriveAccount? get currentUser =>
      const DriveAccount(id: 'user-id', email: 'user@example.com');

  @override
  Future<List<drive.File>> getFolders({String parentId = 'root'}) async {
    return [];
  }

  @override
  Future<drive.File> createFolder({
    required String name,
    required String parentId,
  }) async {
    createdFolderParentId = parentId;
    return drive.File(
      id: 'created-folder-id',
      name: name,
      mimeType: 'application/vnd.google-apps.folder',
    );
  }

  @override
  Future<drive.File?> pickExistingFolder() async {
    return drive.File(
      id: 'existing-folder-id',
      name: 'ASTALOKI',
      mimeType: 'application/vnd.google-apps.folder',
    );
  }
}

void main() {
  test('PKCE challenge follows RFC 7636 S256 vector', () {
    expect(
      createPkceCodeChallenge(
        'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      ),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('Drive destinations survive preference serialization', () {
    final folder = TargetFolder(
      label: 'Archive',
      path: '',
      driveFolderId: 'drive-folder-id',
      driveFolderName: 'Archive',
      driveAccountEmail: 'user@example.com',
    );

    final restored = TargetFolder.fromJson(folder.toJson());

    expect(restored.isDriveDestination, isTrue);
    expect(restored.isConfigured, isTrue);
    expect(restored.driveFolderId, 'drive-folder-id');
    expect(restored.driveFolderName, 'Archive');
    expect(restored.driveAccountEmail, 'user@example.com');
  });

  test('legacy local folder preferences remain valid', () {
    final folder = TargetFolder.fromJson({
      'label': 'Camera',
      'path': '/storage/photos/camera',
    });

    expect(folder.isDriveDestination, isFalse);
    expect(folder.isConfigured, isTrue);
    expect(folder.path, '/storage/photos/camera');
  });

  testWidgets('target folder settings fit a compact mobile screen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialFolders: [
            TargetFolder(label: 'Family', path: '/storage/photos/family'),
            TargetFolder(label: 'Work', path: '/storage/photos/work'),
            TargetFolder(
              label: 'Drive Archive',
              path: '',
              driveFolderId: 'drive-folder-id',
              driveFolderName: 'Archive',
              driveAccountEmail: 'user@example.com',
            ),
          ],
          driveService: GoogleDriveService(),
          onSave: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Target folders'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Local'), findsNWidgets(3));
    expect(find.text('Drive'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new Drive folder appears in the picker with Select action', (
    WidgetTester tester,
  ) async {
    final driveService = _FakeGoogleDriveService();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<DriveFolderSelection>(
                context: context,
                builder: (_) =>
                    DriveFolderPickerModal(driveService: driveService),
              ),
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Buat Folder Baru'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Trips');
    await tester.tap(find.text('Buat'));
    await tester.pumpAndSettle();

    expect(driveService.createdFolderParentId, 'root');
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing Drive folder can be picked and selected', (
    WidgetTester tester,
  ) async {
    final driveService = _FakeGoogleDriveService();
    DriveFolderSelection? selectedFolder;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selectedFolder = await showDialog<DriveFolderSelection>(
                  context: context,
                  builder: (_) =>
                      DriveFolderPickerModal(driveService: driveService),
                );
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pilih Folder Lama'));
    await tester.pumpAndSettle();

    expect(find.text('ASTALOKI'), findsOneWidget);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    expect(selectedFolder?.id, 'existing-folder-id');
    expect(selectedFolder?.name, 'ASTALOKI');
    expect(selectedFolder?.accountEmail, 'user@example.com');
    expect(tester.takeException(), isNull);
  });
}
