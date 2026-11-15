import 'package:flutter/material.dart';

import 'services/app_localizations.dart';

enum PaywalledFeature { moreMoveButtons, googleDrive }

Future<void> showFreePaywall(
  BuildContext context, {
  required PaywalledFeature feature,
}) {
  final description = switch (feature) {
    PaywalledFeature.moreMoveButtons =>
      'More move buttons are available in Loka Media Pro.',
    PaywalledFeature.googleDrive =>
      'Google Drive features are available in Loka Media Pro.',
  };

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.tr('Unlock Pro')),
      content: Text(context.tr(description)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Continue for Free')),
        ),
      ],
    ),
  );
}
