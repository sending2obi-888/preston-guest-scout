import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;
import 'package:material_ui/material_ui.dart';

@JS('Blob')
extension type _JsBlob._(JSObject _) implements JSObject {
  external factory _JsBlob(JSArray<JSAny> blobParts, _JsBlobOptions options);
}

@JS()
@anonymous
extension type _JsBlobOptions._(JSObject _) implements JSObject {
  external factory _JsBlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blob);

@JS('document.createElement')
external JSObject _createElement(String tagName);

extension type _JsIframeElement._(JSObject _) implements JSObject {
  external set src(String value);
  external set title(String value);
  external set allowFullscreen(bool value);
  external _JsStyle get style;
}

extension type _JsAnchorElement._(JSObject _) implements JSObject {
  external set href(String value);
  external set download(String value);
  external set target(String value);
  external void click();
}

extension type _JsStyle._(JSObject _) implements JSObject {
  external set border(String value);
  external set width(String value);
  external set height(String value);
  external set borderRadius(String value);
  external set backgroundColor(String value);
}

final Set<String> _registeredViewTypes = <String>{};
final Map<String, String> _blobUrlByVin = <String, String>{};

String _resolveEmbedUrl({
  required String vin,
  Uint8List? pdfBytes,
  required String inlineServerUrl,
  required String ipacketViewerUrl,
}) {
  if (pdfBytes != null && pdfBytes.isNotEmpty) {
    final existing = _blobUrlByVin['$vin:${pdfBytes.length}'];
    if (existing != null) return existing;
    final parts = <JSAny>[pdfBytes.toJS].toJS;
    final blob = _JsBlob(parts, _JsBlobOptions(type: 'application/pdf'));
    final url = _createObjectUrl(blob);
    _blobUrlByVin['$vin:${pdfBytes.length}'] = url;
    return url;
  }
  if (inlineServerUrl.trim().isNotEmpty) {
    return inlineServerUrl.trim();
  }
  return ipacketViewerUrl.trim();
}

Widget buildWebWindowStickerEmbedImpl({
  required String vin,
  Uint8List? pdfBytes,
  String inlineServerUrl = '',
  String ipacketViewerUrl = '',
  double height = 680,
}) {
  final srcUrl = _resolveEmbedUrl(
    vin: vin,
    pdfBytes: pdfBytes,
    inlineServerUrl: inlineServerUrl,
    ipacketViewerUrl: ipacketViewerUrl,
  );
  if (srcUrl.isEmpty) {
    return const SizedBox.shrink();
  }

  final viewType =
      'window-sticker-iframe-$vin-${srcUrl.hashCode.abs()}';
  if (!_registeredViewTypes.contains(viewType)) {
    _registeredViewTypes.add(viewType);
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final iframe = _JsIframeElement._(_createElement('iframe'));
      iframe.src = srcUrl;
      iframe.title = 'Window Sticker $vin';
      iframe.allowFullscreen = true;
      iframe.style.border = 'none';
      iframe.style.width = '100%';
      iframe.style.height = '100%';
      iframe.style.borderRadius = '12px';
      iframe.style.backgroundColor = '#ffffff';
      return iframe;
    });
  }

  return SizedBox(
    height: height,
    width: double.infinity,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: HtmlElementView(viewType: viewType),
    ),
  );
}

bool triggerWebPdfDownloadImpl({
  required Uint8List pdfBytes,
  required String fileName,
}) {
  if (pdfBytes.isEmpty) return false;
  try {
    final parts = <JSAny>[pdfBytes.toJS].toJS;
    final blob = _JsBlob(parts, _JsBlobOptions(type: 'application/pdf'));
    final url = _createObjectUrl(blob);
    final anchor = _JsAnchorElement._(_createElement('a'));
    anchor.href = url;
    anchor.download = fileName;
    anchor.target = '_blank';
    anchor.click();
    return true;
  } catch (_) {
    return false;
  }
}
