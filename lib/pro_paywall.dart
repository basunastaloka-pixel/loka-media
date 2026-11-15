import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services/app_localizations.dart';
import 'services/pro_entitlement_service.dart';

enum ProPaywallResult { trialStarted, continuedFree, purchased }

class ProPaywall extends StatefulWidget {
  const ProPaywall({
    super.key,
    required this.service,
    this.initial = false,
    this.requiredFeature,
    this.expiredTrial = false,
    this.verificationError,
  });

  final ProEntitlementService service;
  final bool initial;
  final ProFeature? requiredFeature;
  final bool expiredTrial;
  final String? verificationError;

  @override
  State<ProPaywall> createState() => _ProPaywallState();
}

class _ProPaywallState extends State<ProPaywall> {
  ProProduct _selectedProduct = ProProduct.bundle;
  bool _showPrices = false;
  bool _isBusy = false;
  String? _message;
  late String? _error = widget.verificationError;

  bool get _canStartTrial => !widget.expiredTrial;

  String _errorText(Object error) {
    final message = error is StateError
        ? error.message
        : error is FormatException
        ? error.message
        : error.toString();
    return context.tr(message.toString());
  }

  Future<void> _startTrial() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await widget.service.startFreeTrial();
      if (mounted) {
        Navigator.of(context).pop(ProPaywallResult.trialStarted);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _continueFree() async {
    try {
      if (widget.initial) await widget.service.markInitialPaywallSeen();
      if (mounted) {
        Navigator.of(context).pop(ProPaywallResult.continuedFree);
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  Future<void> _buySelectedProduct() async {
    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      final paymentUrl = await widget.service.createPayment(_selectedProduct);
      final launched = await launchUrl(
        Uri.parse(paymentUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError('Unable to open the Midtrans payment page.');
      }
      if (!mounted) return;
      setState(() {
        _message = context.tr(
          'Complete the QRIS payment. Pro access unlocks automatically after payment is confirmed.',
        );
        _isBusy = false;
      });
      unawaited(_pollForPayment());
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _pollForPayment() async {
    for (var attempt = 0; attempt < 36 && mounted; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      final status = await widget.service.refreshStatus();
      final unlocked = widget.requiredFeature == null
          ? status.hasPro || status.trialActive
          : status.allows(widget.requiredFeature!);
      if (unlocked) {
        if (widget.initial) await widget.service.markInitialPaywallSeen();
        if (mounted) {
          Navigator.of(context).pop(ProPaywallResult.purchased);
        }
        return;
      }
      if (status.verificationError != null && mounted) {
        setState(() => _error = status.verificationError);
      }
    }
  }

  Future<void> _checkPaymentStatus() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      final status = await widget.service.refreshStatus();
      final unlocked = widget.requiredFeature == null
          ? status.hasPro || status.trialActive
          : status.allows(widget.requiredFeature!);
      if (unlocked) {
        if (widget.initial) await widget.service.markInitialPaywallSeen();
        if (mounted) {
          Navigator.of(context).pop(ProPaywallResult.purchased);
        }
      } else {
        setState(
          () => _message =
              status.verificationError ??
              context.tr(
                'Payment is not confirmed yet. Please check again shortly.',
              ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return PopScope<ProPaywallResult>(
      canPop: false,
      child: AlertDialog(
        title: Text(
          context.tr(
            widget.expiredTrial ? 'Your free trial has ended' : 'Unlock Pro',
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  'Choose Pro for unlimited target buttons and Google Drive uploads.',
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (ProEntitlementService.midtransMode != 'production' &&
                  widget.service.isConfigured)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    context.tr('Payment mode: {mode}', {
                      'mode': ProEntitlementService.midtransMode,
                    }),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_showPrices) ...[
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: _isBusy,
                  child: RadioGroup<ProProduct>(
                    groupValue: _selectedProduct,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedProduct = value);
                      }
                    },
                    child: Column(
                      children: [
                        for (final product in ProProduct.values)
                          RadioListTile<ProProduct>(
                            value: product,
                            contentPadding: EdgeInsets.zero,
                            title: Text(context.tr(product.name)),
                            subtitle: Text(
                              '${context.tr(product.description)} · ${product.priceLabel}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _isBusy ? null : _buySelectedProduct,
                  icon: _isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.qr_code_2),
                  label: Text(context.tr('Pay with QRIS')),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 8),
                  Text(_message!, style: theme.textTheme.bodySmall),
                  TextButton(
                    onPressed: _isBusy ? null : _checkPaymentStatus,
                    child: Text(context.tr('Check payment')),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_canStartTrial)
                FilledButton(
                  onPressed: _isBusy ? null : _startTrial,
                  child: Text(context.tr('Start 3-Day Free Trial')),
                ),
              TextButton(
                onPressed: _isBusy ? null : _continueFree,
                child: Text(context.tr('Continue for Free')),
              ),
              if (!_showPrices)
                OutlinedButton(
                  onPressed: _isBusy
                      ? null
                      : () => setState(() => _showPrices = true),
                  child: Text(context.tr('View Prices')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
