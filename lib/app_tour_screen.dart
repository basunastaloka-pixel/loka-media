import 'package:flutter/material.dart';

import 'services/app_localizations.dart';

class AppTourScreen extends StatefulWidget {
  final Future<void> Function() onCompleted;

  const AppTourScreen({super.key, required this.onCompleted});

  @override
  State<AppTourScreen> createState() => _AppTourScreenState();
}

class _AppTourScreenState extends State<AppTourScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isCompleting = false;

  static const _pages = [
    (
      icon: Icons.photo_library_outlined,
      title: 'Welcome to Loka Files',
      description: 'Sort 1000 photos in minutes. 1 tap moves a photo to the Drive folder you chose.',
    ),
    (
      icon: Icons.drive_file_move_outline,
      title: 'Set your folders first',
      description: 'Create Target folders in Target folders screen. Each folder is a button when you sort.',
    ),
    (
      icon: Icons.touch_app_outlined,
      title: 'Sort with 1 tap',
      description: "Open an album, select photos, tap a folder button like 'tes move'. Done.",
    ),
    (
      icon: Icons.delete_outline,
      title: 'Safe Trash',
      description: 'After upload to Drive, your local photo moves to Trash for 30 days. You can Restore it.',
    ),
    (
      icon: Icons.cloud_upload_outlined,
      title: 'Drive Upload is Pro',
      description: 'Connect Drive with your Google email. Free users can sort locally. Pro unlocks Move to Drive.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeTour() async {
    if (_isCompleting) return;
    setState(() => _isCompleting = true);
    try {
      await AppPreferences.markTourCompleted();
      await widget.onCompleted();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('Unable to save App Tour setting: {error}', {
              'error': error,
            }),
          ),
        ),
      );
      setState(() => _isCompleting = false);
    }
  }

  void _nextPage() {
    if (_currentPage == _pages.length - 1) {
      _completeTour();
    } else {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('App Tour')),
        actions: [
          TextButton(
            onPressed: _isCompleting ? null : _completeTour,
            child: Text(context.tr('Skip')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (page) => setState(() => _currentPage = page),
                itemBuilder: (context, index) {
                  final page = _pages[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 112,
                          height: 112,
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            page.icon,
                            size: 54,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          context.tr(page.title),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          context.tr(page.description),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      _pages.length,
                      (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: index == _currentPage ? 22 : 8,
                        height: 8,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: index == _currentPage
                              ? colors.primary
                              : colors.outlineVariant,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _isCompleting ? null : _nextPage,
                      child: Text(
                        context.tr(
                          _currentPage == _pages.length - 1
                              ? 'Get Started'
                              : 'Next',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
