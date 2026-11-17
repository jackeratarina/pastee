import 'dart:io';

/// Opens [url] in the default browser. Only https links are opened. Returns
/// false if no browser could be started.
Future<bool> openInBrowser(Uri url) async {
  if (url.scheme != 'https') return false;
  final link = '$url';
  final (String program, List<String> arguments) =
      switch (Platform.operatingSystem) {
    'macos' => ('/usr/bin/open', [link]),
    // By full path: Windows looks for a bare program name in Pastee's own
    // folder first.
    'windows' => (
        '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\rundll32.exe',
        ['url.dll,FileProtocolHandler', link]
      ),
    'linux' => ('xdg-open', [link]),
    _ => ('', <String>[]),
  };
  if (program.isEmpty) return false;
  try {
    await Process.start(program, arguments, mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}
