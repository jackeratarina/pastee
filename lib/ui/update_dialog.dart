import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../providers/providers.dart';
import '../providers/update_provider.dart';
import '../services/browser.dart';
import '../services/update_installer.dart';
import '../services/updates.dart';
import 'theme.dart';

/// Opens [url] in the browser; tests replace it.
final openUrlProvider =
    Provider<Future<bool> Function(Uri url)>((ref) => openInBrowser);

/// What's new in the releases since this one, and the button that installs
/// the newest.
Future<void> showUpdateDialog(BuildContext context) {
  return showDialog<void>(
      context: context, builder: (_) => const UpdateDialog());
}

class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final update = ref.watch(updateProvider);
    final probe = ref.watch(installProbeProvider);
    final notifier = ref.read(updateProvider.notifier);
    final latest = update.latest;
    final target = probe.target;
    final asset =
        target == null ? null : latest?.assetEndingWith(target.assetSuffix);

    void close() {
      notifier.clearInstallError();
      Navigator.of(context).pop();
    }

    Future<void> openPage() async {
      await ref.read(openUrlProvider)(latest?.page ?? releasesPage);
    }

    final List<Widget> actions;
    if (update.stage == UpdateStage.downloading) {
      actions = [
        TextButton(onPressed: notifier.cancel, child: const Text('Cancel')),
      ];
    } else if (update.busy) {
      actions = const [];
    } else if (latest == null) {
      actions = [
        FilledButton(
            autofocus: true, onPressed: close, child: const Text('Close')),
      ];
    } else {
      actions = [
        if (latest.version != update.skipped)
          TextButton(
            onPressed: () {
              notifier.skip();
              close();
            },
            child: const Text('Skip this version'),
          ),
        TextButton(onPressed: close, child: const Text('Later')),
        if (asset != null)
          FilledButton.icon(
            key: const ValueKey('installUpdate'),
            autofocus: true,
            onPressed: notifier.install,
            icon: const Icon(Icons.system_update_alt_rounded, size: 18),
            label: const Text('Update and restart'),
          )
        else
          FilledButton.icon(
            autofocus: true,
            onPressed: openPage,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Download from GitHub'),
          ),
      ];
    }

    return PopScope(
      canPop: !update.busy,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt_rounded, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Update Pastee',
                          style: theme.textTheme.titleLarge),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: update.busy ? null : close,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        latest == null
                            ? 'Pastee ${update.current ?? ''} is up to date.'
                            : 'Pastee ${latest.version} is available. '
                                'You have ${update.current}.',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      for (final release in update.newer.take(5)) ...[
                        const SizedBox(height: 16),
                        _ReleaseHeading(release),
                        const SizedBox(height: 4),
                        ReleaseNotesView(release.notes),
                      ],
                      if (update.newer.length > 5)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: TextButton.icon(
                            onPressed: openPage,
                            icon:
                                const Icon(Icons.open_in_new_rounded, size: 16),
                            label: Text(
                                'And ${update.newer.length - 5} more on GitHub'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              if (latest != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: _UpdateStatus(
                    update: update,
                    probe: probe,
                    release: latest,
                    asset: asset,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress while updating, otherwise what "Update and restart" will do, or
/// why Pastee can't do it.
class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus({
    required this.update,
    required this.probe,
    required this.release,
    required this.asset,
  });

  final UpdateState update;
  final InstallProbe probe;
  final Release release;
  final ReleaseAsset? asset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;

    Widget progress(double? value, String text) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: value),
            const SizedBox(height: 6),
            Text(text, style: small),
          ],
        );

    switch (update.stage) {
      case UpdateStage.preparing:
        return progress(null, 'Looking for the newest release…');
      case UpdateStage.downloading:
        final size = update.size;
        return progress(
          size > 0 ? update.received / size : null,
          'Downloading Pastee ${(update.installing ?? release).version}… '
          '${megabytes(update.received)} of ${megabytes(size)}',
        );
      case UpdateStage.installing:
        return progress(
            null,
            switch (update.step) {
              InstallStep.waitingForPassword =>
                'Installing the package. Enter your password if your system asks for it…',
              InstallStep.startingSetup => 'Starting the setup…',
              _ => 'Unpacking and checking the new version…',
            });
      case UpdateStage.restarting:
        return progress(null, 'Restarting Pastee…');
      case UpdateStage.idle:
      case UpdateStage.checking:
        break;
    }

    final error = update.installError;
    if (error != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child:
                SelectableText(error, style: small?.copyWith(color: cs.error)),
          ),
        ],
      );
    }
    final target = probe.target;
    final String text;
    if (target == null) {
      text = probe.problem ?? '';
    } else if (asset == null) {
      text = 'This release has no download for this computer '
          '(…${target.assetSuffix}). Get it from GitHub instead.';
    } else {
      text = '${_plan(target)} (${megabytes(asset!.size)})';
    }
    return Text(text, style: small?.copyWith(color: cs.onSurfaceVariant));
  }

  static String _plan(InstallTarget target) {
    final folder = p.dirname(target.path);
    return switch (target.kind) {
      InstallKind.macApp =>
        'Pastee downloads the new version, checks it, replaces itself in '
            '$folder and opens again.',
      InstallKind.windowsSetup =>
        'Pastee downloads the new setup, checks it and closes. The setup '
            'updates Pastee and opens it again.',
      InstallKind.windowsPortable =>
        'Pastee downloads the new version, checks it, replaces its files in '
            '${target.path} and opens again.',
      InstallKind.linuxDeb =>
        'Pastee downloads the new package, checks it and installs it with '
            'apt, which asks for your password. Then Pastee opens again.',
      InstallKind.linuxTarball =>
        'Pastee downloads the new version, checks it, replaces its folder '
            '${target.path} and opens again.',
    };
  }
}

