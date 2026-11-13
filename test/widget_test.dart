import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pilah_foto/services/app_update_service.dart';
import 'package:pilah_foto/services/drive_folder_link.dart';
import 'package:pilah_foto/models/local_delete_mode.dart';
import 'package:pilah_foto/models/target_folder.dart';
import 'package:pilah_foto/services/google_drive_service.dart';
import 'package:pilah_foto/services/windows_desktop_oauth.dart';
import 'package:pilah_foto/settings_screen.dart';
import 'package:pilah_foto/widgets/drive_folder_picker.dart';
import 'package:pilah_foto/widgets/video_preview_layout.dart';

class _FakeGoogleDriveService extends GoogleDriveService {
  String? createdFolderParentId;
  String? receivedFolderLink;

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
  Future<drive.File> getFolderFromLink(String link) async {
    receivedFolderLink = link;
    return drive.File(
      id: 'linked-folder-id',
      name: 'LINKED FOLDER',
      mimeType: 'application/vnd.google-apps.folder',
    );
  }
}

Future<int> _getLoopbackStatusCode(Uri uri) async {
  final socket = await Socket.connect(uri.host, uri.port);
  try {
    final requestTarget = '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
    socket.write(
      'GET $requestTarget HTTP/1.1\r\n'
      'Host: ${uri.authority}\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();

    final statusLine = await utf8
        .decoder
        .bind(socket)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    return int.parse(statusLine.split(' ')[1]);
  } finally {
    await socket.close();
  }
}

void main() {
  test('PKCE challenge follows RFC 7636 S256 vector', () {
    expect(
      createPkceCodeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('OAuth callback ignores unrelated loopback requests', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final callbackFuture = waitForOAuthCallback(server);
    final faviconStatusCode = await _getLoopbackStatusCode(
      Uri.parse('http://127.0.0.1:${server.port}/favicon.ico'),
    );
    final callbackResponseFuture = _getLoopbackStatusCode(
      Uri.parse(
        'http://127.0.0.1:${server.port}/?code=auth-code&state=oauth-state',
      ),
    );
    final callback = await callbackFuture;
    expect(callback.uri.queryParameters['code'], 'auth-code');
    expect(callback.uri.queryParameters['state'], 'oauth-state');
    callback.response.statusCode = HttpStatus.ok;
    await callback.response.close();
    expect(
      faviconStatusCode,
      anyOf(HttpStatus.badRequest, HttpStatus.notFound),
    );
    expect(await callbackResponseFuture, HttpStatus.ok);
  });

  test(
    'OAuth authorization-code exchange uses PKCE without a client secret',
    () {
      final parameters = createAuthorizationCodeTokenParameters(
        clientId: 'windows-desktop-client',
        code: 'authorization-code',
        codeVerifier: 'pkce-verifier',
        redirectUri: 'http://127.0.0.1:12345',
      );

      expect(parameters, {
        'client_id': 'windows-desktop-client',
        'code': 'authorization-code',
        'code_verifier': 'pkce-verifier',
        'redirect_uri': 'http://127.0.0.1:12345',
        'grant_type': 'authorization_code',
      });
    },
  );

  test('video preview uses vertical, horizontal, and square aspect ratios', () {
    expect(
      videoDisplayAspectRatio(
        const VideoParams(w: 1080, h: 1920, aspect: 9 / 16),
      ),
      closeTo(9 / 16, 0.001),
    );
    expect(
      videoDisplayAspectRatio(
        const VideoParams(w: 1920, h: 1080, aspect: 16 / 9),
      ),
      closeTo(16 / 9, 0.001),
    );
    expect(
      videoDisplayAspectRatio(
        const VideoParams(w: 1080, h: 1080, aspect: 1),
      ),
      1,
    );
  });

  test('video preview retains its ratio within responsive screen bounds', () {
    for (final aspectRatio in [9 / 16, 16 / 9, 1.0]) {
      for (final screenSize in [
        const Size(390, 844),
        const Size(800, 1280),
        const Size(1280, 800),
      ]) {
        final maxSize = Size(
          screenSize.width * 0.9,
          screenSize.height * 0.9,
        );
        final previewSize = videoPreviewSizeForAspectRatio(
          aspectRatio: aspectRatio,
          maxSize: maxSize,
        );

        expect(previewSize.width, lessThanOrEqualTo(maxSize.width));
        expect(previewSize.height, lessThanOrEqualTo(maxSize.height));
        expect(
          previewSize.width / previewSize.height,
          closeTo(aspectRatio, 0.001),
        );
      }
    }
  });

  test('Drive folder links expose only valid folder IDs', () {
    expect(
      extractDriveFolderId(
        'https://drive.google.com/drive/folders/Abc_123?usp=sharing',
      ),
      'Abc_123',
    );
    expect(
      extractDriveFolderId('https://drive.google.com/open?id=Folder-456'),
      'Folder-456',
    );
    expect(extractDriveFolderId('https://example.com/folders/123'), isNull);
    expect(extractDriveFolderId('not a link'), isNull);
  });

  test('app update versions compare numerically', () {
    expect(
      AppUpdateService.compareVersions('v1.10.0', '1.9.9'),
      greaterThan(0),
    );
    expect(
      AppUpdateService.compareVersions('v1.0.7', '1.0.6+6'),
      greaterThan(0),
    );
    expect(
      AppUpdateService.compareVersions('v1.0.6', '1.0.6+6'),
      0,
    );
    expect(AppUpdateService.compareVersions('1.2.0', 'v1.2.0'), 0);
    expect(AppUpdateService.compareVersions('1.1.9', '1.2.0'), lessThan(0));
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
    SharedPreferences.setMockInitialValues({});
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
    expect(find.text('Check for Update'), findsOneWidget);
    expect(find.text('Local'), findsAtLeastNWidgets(2));
    expect(find.text('Delete Mode'), findsOneWidget);
    expect(
      find.text(
        'Applies only to local files after a successful Google Drive upload.',
      ),
      findsOneWidget,
    );
    expect(find.text('Move to Trash'), findsOneWidget);
    expect(find.text('Delete Permanently'), findsOneWidget);
    final mobileGrid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (mobileGrid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('target folder settings use two columns on wide screens', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialFolders: [
            TargetFolder(label: 'Family', path: '/photos/family'),
            TargetFolder(label: 'Work', path: '/photos/work'),
          ],
          driveService: GoogleDriveService(),
          onSave: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      2,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete mode is saved in SharedPreferences', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    initialFolders: const [],
                    driveService: GoogleDriveService(),
                    onSave: (_) {},
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Permanently'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      preferences.getString(LocalDeleteMode.preferenceKey),
      LocalDeleteMode.deletePermanently.name,
    );
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
              onPressed: () => showModalBottomSheet<DriveFolderSelection>(
                context: context,
                isScrollControlled: true,
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
    await tester.tap(find.text('Create New Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Trips');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(driveService.createdFolderParentId, 'root');
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('folder link tab is isolated and can select a Drive folder', (
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
                selectedFolder =
                    await showModalBottomSheet<DriveFolderSelection>(
                      context: context,
                      isScrollControlled: true,
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
    expect(find.text('Create New Folder'), findsOneWidget);
    expect(find.text('Add Google Drive Folder Editor Link'), findsNothing);
    await tester.tap(find.text('Add Folder Link'));
    await tester.pumpAndSettle();
    expect(find.text('Add Google Drive Folder Editor Link'), findsOneWidget);
    expect(find.text('Create New Folder'), findsNothing);
    const folderLink =
        'https://drive.google.com/drive/folders/linked-folder-id';
    await tester.enterText(find.byType(TextField), folderLink);
    await tester.tap(find.text('Use This Folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select Folder'));
    await tester.pumpAndSettle();

    expect(selectedFolder?.id, 'linked-folder-id');
    expect(selectedFolder?.name, 'LINKED FOLDER');
    expect(selectedFolder?.accountEmail, 'user@example.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Drive folder picker keeps actions visible with keyboard open', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPhysicalSize);

    for (final screenSize in [
      const Size(390, 844),
      const Size(800, 1280),
      const Size(1280, 800),
    ]) {
      final driveService = _FakeGoogleDriveService();
      tester.view.physicalSize = screenSize;
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<DriveFolderSelection>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (sheetContext) => Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
                    ),
                    child: MediaQuery.removeViewInsets(
                      context: sheetContext,
                      removeBottom: true,
                      child: DriveFolderPickerModal(driveService: driveService),
                    ),
                  ),
                ),
                child: const Text('Open picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Folder Link'));
      await tester.pumpAndSettle();

      expect(find.text('Add Google Drive Folder Editor Link'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Drive link');
      await tester.pump();
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Select Folder'), findsOneWidget);
      final unobscuredHeight = screenSize.height - 320;
      expect(
        tester.getRect(find.text('Cancel')).bottom,
        lessThanOrEqualTo(unobscuredHeight),
      );
      expect(
        tester.getRect(find.text('Select Folder')).bottom,
        lessThanOrEqualTo(unobscuredHeight),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('pasted Drive folder link can be validated and selected', (
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
                selectedFolder =
                    await showModalBottomSheet<DriveFolderSelection>(
                      context: context,
                      isScrollControlled: true,
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
    await tester.tap(find.text('Add Folder Link'));
    await tester.pumpAndSettle();
    const folderLink =
        'https://drive.google.com/drive/folders/linked-folder-id';
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), folderLink);
    await tester.tap(find.text('Use This Folder'));
    await tester.pumpAndSettle();

    expect(driveService.receivedFolderLink, folderLink);
    expect(find.text('LINKED FOLDER'), findsOneWidget);
    await tester.tap(find.text('Select Folder'));
    await tester.pumpAndSettle();
    expect(selectedFolder?.id, 'linked-folder-id');
    expect(selectedFolder?.name, 'LINKED FOLDER');
    expect(tester.takeException(), isNull);
  });
}
