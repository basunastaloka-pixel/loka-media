import 'dart:io';
import 'dart:math';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum ProFeature { addButtons, drive }

enum ProProduct {
  addButtons(
    'add_buttons',
    'Unlimited target buttons',
    'Unlimited PINDAHKAN buttons',
    30000,
  ),
  drive('drive', 'Google Drive upload', 'Connect Drive and upload', 35000),
  bundle('bundle', 'Pro Bundle', 'Both Pro features', 59000);

  const ProProduct(this.id, this.name, this.description, this.priceRupiah);

  final String id;
  final String name;
  final String description;
  final int priceRupiah;

  String get priceLabel {
    final digits = priceRupiah.toString();
    final groups = <String>[];
    for (var end = digits.length; end > 0; end -= 3) {
      final start = end - 3 < 0 ? 0 : end - 3;
      groups.insert(0, digits.substring(start, end));
    }
    return 'Rp ${groups.join('.')}';
  }
}

class ProEntitlements {
  const ProEntitlements({
    this.addButtons = false,
    this.drive = false,
    this.grandfatheredDrive = false,
    this.trialEndsAt,
    this.verificationError,
  });

  final bool addButtons;
  final bool drive;
  final bool grandfatheredDrive;
  final DateTime? trialEndsAt;
  final String? verificationError;

  bool get trialActive =>
      trialEndsAt != null && trialEndsAt!.isAfter(DateTime.now());
  bool get trialExpired =>
      trialEndsAt != null && !trialEndsAt!.isAfter(DateTime.now());
  bool get hasPro => addButtons || drive;
  bool get hasAnyProAccess => hasPro || grandfatheredDrive || trialActive;
  bool get canAddButtons => addButtons || trialActive;
  bool get canUseDrive => drive || grandfatheredDrive || trialActive;

  bool allows(ProFeature feature) => switch (feature) {
    ProFeature.addButtons => canAddButtons,
    ProFeature.drive => canUseDrive,
  };

  ProEntitlements copyWith({String? verificationError}) => ProEntitlements(
    addButtons: addButtons,
    drive: drive,
    grandfatheredDrive: grandfatheredDrive,
    trialEndsAt: trialEndsAt,
    verificationError: verificationError,
  );
}

