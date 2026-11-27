import 'dart:typed_data';
import 'package:material_ui/material_ui.dart';

Widget buildWebWindowStickerEmbedImpl({
  required String vin,
  Uint8List? pdfBytes,
  String inlineServerUrl = '',
  String ipacketViewerUrl = '',
  double height = 680,
}) {
  return const SizedBox.shrink();
}

bool triggerWebPdfDownloadImpl({
  required Uint8List pdfBytes,
  required String fileName,
}) {
  return false;
}
