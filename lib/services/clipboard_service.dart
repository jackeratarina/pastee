import 'package:flutter/services.dart';

/// Reads and writes plain text on the system clipboard.
class ClipboardService {
  const ClipboardService();

  Future<String?> getText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<void> setText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