class ProEntitlementService {
  ProEntitlementService({
    http.Client? client,
    Uri? endpoint,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _endpoint = endpoint ?? _configuredEndpoint,
       _clock = clock ?? DateTime.now;

  static const _apiUrl = String.fromEnvironment('PRO_LICENSE_API_URL');
  static const midtransMode = String.fromEnvironment(
    'MIDTRANS_MODE',
    defaultValue: 'sandbox',
  );
  static const trialDuration = Duration(days: 3);
  static const freeTargetButtonLimit = 2;

  static final Uri? _configuredEndpoint = _apiUrl.isEmpty
      ? null
      : Uri.tryParse(_apiUrl);

  static const _addButtonsKey = 'loka_pro_add_buttons';
  static const _driveKey = 'loka_pro_drive';
  static const _grandfatheredDriveKey = 'loka_pro_grandfathered_drive';
  static const _legacyDriveCheckKey = 'loka_pro_legacy_drive_checked';
  static const _trialStartKey = 'loka_pro_trial_start_ms';
  static const _trialEndsKey = 'loka_pro_trial_end_ms';
  static const _initialPaywallSeenKey = 'loka_pro_initial_paywall_seen';
  static const _trialExpiredPaywallSeenKey =
      'loka_pro_trial_expired_paywall_seen';
  static const _installIdKey = 'loka_pro_install_id';

  static final ProEntitlementService instance = ProEntitlementService();

  final http.Client _client;
  final Uri? _endpoint;
  final DateTime Function() _clock;

  bool get isConfigured =>
      _endpoint != null &&
      _endpoint.scheme == 'https' &&
      _endpoint.host.isNotEmpty;

  Future<ProEntitlements> loadLocalStatus() async {
    final preferences = await SharedPreferences.getInstance();
    final trialEndMs = preferences.getInt(_trialEndsKey);
    return ProEntitlements(
      addButtons: preferences.getBool(_addButtonsKey) ?? false,
      drive: preferences.getBool(_driveKey) ?? false,
      grandfatheredDrive: preferences.getBool(_grandfatheredDriveKey) ?? false,
      trialEndsAt: trialEndMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(trialEndMs),
    );
  }

  Future<ProEntitlements> refreshStatus() async {
    final local = await loadLocalStatus();
    if (!isConfigured) return local;
    try {
      final response = await _client
          .post(
            _endpoint!,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'action': 'status',
              'installId': await _getInstallId(),
            }),
          )
          .timeout(const Duration(seconds: 15));
      final data = _decodeResponse(response);
      final entitlements = _readEntitlements(data);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_addButtonsKey, entitlements.addButtons);
      await preferences.setBool(_driveKey, entitlements.drive);
      return ProEntitlements(
        addButtons: entitlements.addButtons,
        drive: entitlements.drive,
        grandfatheredDrive: local.grandfatheredDrive,
        trialEndsAt: local.trialEndsAt,
      );
    } catch (error) {
      return local.copyWith(verificationError: error.toString());
    }
  }

  Future<ProEntitlements> refreshFor(ProFeature feature) async {
    final status = await refreshStatus();
    if (!status.allows(feature)) return status;
    return status;
  }

  Future<bool> needsInitialPaywall() async {
    final preferences = await SharedPreferences.getInstance();
    final status = await loadLocalStatus();
    return !status.hasAnyProAccess &&
        !(preferences.getBool(_initialPaywallSeenKey) ?? false);
  }

  Future<void> markInitialPaywallSeen() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_initialPaywallSeenKey, true)) {
      throw StateError('The initial Pro choice could not be saved.');
    }
  }

  Future<bool> needsTrialExpiredPaywall() async {
    final preferences = await SharedPreferences.getInstance();
    final status = await loadLocalStatus();
    return status.trialExpired &&
        !status.hasPro &&
        !(preferences.getBool(_trialExpiredPaywallSeenKey) ?? false);
  }

  Future<void> markTrialExpiredPaywallSeen() async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_trialExpiredPaywallSeenKey, true)) {
      throw StateError('The expired trial paywall state could not be saved.');
    }
  }

  Future<bool> startFreeTrial() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.containsKey(_trialStartKey)) return false;
    final start = _clock();
    final savedEnd = await preferences.setInt(
      _trialEndsKey,
      start.add(trialDuration).millisecondsSinceEpoch,
    );
    final savedStart = await preferences.setInt(
      _trialStartKey,
      start.millisecondsSinceEpoch,
    );
    if (!savedStart || !savedEnd) {
      throw StateError('The free trial could not be saved.');
    }
    await markInitialPaywallSeen();
    return true;
  }

  Future<bool> hasStartedTrial() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.containsKey(_trialStartKey);
  }

  Future<bool> needsLegacyDriveCheck() async {
    final preferences = await SharedPreferences.getInstance();
    return !(preferences.getBool(_legacyDriveCheckKey) ?? false);
  }

  Future<void> completeLegacyDriveCheck({required bool wasConnected}) async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_legacyDriveCheckKey) ?? false) return;
    if (wasConnected && !preferences.containsKey(_trialStartKey)) {
      await preferences.setBool(_grandfatheredDriveKey, true);
    }
    if (!await preferences.setBool(_legacyDriveCheckKey, true)) {
      throw StateError('The legacy Drive access check could not be saved.');
    }
  }

  Future<String> createPayment(ProProduct product) async {
    if (!isConfigured) {
      throw StateError(
        'Pro payments are not configured. Please try again later.',
      );
    }
    final response = await _client
        .post(
          _endpoint!,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'action': 'createPayment',
            'installId': await _getInstallId(),
            'product': product.id,
            'midtransMode': midtransMode,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final data = _decodeResponse(response);
    final paymentUrl = data['paymentUrl'];
    if (paymentUrl is! String) {
      throw const FormatException(
        'Payment service did not return a payment URL.',
      );
    }
    final uri = Uri.tryParse(paymentUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException(
        'Payment service returned an invalid payment URL.',
      );
    }
    return paymentUrl;
  }

  Map<String, Object?> _decodeResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Pro service returned HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pro service returned invalid JSON.');
    }
    if (decoded['error'] is String) {
      throw StateError(decoded['error'] as String);
    }
    return decoded;
  }

  _RemoteEntitlements _readEntitlements(Map<String, Object?> data) {
    final nested = data['entitlements'];
    if (nested != null && nested is! Map<String, dynamic>) {
      throw const FormatException(
        'Pro service returned invalid entitlement data.',
      );
    }
    final values = nested as Map<String, dynamic>? ?? data;
    final rootKeys = nested == null
        ? const {'addButtons', 'drive'}
        : const {'entitlements'};
    if (data.keys.any((key) => !rootKeys.contains(key)) ||
        values.keys.any((key) => key != 'addButtons' && key != 'drive') ||
        values['addButtons'] is! bool ||
        values['drive'] is! bool) {
      throw const FormatException(
        'Pro service returned invalid entitlement data.',
      );
    }
    return _RemoteEntitlements(
      addButtons: values['addButtons'] as bool,
      drive: values['drive'] as bool,
    );
  }

  Future<String> _getInstallId() async {
    final preferences = await SharedPreferences.getInstance();
    final savedId = preferences.getString(_installIdKey);
    if (savedId != null && savedId.isNotEmpty) return savedId;
    final random = Random.secure();
    final id = List<int>.generate(
      24,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    if (!await preferences.setString(_installIdKey, id)) {
      throw StateError('The Pro installation ID could not be saved.');
    }
    return id;
  }

  void close() => _client.close();
}

class _RemoteEntitlements {
  const _RemoteEntitlements({required this.addButtons, required this.drive});

  final bool addButtons;
  final bool drive;
}
