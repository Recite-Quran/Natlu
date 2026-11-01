import 'dart:typed_data';

/// Stub implementation for non-web platforms (Windows, Android, iOS, macOS, Linux).
Future<bool> hasCachedPagesWeb() async => false;
Future<Uint8List?> getPageFromIndexedDb(String key) async => null;
Future<void> savePagesBatchToIndexedDb(Map<String, Uint8List> pages) async {}

