import 'dart:convert';
import 'dart:io';
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

Map<String, String> createAuthorizationCodeTokenParameters({
  required String clientId,
  required String code,
  required String codeVerifier,
  required String redirectUri,
}) {
  return {
    'client_id': clientId,
    'code': code,
    'code_verifier': codeVerifier,
    'redirect_uri': redirectUri,
    'grant_type': 'authorization_code',
  };
}

Future<HttpRequest> waitForOAuthCallback(HttpServer server) async {
  await for (final request in server) {
    final uri = request.uri;
    if (uri.path == '/' &&
        (uri.queryParameters.containsKey('state') ||
            uri.queryParameters.containsKey('code') ||
            uri.queryParameters.containsKey('error'))) {
      return request;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.set('Cache-Control', 'no-store');
    await request.response.close();
  }

  throw const FormatException(
    'Google OAuth callback server closed before receiving a response.',
  );
}
