import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:clock/clock.dart' as clock_package;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../services/storage_service.dart';
import '../services/update_installer.dart';
import '../services/updates.dart';
import '../version.dart';
import 'providers.dart';

// ── services (overridden in tests) ───────────────────────────────────────

final releaseSourceProvider = Provider<ReleaseSource>(
    (ref) => GitHubReleaseSource(userAgent: 'Pastee/$appVersion'));

final updateInstallerProvider =
    Provider<UpdateInstaller>((ref) => SystemUpdateInstaller());

/// The running version. Null for a development build, which never updates
/// itself.
final runningVersionProvider =
    Provider<Version?>((ref) => Version.tryParse(appVersion));

/// Quits Pastee so the update can take its place.
final quitForUpdateProvider =
    Provider<Future<void> Function()>((ref) => quitPastee);

/// How this copy of Pastee can update itself, or why it can't.
final installProbeProvider =
    Provider<InstallProbe>((ref) => ref.watch(updateInstallerProvider).probe());

/// Quits like ⌘Q or closing the window, so the native side tidies up (a copied
/// secret leaves the clipboard). If that doesn't happen within a few seconds,
/// the process ends anyway.
Future<void> quitPastee() async {
  Timer(const Duration(seconds: 3), () => exit(0));
  await ServicesBinding.instance.exitApplication(AppExitType.required);
}

// ── state ────────────────────────────────────────────────────────────────

enum UpdateStage {
  idle,
  checking,

  /// Asking GitHub again for the newest release, just before downloading it.
  preparing,
  downloading,
  installing,
  restarting,
}

/// Shown once after Pastee restarts from an update.
@immutable
class UpdateNotice {
  const UpdateNotice(
      {required this.version, required this.installed, this.page});

  /// The version the update was to.
  final Version version;

  /// Its release on GitHub, with what's new.
  final Uri? page;

  /// False: Pastee started again on the old version, so something stopped
  /// the new one from going in.
  final bool installed;
}

@immutable
class UpdateState {
  const UpdateState({
    this.current,
    this.stage = UpdateStage.idle,
    this.newer = const [],
    this.lastChecked,
    this.checkError,
    this.installError,
    this.received = 0,
    this.size = 0,
    this.step,
    this.skipped,
    this.notice,
    this.installing,
  });

  /// The running version; null for a development build.
  final Version? current;
  final UpdateStage stage;

  /// The releases newer than [current], newest first, as of [lastChecked].
  final List<Release> newer;
  final DateTime? lastChecked;

  /// Why the last check failed.
  final String? checkError;

  /// Why the last update attempt failed.
  final String? installError;

  /// Download progress, in bytes.
  final int received;
  final int size;
  final InstallStep? step;

  /// The version the user chose to skip.
  final Version? skipped;
  final UpdateNotice? notice;

  /// The release being downloaded and installed.
  final Release? installing;

  Release? get latest => newer.firstOrNull;

  /// Whether to point the user at [latest]: there is one, and they didn't
  /// skip it.
  bool get offered => latest != null && latest!.version != skipped;

  /// Updating, until Pastee quits.
  bool get busy =>
      stage == UpdateStage.preparing ||
      stage == UpdateStage.downloading ||
      stage == UpdateStage.installing ||
      stage == UpdateStage.restarting;

  UpdateState copyWith({
    UpdateStage? stage,
    List<Release>? newer,
    DateTime? Function()? lastChecked,
    String? Function()? checkError,
    String? Function()? installError,
    int? received,
    int? size,
    InstallStep? Function()? step,
    Version? Function()? skipped,
    UpdateNotice? Function()? notice,
    Release? Function()? installing,
  }) {
    return UpdateState(
      current: current,
      stage: stage ?? this.stage,
      newer: newer ?? this.newer,
      lastChecked: lastChecked != null ? lastChecked() : this.lastChecked,
      checkError: checkError != null ? checkError() : this.checkError,
      installError: installError != null ? installError() : this.installError,
      received: received ?? this.received,
      size: size ?? this.size,
      step: step != null ? step() : this.step,
      skipped: skipped != null ? skipped() : this.skipped,
      notice: notice != null ? notice() : this.notice,
      installing: installing != null ? installing() : this.installing,
    );
  }
}

// ── checking, downloading, installing ────────────────────────────────────

final updateProvider =
    StateNotifierProvider<UpdateNotifier, UpdateState>((ref) {
  final notifier = UpdateNotifier(
    store: ref.watch(settingsStoreProvider),
    source: ref.watch(releaseSourceProvider),
    installer: ref.watch(updateInstallerProvider),
    current: ref.watch(runningVersionProvider),
    automatic: () => ref.read(settingsProvider).checkForUpdates,
    quit: ref.watch(quitForUpdateProvider),
  );
  ref.listen<bool>(settingsProvider.select((s) => s.checkForUpdates), (_, on) {
    if (on) notifier.checkIfDue();
  });
  return notifier;
});

