import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/identity.dart';

/// Build a per-device self-signed TLS certificate + private key, written to
/// the app support dir and reused across sessions. The cert CN is the device
/// fingerprint, so peers can sanity-check it against the identity key during
/// pairing.
///
/// We rely on Dart's ability to generate a self-signed cert only via a
/// SecurityContext loaded from PEM files. Since we can't easily mint ASN.1
/// from Dart, we generate an ephemeral EC keypair via `openssl` (bundled on
/// most systems; on Windows we ship a fallback that uses an unverified
/// SecureSocket — see notes). For robustness on Windows where openssl may be
/// absent, we fall back to a plain SecureSocket with a randomly generated
/// in-memory context if available, or to plaintext framing guarded by the
/// application-level ed25519 pinning.
class TlsMaterial {
  TlsMaterial._(this.certFile, this.keyFile);
  final File certFile;
  final File keyFile;

  SecurityContext? _context;
  SecurityContext? get context => _context;

  Future<SecurityContext> buildContext() async {
    if (_context != null) return _context!;
    final ctx = SecurityContext();
    try {
      ctx.useCertificateChain(certFile.path);
      ctx.usePrivateKey(keyFile.path);
    } catch (_) {
      // If PEMs aren't usable, callers fall back to plaintext+pinning.
      return ctx;
    }
    _context = ctx;
    return ctx;
  }
}

/// Generate a self-signed cert PEM pair using openssl if available.
/// Returns null if openssl isn't on PATH (caller will use pinning fallback).
Future<TlsMaterial?> generateSelfSignedCert({
  required DeviceIdentity identity,
  required Directory outDir,
}) async {
  final cn = identity.deviceId.replaceAll('-', '');
  final certPath = '${outDir.path}${Platform.pathSeparator}tls.crt';
  final keyPath = '${outDir.path}${Platform.pathSeparator}tls.key';

  // If already present, reuse.
  final certFile = File(certPath);
  final keyFile = File(keyPath);
  if (await certFile.exists() && await keyFile.exists()) {
    return TlsMaterial._(certFile, keyFile);
  }

  // Try openssl.
  final ok = await _tryOpenssl(cn, certPath, keyPath);
  if (ok) return TlsMaterial._(certFile, keyFile);
  return null;
}

Future<bool> _tryOpenssl(String cn, String certPath, String keyPath) async {
  try {
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      keyPath,
      '-out',
      certPath,
      '-days',
      '3650',
      '-nodes',
      '-subj',
      '/CN=$cn',
      '-addext',
      'basicConstraints=critical,CA:FALSE',
    ]).timeout(const Duration(seconds: 15));
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Fingerprint a public key (used for sanity display / pinning).
String fingerprintOf(String publicKeyB64) {
  final digest = sha256.convert(
    publicKeyB64.codeUnits,
  );
  return digest.toString().substring(0, 16).toUpperCase();
}
