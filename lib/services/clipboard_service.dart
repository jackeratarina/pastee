import 'package:flutter/services.dart';

class ClipboardService {
  Future<String?> getText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<void> setText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