/// Checks GitHub for a new release once a day (if the user lets it), and
/// downloads, checks and installs one when asked.
class UpdateNotifier extends StateNotifier<UpdateState> {
  UpdateNotifier({
    required SettingsStore store,
    required ReleaseSource source,
    required UpdateInstaller installer,
    required Version? current,
    required bool Function() automatic,
    required Future<void> Function() quit,
    DateTime Function()? now,
  })  : _store = store,
        _source = source,
        _installer = installer,
        _automatic = automatic,
        _quit = quit,
        _now = now ?? (() => clock_package.clock.now()),
        super(_load(store, current)) {
    if (current == null) return;
    _readPending();
    _timers.add(Timer(startupDelay, checkIfDue));
    _timers.add(Timer.periodic(const Duration(hours: 1), (_) => checkIfDue()));
    _timers.add(Timer(const Duration(seconds: 30), cleanUp));
  }

  /// How often Pastee checks by itself.
  static const checkInterval = Duration(hours: 24);

  /// The first automatic check waits this long after Pastee starts.
  static const startupDelay = Duration(seconds: 8);

  final SettingsStore _store;
  final ReleaseSource _source;
  final UpdateInstaller _installer;
  final bool Function() _automatic;
  final Future<void> Function() _quit;
  final DateTime Function() _now;
  final List<Timer> _timers = [];
  Future<void>? _checking;
  Completer<void>? _cancel;

  static const _kLastCheck = 'update.lastCheck';
  static const _kNewer = 'update.newer';
  static const _kSkipped = 'update.skipped';
  static const _kPending = 'update.pending';
  static const _kLeftovers = 'update.leftovers';

  static UpdateState _load(SettingsStore store, Version? current) {
    if (current == null) return const UpdateState();
    final last = store.read(_kLastCheck);
    final cached = store.read(_kNewer);
    return UpdateState(
      current: current,
      lastChecked:
          last is int ? DateTime.fromMillisecondsSinceEpoch(last) : null,
      // What the last check found, minus what this version already is (it
      // was installed since).
      newer: [
        if (cached is List)
          for (final json in cached)
            if (Release.fromJson(json) case final release?)
              if (release.version > current) release,
      ]..sort((a, b) => b.version.compareTo(a.version)),
      skipped: Version.tryParse(store.read(_kSkipped) as String?),
    );
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _cancel?.complete();
    super.dispose();
  }

  /// Checks if automatic checks are on and the last one is a day old.
  void checkIfDue() {
    if (!mounted || state.current == null || !_automatic()) return;
    final last = state.lastChecked;
    final now = _now();
    // A clock set back makes the last check look like it's in the future.
    if (last != null &&
        !last.isAfter(now) &&
        now.difference(last) < checkInterval) {
      return;
    }
    check();
  }

  /// Asks GitHub for the releases now.
  Future<void> check() => _checking ??= _check().whenComplete(() {
        _checking = null;
      });

