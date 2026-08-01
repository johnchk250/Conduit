import 'dart:convert';

const int maxRelativePathBytes = 4096;
const int maxRelativePathSegmentBytes = 255;

final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
  caseSensitive: false,
);

/// Whether [value] is a portable relative file path with no traversal or
/// platform device-name semantics.
///
/// Conduit synchronizes between Windows and Android, so the accepted wire path
/// vocabulary deliberately uses the safe intersection of both platforms.
bool isSafeRelativePath(String value) {
  if (value.isEmpty ||
      value.contains('\u0000') ||
      utf8.encode(value).length > maxRelativePathBytes) {
    return false;
  }

  final normalized = value.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return false;
  }

  final segments = normalized.split('/');
  for (final segment in segments) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        utf8.encode(segment).length > maxRelativePathSegmentBytes ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        segment.codeUnits.any((code) => code < 0x20) ||
        RegExp(r'[<>:"|?*]').hasMatch(segment) ||
        _windowsReservedName.hasMatch(segment)) {
      return false;
    }
  }
  return true;
}

/// A safe user file path that cannot overlap Conduit's internal state.
bool isSyncableRelativePath(String value) {
  if (!isSafeRelativePath(value)) return false;
  final segments = value
      .replaceAll('\\', '/')
      .split('/')
      .map((segment) => segment.toLowerCase())
      .toList(growable: false);
  if (segments.any(
    (segment) => segment == '.syncstate' || segment == '.syncversions',
  )) {
    return false;
  }
  return !segments.last.endsWith('.syncpart');
}

/// Ad-hoc transfers always land directly in the receive folder.
bool isSafeFileName(String value) =>
    !value.contains('/') &&
    !value.contains('\\') &&
    isSyncableRelativePath(value);

String requireSafeRelativePath(String value) {
  if (!isSafeRelativePath(value)) {
    throw const FormatException('Unsafe relative path');
  }
  return value.replaceAll('\\', '/');
}

String requireSyncableRelativePath(String value) {
  if (!isSyncableRelativePath(value)) {
    throw const FormatException('Unsafe sync path');
  }
  return value.replaceAll('\\', '/');
}