class _ReleaseHeading extends StatelessWidget {
  const _ReleaseHeading(this.release);

  final Release release;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = release.publishedAt;
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: 'Pastee ${release.version}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (date != null)
          TextSpan(
            text: '  ·  ${shortDate(date.toLocal())}',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
      ]),
      style: theme.textTheme.titleSmall,
    );
  }
}

/// The few kinds of Markdown that release notes use: headings, bullets,
/// **bold**, `code` and links (shown as their text).
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView(this.markdown, {super.key});

  final String markdown;

  static final _inline =
      RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\([^)]*\)');
  static final _bullet = RegExp(r'^\s*[-*] +');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium;
    final mono = TextStyle(
      fontFamily: AppTheme.monoFont,
      fontFamilyFallback: AppTheme.monoFallback,
      fontSize: (body?.fontSize ?? 14) - 1,
    );

    List<InlineSpan> spans(String text) {
      final result = <InlineSpan>[];
      var last = 0;
      for (final match in _inline.allMatches(text)) {
        if (match.start > last) {
          result.add(TextSpan(text: text.substring(last, match.start)));
        }
        if (match[1] != null) {
          result.add(TextSpan(
              text: match[1],
              style: const TextStyle(fontWeight: FontWeight.w700)));
        } else if (match[2] != null) {
          result.add(TextSpan(text: match[2], style: mono));
        } else {
          result.add(TextSpan(text: match[3]));
        }
        last = match.end;
      }
      if (last < text.length) result.add(TextSpan(text: text.substring(last)));
      return result;
    }

    // Bullets can go on over several lines; collect them first.
    final blocks = <(String kind, String text)>[];
    for (final raw in markdown.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        blocks.add(('gap', ''));
      } else if (line.startsWith('#')) {
        blocks.add(('heading', line.replaceFirst(RegExp(r'^#+\s*'), '')));
      } else if (_bullet.hasMatch(line)) {
        blocks.add(('bullet', line.replaceFirst(_bullet, '')));
      } else if (blocks.isNotEmpty &&
          blocks.last.$1 != 'gap' &&
          blocks.last.$1 != 'heading') {
        final (kind, text) = blocks.removeLast();
        blocks.add((kind, '$text ${line.trim()}'));
      } else {
        blocks.add(('text', line.trim()));
      }
    }

    final children = <Widget>[];
    for (final (kind, text) in blocks) {
      switch (kind) {
        case 'gap':
          if (children.isNotEmpty) children.add(const SizedBox(height: 4));
        case 'heading':
          children.add(Padding(
            padding: EdgeInsets.only(top: children.isEmpty ? 0 : 6, bottom: 2),
            child: Text(text,
                style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary)),
          ));
        case 'bullet':
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: body),
                Expanded(
                    child: Text.rich(TextSpan(children: spans(text)),
                        style: body)),
              ],
            ),
          ));
        default:
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(TextSpan(children: spans(text)), style: body),
          ));
      }
    }
    if (children.isEmpty) {
      children.add(Text('No notes for this release.',
          style: body?.copyWith(color: theme.colorScheme.onSurfaceVariant)));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// Settings → Updates: the version, whether there's a newer one, and the
/// automatic check.
class UpdateSettings extends ConsumerWidget {
  const UpdateSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final update = ref.watch(updateProvider);
    final automatic =
        ref.watch(settingsProvider.select((s) => s.checkForUpdates));
    final notifier = ref.read(updateProvider.notifier);
    final current = update.current;
    final small = theme.textTheme.bodySmall;

    if (current == null) {
      return Text(
        'This is a development build, so it doesn’t update itself.',
        style: small?.copyWith(color: cs.onSurfaceVariant),
      );
    }

    final latest = update.latest;
    final checking = update.stage == UpdateStage.checking;
    final (IconData icon, Color color, String text) = switch (update) {
      _ when checking => (
          Icons.hourglass_empty,
          cs.onSurfaceVariant,
          'Checking for updates…'
        ),
      _ when latest != null => (
          Icons.system_update_alt_rounded,
          cs.primary,
          'Pastee ${latest.version} is available. You have $current.'
        ),
      UpdateState(checkError: final String error) => (
          Icons.error_outline,
          cs.error,
          'Couldn’t check for updates. $error'
        ),
      UpdateState(lastChecked: final DateTime last) => (
          Icons.check_circle_outline,
          Colors.green.shade600,
          'Pastee $current is up to date. Checked ${timeAgo(last, clock.now())}.'
        ),
      _ => (
          Icons.info_outline,
          cs.onSurfaceVariant,
          'You have Pastee $current.'
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  key: const ValueKey('updateStatus'),
                  style: small?.copyWith(
                      color: color == cs.onSurfaceVariant ? null : color)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (latest != null)
              FilledButton.tonal(
                onPressed: update.busy ? null : () => showUpdateDialog(context),
                child: const Text('Update…'),
              ),
            OutlinedButton(
              onPressed: checking || update.busy ? null : notifier.check,
              child: const Text('Check now'),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Check for updates automatically'),
          subtitle: const Text(
              'Once a day, Pastee asks GitHub whether there’s a new release. '
              'Nothing else is sent: your items never leave this computer.'),
          value: automatic,
          onChanged: (on) =>
              ref.read(settingsProvider.notifier).setCheckForUpdates(on),
        ),
      ],
    );
  }
}

String megabytes(int bytes) => '${(bytes / 1000000).toStringAsFixed(1)} MB';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "17 Nov 2026".
String shortDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// "just now", "5 minutes ago", "yesterday"…
String timeAgo(DateTime then, DateTime now) {
  final elapsed = now.difference(then);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) {
    return elapsed.inMinutes == 1
        ? 'a minute ago'
        : '${elapsed.inMinutes} minutes ago';
  }
  if (elapsed.inHours < 24) {
    return elapsed.inHours == 1
        ? 'an hour ago'
        : '${elapsed.inHours} hours ago';
  }
  if (elapsed.inDays == 1) return 'yesterday';
  return '${elapsed.inDays} days ago';
}
