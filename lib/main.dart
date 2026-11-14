import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:workmanager/workmanager.dart';

import 'app_tour_screen.dart';
import 'services/app_localizations.dart';
import 'services/drive_upload_queue.dart';
import 'sort_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (Platform.isAndroid) {
    await Workmanager().initialize(driveUploadCallbackDispatcher);
  }
  runApp(const PilahFotoApp());
}

class PilahFotoApp extends StatefulWidget {
  const PilahFotoApp({super.key});

  @override
  State<PilahFotoApp> createState() => _PilahFotoAppState();

  static void setThemeMode(BuildContext context, ThemeMode mode) {
    context.findAncestorStateOfType<_PilahFotoAppState>()!.setThemeMode(mode);
  }

  static Future<void> setLanguage(BuildContext context, AppLanguage language) {
    final state = context.findAncestorStateOfType<_PilahFotoAppState>();
    if (state == null) {
      throw StateError('The Loka Files app state is unavailable.');
    }
    return state.setLanguage(language);
  }
}

class _PilahFotoAppState extends State<PilahFotoApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  ThemeMode _themeMode = ThemeMode.system;
  AppLanguage _language = AppLanguage.english;
  bool _isLoadingPreferences = true;
  bool _tourCompleted = false;
  bool _packageMigrationNoticePending = false;
  bool _isShowingPackageMigrationNotice = false;
  Object? _preferencesError;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  void setThemeMode(ThemeMode mode) {
    setState(() => _themeMode = mode);
  }

  Future<void> setLanguage(AppLanguage language) async {
    await AppPreferences.saveLanguage(language);
    if (mounted) setState(() => _language = language);
  }

  Future<void> _loadPreferences() async {
    setState(() {
      _isLoadingPreferences = true;
      _preferencesError = null;
    });
    try {
      final language = await AppPreferences.loadLanguage();
      final tourCompleted = await AppPreferences.hasCompletedTour();
      final packageMigrationNoticeSeen =
          !Platform.isAndroid ||
          await AppPreferences.hasSeenPackageMigrationNotice();
      if (!mounted) return;
      setState(() {
        _language = language;
        _tourCompleted = tourCompleted;
        _packageMigrationNoticePending = !packageMigrationNoticeSeen;
        _isLoadingPreferences = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showPackageMigrationNotice();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preferencesError = error;
        _isLoadingPreferences = false;
      });
    }
  }

  Future<void> _completeFirstTour() async {
    if (mounted) setState(() => _tourCompleted = true);
  }

  Future<void> _showPackageMigrationNotice() async {
    if (!_packageMigrationNoticePending || _isShowingPackageMigrationNotice) {
      return;
    }
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    _isShowingPackageMigrationNotice = true;
    try {
      await showDialog<void>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Text(
            context.tr(
              'This is new package version. Please uninstall old Loka Files (com.example.pilah_foto) after backing up your Target folders.',
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.tr('OK')),
            ),
          ],
        ),
      );
      await AppPreferences.markPackageMigrationNoticeSeen();
      if (mounted) {
        setState(() => _packageMigrationNoticePending = false);
      }
    } catch (error) {
      if (!dialogContext.mounted) return;
      if (mounted) {
        setState(() => _packageMigrationNoticePending = false);
      }
      ScaffoldMessenger.of(dialogContext).showSnackBar(
        SnackBar(
          content: Text(
            dialogContext.tr('Unable to save app settings: {error}', {
              'error': error,
            }),
          ),
        ),
      );
    } finally {
      _isShowingPackageMigrationNotice = false;
    }
  }

  Widget _buildHome() {
    if (_isLoadingPreferences) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_preferencesError case final error?) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr('Unable to load app settings: {error}', {
                    'error': error,
                  }),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _loadPreferences,
                  child: Text(context.tr('Retry')),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_tourCompleted) {
      return AppTourScreen(onCompleted: _completeFirstTour);
    }
    return const SortScreen();
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF171717),
      brightness: brightness,
    );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xFFFAFAFA)
          : null,
      appBarTheme: AppBarTheme(
        backgroundColor: brightness == Brightness.light
            ? const Color(0xFFFAFAFA)
            : colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        centerTitle: false,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Loka Files',
      debugShowCheckedModeBanner: false,
      locale: _language.locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: _buildHome(),
    );
  }
}
