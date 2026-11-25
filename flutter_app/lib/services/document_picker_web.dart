import 'dart:convert';
import 'dart:js_interop';

@JS('prestonPickDocumentFile')
external JSPromise<JSString> _prestonPickDocumentFile();

Future<Map<String, dynamic>> pickWebBrowserDocument() async {
  try {
    final jsStr = await _prestonPickDocumentFile().toDart;
    final raw = jsStr.toDart;
    if (raw.trim().isEmpty) {
      return <String, dynamic>{'picked': false};
    }
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (e) {
    return <String, dynamic>{
      'picked': false,
      'error': e.toString(),
    };
  }
}
