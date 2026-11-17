import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pastee/services/update_installer.dart';
import 'package:pastee/services/updates.dart';

/// The bytes every fake download delivers.
final downloadBytes = utf8.encode('the new Pastee');
final downloadSha = sha256.convert(downloadBytes).toString();

/// A release like the ones the release build publishes: the Linux tarballs
/// (with GitHub's digest) and SHA256SUMS.txt.
Release makeRelease(
  String version, {
  String notes = '### New\n- **Updates.** Pastee updates itself.',
  int size = 9700000,
  String? digest,
  bool withSums = true,
  List<String> platforms = const ['linux-x64.tar.gz', 'linux-arm64.tar.gz'],
}) {
  final base =
      'https://github.com/$updateRepository/releases/download/v$version';
  return Release(
    version: Version.tryParse(version)!,
    tag: 'v$version',
    notes: notes,
    page: Uri.parse(
        'https://github.com/$updateRepository/releases/tag/v$version'),
    publishedAt: DateTime.utc(2026, 11, 20),
    assets: [
      for (final platform in platforms)
        ReleaseAsset(
          name: 'Pastee-$version-$platform',
          url: Uri.parse('$base/Pastee-$version-$platform'),
          size: size,
          sha256: digest ?? downloadSha,
        ),
      if (withSums)
        ReleaseAsset(
            name: 'SHA256SUMS.txt',
            url: Uri.parse('$base/SHA256SUMS.txt'),
            size: 500),
    ],
  );
}

/// SHA256SUMS.txt for [release], listing [sha] for each of its files.
String sumsFor(Release release, {String? sha}) => [
      for (final asset in release.assets)
        if (asset.name != 'SHA256SUMS.txt')
          '${sha ?? downloadSha}  ${asset.name}',
    ].join('\n');

class FakeReleaseSource implements ReleaseSource {
  FakeReleaseSource([List<Release>? releases]) : published = releases ?? [];

  List<Release> published;

  /// Thrown by [releases] instead of answering.
  Object? error;
  int checks = 0;

  /// SHA256SUMS.txt and friends, by URL. Missing ones are a 404.
  final Map<Uri, String> texts = {};
  final List<Uri> downloads = [];

  /// What [download] says arrived, if not [downloadSha].
  String? receivedSha;

  /// While set, a download stops half way until it completes.
  Completer<void>? hold;

  @override
  Future<List<Release>> releases() async {
    checks++;
    if (error case final error?) throw error;
    return [...published]..sort((a, b) => b.version.compareTo(a.version));
  }

  @override
  Future<String> fetchText(Uri url) async =>
      texts[url] ??
      (throw const UpdateException('GitHub answered with error 404.'));

  @override
  Future<String> download(
    Uri url,
    File file, {
    required int size,
    void Function(int received)? onProgress,
    Future<void>? cancel,
  }) async {
    downloads.add(url);
    onProgress?.call(size ~/ 2);
    if (hold case final hold?) {
      var cancelled = false;
      await Future.any([
        hold.future,
        if (cancel != null) cancel.then((_) => cancelled = true),
      ]);
      if (cancelled) throw const UpdateCancelled();
    }
    onProgress?.call(size);
    return receivedSha ?? downloadSha;
  }
}

/// Installs nothing; records what it was asked to do.
class FakeInstaller implements UpdateInstaller {
  FakeInstaller([InstallProbe? probe])
      : probeResult = probe ??
            const InstallProbe.target(InstallTarget(
                kind: InstallKind.linuxTarball,
                path: '/home/me/apps/pastee',
                assetSuffix: '-linux-x64.tar.gz'));

  InstallProbe probeResult;
  static const workspace = '/tmp/pastee-update-test';
  final installs = <(String file, Version version, InstallTarget target)>[];
  final discarded = <String>[];

  /// Thrown by [install] instead of installing.
  Object? error;

  /// What [install] says its helper still needs.
  List<String> keep = const [];

  @override
  InstallProbe probe() => probeResult;

  @override
  Future<Directory> createWorkspace() async => Directory(workspace);

  @override
  Future<void> discard(String path) async => discarded.add(path);

  @override
  Future<List<String>> install(
    File download,
    Release release,
    InstallTarget target, {
    void Function(InstallStep step)? onStep,
  }) async {
    onStep?.call(InstallStep.unpacking);
    if (error case final error?) throw error;
    installs.add((download.path, release.version, target));
    return keep;
  }
}
