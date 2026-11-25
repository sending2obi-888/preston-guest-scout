import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'document_picker_stub.dart'
    if (dart.library.js_interop) 'document_picker_web.dart';

class PickedDocumentFile {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String base64Data;

  const PickedDocumentFile({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.base64Data,
  });

  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class DocumentPickerService {
  static const MethodChannel _channel =
      MethodChannel('com.prestonmotor.scout/launcher_widget');

  @visibleForTesting
  static Future<PickedDocumentFile?> Function()? mockPickDocumentHandler;

  static Future<PickedDocumentFile?> pickDocument() async {
    if (mockPickDocumentHandler != null) {
      return mockPickDocumentHandler!();
    }

    if (kIsWeb) {
      final res = await pickWebBrowserDocument();
      if (res['error'] != null && res['error'].toString().trim().isNotEmpty) {
        throw Exception(res['error'].toString());
      }
      if (res['picked'] != true) return null;
      final b64 = (res['base64Data']?.toString() ?? '').trim();
      if (b64.isEmpty) return null;
      return PickedDocumentFile(
        fileName: (res['fileName']?.toString() ?? 'uploaded-document').trim(),
        mimeType:
            (res['mimeType']?.toString() ?? 'application/octet-stream').trim(),
        sizeBytes: (res['sizeBytes'] as num?)?.toInt() ?? 0,
        base64Data: b64,
      );
    }

    final raw = await _channel.invokeMethod<dynamic>('pickDocumentFile');
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    if (map['picked'] != true) return null;
    final b64 = (map['base64Data']?.toString() ?? '').trim();
    if (b64.isEmpty) return null;
    return PickedDocumentFile(
      fileName: (map['fileName']?.toString() ?? 'uploaded-document').trim(),
      mimeType:
          (map['mimeType']?.toString() ?? 'application/octet-stream').trim(),
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      base64Data: b64,
    );
  }
}
