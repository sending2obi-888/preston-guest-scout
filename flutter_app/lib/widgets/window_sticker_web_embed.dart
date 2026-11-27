import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';
import 'window_sticker_web_embed_stub.dart'
    if (dart.library.js_interop) 'window_sticker_web_embed_web.dart' as impl;

Widget buildWebWindowStickerEmbed({
  required String vin,
  Uint8List? pdfBytes,
  String inlineServerUrl = '',
  String ipacketViewerUrl = '',
  double height = 680,
}) =>
    impl.buildWebWindowStickerEmbedImpl(
      vin: vin,
      pdfBytes: pdfBytes,
      inlineServerUrl: inlineServerUrl,
      ipacketViewerUrl: ipacketViewerUrl,
      height: height,
    );

bool triggerWebPdfDownload({
  required Uint8List pdfBytes,
  required String fileName,
}) =>
    impl.triggerWebPdfDownloadImpl(
      pdfBytes: pdfBytes,
      fileName: fileName,
    );
