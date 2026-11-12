import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

String createPkceCodeVerifier() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

String createPkceCodeChallenge(String verifier) {
  return base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

String createOAuthState() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

void addOptionalClientSecret(
  Map<String, String> parameters,
  String? clientSecret,
) {
  if (clientSecret != null && clientSecret.trim().isNotEmpty) {
    parameters['client_secret'] = clientSecret;
  }
}