  Future<void> _check() async {
    final current = state.current;
    if (current == null || state.busy) return;
    state = state.copyWith(stage: UpdateStage.checking);
    try {
      final releases = await _source.releases();
      if (!mounted) return;
      await _remember(releases, current);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        stage: _afterCheck,
        checkError: () => error is UpdateException
            ? error.message
            : 'Pastee couldn’t check for updates: $error',
      );
    }
  }

  /// Keeps what GitHub just said: shown now, and after a restart until the
  /// next check. Returns the releases newer than [current], newest first.
  Future<List<Release>> _remember(
      List<Release> releases, Version current) async {
    final newer = [
      for (final release in releases)
        if (release.version > current) release,
    ]..sort((a, b) => b.version.compareTo(a.version));
    final now = _now();
    if (mounted) {
      state = state.copyWith(
        stage: _afterCheck,
        newer: newer,
        lastChecked: () => now,
        checkError: () => null,
      );
    }
    await _store.write(_kLastCheck, now.millisecondsSinceEpoch);
    await _store.write(_kNewer,
        newer.isEmpty ? null : [for (final r in newer.take(10)) r.toJson()]);
    return newer;
  }

  /// An update the user started while the check ran keeps going.
  UpdateStage get _afterCheck =>
      state.stage == UpdateStage.checking ? UpdateStage.idle : state.stage;

  /// Stops pointing at [UpdateState.latest] until a newer one comes out.
  Future<void> skip() async {
    final latest = state.latest;
    if (latest == null) return;
    state = state.copyWith(skipped: () => latest.version);
    await _store.write(_kSkipped, '${latest.version}');
  }

  void clearNotice() => state = state.copyWith(notice: () => null);

  void clearInstallError() => state = state.copyWith(installError: () => null);

  /// Stops a download in progress.
  void cancel() {
    if (state.stage == UpdateStage.downloading) {
      final cancel = _cancel;
      if (cancel != null && !cancel.isCompleted) cancel.complete();
    }
  }

  /// Downloads the newest release, checks it against the release's
  /// checksums, puts it in place and quits, so Pastee starts again as the
  /// new version.
  ///
  /// It asks GitHub for the releases again first: what the last check found
  /// may be a day old, pulled since, or overtaken by a newer one.
  Future<void> install() async {
    final current = state.current;
    if (state.latest == null || state.busy || current == null) return;
    final probe = _installer.probe();
    final target = probe.target;
    if (target == null) {
      state = state.copyWith(installError: () => probe.problem);
      return;
    }
    final cancel = _cancel = Completer<void>();
    state = state.copyWith(
      stage: UpdateStage.preparing,
      received: 0,
      size: 0,
      installError: () => null,
      step: () => null,
      installing: () => null,
    );
    Directory? work;
    // Once the installer has started its helper, the folders it returned
    // belong to that helper.
    var handedOver = false;
    try {
      final releases = await _source.releases();
      final newer = await _remember(releases, current);
      if (newer.isEmpty) {
        throw UpdateException('GitHub no longer offers a Pastee newer than '
            '$current, so there’s nothing to install.');
      }
      final release = newer.first;
      final asset = release.assetEndingWith(target.assetSuffix);
      if (asset == null) {
        throw UpdateException('Pastee ${release.version} has no download '
            'for this computer (…${target.assetSuffix}).');
      }
      if (cancel.isCompleted) throw const UpdateCancelled();
      state = state.copyWith(
        stage: UpdateStage.downloading,
        size: asset.size,
        installing: () => release,
      );
      work = await _installer.createWorkspace();
      // A release without checksums is never installed, so get them first.
      final sumsFile = release.checksums;
      final sums = sumsFile == null
          ? null
          : parseChecksums(await _source.fetchText(sumsFile.url));
      final expected = expectedChecksum(asset, sums);
      if (cancel.isCompleted) throw const UpdateCancelled();
      final file = File(p.join(work.path, asset.name));
      final actual = await _source.download(
        asset.url,
        file,
        size: asset.size,
        cancel: cancel.future,
        onProgress: (received) {
          if (mounted) state = state.copyWith(received: received);
        },
      );
      if (actual != expected) {
        throw const UpdateException('The download was damaged on the way: '
            'its checksum doesn’t match. Try again.');
      }
      if (cancel.isCompleted) throw const UpdateCancelled();
      if (!mounted) return;
      state = state.copyWith(stage: UpdateStage.installing);
      final keep =
          await _installer.install(file, release, target, onStep: (step) {
        if (mounted) state = state.copyWith(step: () => step);
      });
      handedOver = true;
      if (!keep.contains(work.path)) await _installer.discard(work.path);
      await _store.write(_kPending, {
        'from': '$current',
        'to': '${release.version}',
        'at': _now().millisecondsSinceEpoch,
        'page': '${release.page}',
        'leftovers': keep,
      });
      if (!mounted) return;
      state = state.copyWith(stage: UpdateStage.restarting);
      await _quit();
    } catch (error) {
      if (work != null && !handedOver) await _installer.discard(work.path);
      if (!mounted) return;
      state = state.copyWith(
        stage: UpdateStage.idle,
        received: 0,
        step: () => null,
        installing: () => null,
        installError: () => switch (error) {
          UpdateCancelled() => null,
          UpdateException(:final message) => message,
          _ => 'The update failed: $error',
        },
      );
    } finally {
      _cancel = null;
    }
  }

  /// After a restart from an update: say whether the new version is the one
  /// running, and remember what to tidy up.
  void _readPending() {
    final pending = _store.read(_kPending);
    if (pending == null) return;
    _store.write(_kPending, null);
    if (pending is! Map) return;
    final leftovers = pending['leftovers'];
    if (leftovers is List && leftovers.isNotEmpty) {
      final known = _store.read(_kLeftovers);
      _store.write(_kLeftovers, [
        if (known is List) ...known.whereType<String>(),
        ...leftovers.whereType<String>(),
      ]);
    }
    final to = Version.tryParse(pending['to'] as String?);
    final from = Version.tryParse(pending['from'] as String?);
    final at = pending['at'];
    if (to == null || at is! int) return;
    // An update that never restarted Pastee, found much later, isn't news.
    final age = _now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    if (age > const Duration(days: 2)) return;
    final page = Uri.tryParse('${pending['page']}');
    final link =
        page != null && page.scheme == 'https' && page.host == 'github.com'
            ? page
            : null;
    if (state.current == to) {
      state = state.copyWith(
          notice: () => UpdateNotice(version: to, installed: true, page: link));
    } else if (state.current == from) {
      state = state.copyWith(
          notice: () =>
              UpdateNotice(version: to, installed: false, page: link));
    }
  }

  /// Deletes what earlier updates left behind (the Windows setup can't be
  /// deleted while it runs, for one). Runs shortly after Pastee starts.
  @visibleForTesting
  Future<void> cleanUp() async {
    final leftovers = _store.read(_kLeftovers);
    if (leftovers is! List || leftovers.isEmpty) return;
    for (final path in leftovers.whereType<String>()) {
      await _installer.discard(path);
    }
    if (mounted) await _store.write(_kLeftovers, null);
  }
}
