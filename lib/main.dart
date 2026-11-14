import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/providers.dart';
import 'services/storage_service.dart';
import 'ui/home_screen.dart';
import 'ui/lock_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final OpenedStorage storage;
  try {
    storage = await Storage.openDefault();
  } catch (error) {
    runApp(StartupErrorApp(error: error));
    return;
  }

  runApp(
    ProviderScope(
      overrides: [
        pasteStoreProvider.overrideWithValue(storage.pastes),
        settingsStoreProvider.overrideWithValue(storage.settings),
        storageReportProvider.overrideWithValue(storage.report),
      ],
      child: const PasteeApp(),
    ),
  );
}

class PasteeApp extends ConsumerWidget {
  const PasteeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    // Registers the summon shortcut as soon as the app starts.
    ref.watch(hotKeyProvider);

    return MaterialApp(
      title: 'Pastee',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const LockGate(child: HomeScreen()),
    );
  }
}

/// Shown instead of crashing if the data folder can't be opened (no disk
/// space, permissions, another copy of Pastee holding the files…).
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Pastee couldn’t open its saved items',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                    'Your data has not been changed. Close any other copy of Pastee and try again.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                SelectableText('$error', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
