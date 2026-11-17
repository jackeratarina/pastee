import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// The GitHub repository whose releases Pastee updates itself from.
const updateRepository = 'jackeratarina/pastee';

/// The releases Pastee looks at when it checks for an update.
final releasesApi = Uri.https(
    'api.github.com', '/repos/$updateRepository/releases', {'per_page': '20'});

/// Where to download Pastee by hand.
final releasesPage =
    Uri.https('github.com', '/$updateRepository/releases/latest');

/// Checking, downloading or installing an update went wrong; [message] says
/// how, for the user.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The user stopped the download.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// A release number like 1.4.0. Tags may start with "v". A pre-release such
/// as 1.5.0-beta.1 comes before 1.5.0.
@immutable
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch, [this.preRelease = '']);

  final int major;
  final int minor;
  final int patch;
  final String preRelease;

  static final _pattern = RegExp(r'^[vV]?(\d{1,9})(?:\.(\d{1,9}))?'
      r'(?:\.(\d{1,9}))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');

  /// Null for anything that isn't a version, such as "dev".
  static Version? tryParse(String? text) {
    if (text == null) return null;
    final match = _pattern.firstMatch(text.trim());
    if (match == null) return null;
    return Version(int.parse(match[1]!), int.parse(match[2] ?? '0'),
        int.parse(match[3] ?? '0'), match[4] ?? '');
  }

  bool get isPreRelease => preRelease.isNotEmpty;

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    return _comparePreRelease(preRelease, other.preRelease);
  }

  /// Semantic Versioning's order: dot-separated parts, numbers by value and
  /// before words, and fewer parts first when all else is equal.
  static int _comparePreRelease(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < left.length && i < right.length; i++) {
      final x = int.tryParse(left[i]);
      final y = int.tryParse(right[i]);
      final order = x != null && y != null
          ? x.compareTo(y)
          : x != null
              ? -1
              : y != null
                  ? 1
                  : left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return left.length.compareTo(right.length);
  }

  bool operator >(Version other) => compareTo(other) > 0;
  bool operator <(Version other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  @override
  String toString() =>
      '$major.$minor.$patch${preRelease.isEmpty ? '' : '-$preRelease'}';
}

/// A file attached to a release.
@immutable
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final Uri url;
  final int size;

  /// The SHA-256 that GitHub worked out when the file was uploaded, in
  /// lowercase hex, if GitHub says.
  final String? sha256;

  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  /// An entry of a GitHub release's "assets", or null if it isn't a finished
  /// upload of this repository's releases.
  static ReleaseAsset? fromGitHub(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    final size = json['size'];
    final state = json['state'];
    if (name is! String || url is! String || size is! int || size <= 0) {
      return null;
    }
    if (state != null && state != 'uploaded') return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !isReleaseDownload(uri)) return null;
    final digest = json['digest'];
    String? sha;
    if (digest is String && digest.startsWith('sha256:')) {
      final hex = digest.substring(7).toLowerCase();
      if (_hex.hasMatch(hex)) sha = hex;
    }
    return ReleaseAsset(name: name, url: uri, size: size, sha256: sha);
  }

  Map<String, Object> toJson() => {
        'name': name,
        'url': '$url',
        'size': size,
        if (sha256 != null) 'sha256': sha256!,
      };

  static ReleaseAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = Uri.tryParse('${json['url']}');
    final size = json['size'];
    final sha = json['sha256'];
    if (name is! String || url == null || size is! int) return null;
    if (!isReleaseDownload(url)) return null;
    return ReleaseAsset(
        name: name,
        url: url,
        size: size,
        sha256: sha is String && _hex.hasMatch(sha) ? sha : null);
  }
}

/// Pastee downloads only files attached to its own repository's releases.
bool isReleaseDownload(Uri url) =>
    url.scheme == 'https' &&
    url.host == 'github.com' &&
    url.path.startsWith('/$updateRepository/releases/download/');

/// A published release of Pastee.
@immutable
class Release {
  const Release({
    required this.version,
    required this.tag,
    required this.notes,
    required this.page,
    required this.assets,
    this.publishedAt,
  });

  final Version version;
  final String tag;

  /// What's new, in Markdown.
  final String notes;

  /// The release on github.com.
  final Uri page;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  /// The download whose name ends with [suffix], like "-linux-x64.deb".
  ReleaseAsset? assetEndingWith(String suffix) =>
      assets.where((asset) => asset.name.endsWith(suffix)).firstOrNull;

  /// SHA256SUMS.txt, the checksums the release build wrote.
  ReleaseAsset? get checksums =>
      assets.where((asset) => asset.name == 'SHA256SUMS.txt').firstOrNull;

  /// A release from GitHub's API, or null for drafts, pre-releases and tags
  /// that aren't versions.
  static Release? fromGitHub(Object? json) {
    if (json is! Map) return null;
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final version = Version.tryParse(tag);
    if (version == null || version.isPreRelease) return null;
    final body = json['body'];
    final published = json['published_at'];
    return Release(
      version: version,
      tag: tag,
      notes: releaseNotes(body is String ? body : ''),
      page: _releasePage(json['html_url'], tag),
      publishedAt:
          published is String ? DateTime.tryParse(published)?.toUtc() : null,
      assets: [
        if (json['assets'] case final List assets)
          for (final entry in assets)
            if (ReleaseAsset.fromGitHub(entry) case final asset?) asset,
      ],
    );
  }

  static Uri _releasePage(Object? url, String tag) {
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.path.startsWith('/$updateRepository/releases/')) {
      return uri;
    }
    return Uri.https('github.com', '/$updateRepository/releases/tag/$tag');
  }

  Map<String, Object> toJson() => {
        'tag': tag,
        'notes': notes,
        'page': '$page',
        if (publishedAt != null)
          'published': publishedAt!.millisecondsSinceEpoch,
        'assets': [for (final asset in assets) asset.toJson()],
      };

  static Release? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag'];
    final version = Version.tryParse(tag is String ? tag : null);
    final notes = json['notes'];
    final published = json['published'];
    final assets = json['assets'];
    if (tag is! String || version == null || assets is! List) return null;
    return Release(
      version: version,
      tag: tag,
      notes: notes is String ? notes : '',
      page: _releasePage(json['page'], tag),
      publishedAt: published is int
          ? DateTime.fromMillisecondsSinceEpoch(published, isUtc: true)
          : null,
      assets: [
        for (final entry in assets)
          if (ReleaseAsset.fromJson(entry) case final asset?) asset,
      ],
    );
  }
}

/// The "what's new" part of a release description. The release build adds
/// an install guide under "## Install", which doesn't belong in Pastee.
String releaseNotes(String body) {
  final lines = const LineSplitter().convert(body);
  final end = lines
      .indexWhere((line) => line.trimRight().toLowerCase() == '## install');
  return (end < 0 ? lines : lines.sublist(0, end)).join('\n').trim();
}

/// The checksums in a SHA256SUMS.txt (as `sha256sum` writes it), by file
/// name.
Map<String, String> parseChecksums(String text) {
  final pattern = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$');
  return {
    for (final line in const LineSplitter().convert(text))
      if (pattern.firstMatch(line.trimRight()) case final match?)
        match[2]!: match[1]!.toLowerCase(),
  };
}

/// The SHA-256 that [asset] must have: what the release's SHA256SUMS.txt
/// ([sums]) lists for it, and what GitHub recorded when it was uploaded. They
/// must agree, and at least one must be there, or nothing is installed.
String expectedChecksum(ReleaseAsset asset, Map<String, String>? sums) {
  final listed = sums?[asset.name];
  final recorded = asset.sha256;
  if (listed != null && recorded != null && listed != recorded) {
    throw UpdateException('The checksums the release lists for ${asset.name} '
        'don’t agree, so Pastee won’t install it.');
  }
  final expected = listed ?? recorded;
  if (expected == null) {
    throw UpdateException('The release lists no checksum for ${asset.name}, '
        'so Pastee won’t install it.');
  }
  return expected;
}

/// Where releases come from: GitHub, or a fake in tests.
abstract class ReleaseSource {
  /// The published releases, highest version first. Drafts and pre-releases
  /// are left out.
  Future<List<Release>> releases();

  /// A small text file attached to a release, such as SHA256SUMS.txt.
  Future<String> fetchText(Uri url);

  /// Saves [url] to [file] and returns the SHA-256 of what arrived (lowercase
  /// hex). The file must be [size] bytes. [onProgress] hears how many bytes
  /// have arrived. Completing [cancel] stops the download with
  /// [UpdateCancelled].
  Future<String> download(
    Uri url,
    File file, {
    required int size,
    void Function(int received)? onProgress,
    Future<void>? cancel,
  });
}

/// GitHub's REST API, without an account: 60 requests an hour for each
/// network address, far more than a daily check needs.
class GitHubReleaseSource implements ReleaseSource {
  GitHubReleaseSource({
    required this.userAgent,
    Uri? api,
    HttpClient Function()? httpClient,
  })  : api = api ?? releasesApi,
        _newClient = httpClient ?? HttpClient.new;

  /// Says which app is asking (GitHub requires one): "Pastee/1.4.0".
  final String userAgent;
  final Uri api;
  final HttpClient Function() _newClient;

  static const _timeout = Duration(seconds: 30);

  HttpClient _client() => _newClient()
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 5)
    ..findProxy = HttpClient.findProxyFromEnvironment;

  @override
  Future<List<Release>> releases() async {
    final body = await _fetch(api,
        accept: 'application/vnd.github+json', limit: 8 << 20);
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } on FormatException {
      throw const UpdateException(
          'GitHub sent an answer Pastee doesn’t understand.');
    }
    if (json is! List) {
      throw const UpdateException(
          'GitHub sent an answer Pastee doesn’t understand.');
    }
    return [
      for (final entry in json)
        if (Release.fromGitHub(entry) case final release?) release,
    ]..sort((a, b) => b.version.compareTo(a.version));
  }

  @override
  Future<String> fetchText(Uri url) async =>
      utf8.decode(await _fetch(url, accept: '*/*', limit: 1 << 20),
          allowMalformed: true);

  Future<List<int>> _fetch(Uri url,
      {required String accept, required int limit}) async {
    final client = _client();
    try {
      final request = await client.getUrl(url).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, accept);
      if (url.host == 'api.github.com') {
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      final response = await request.close().timeout(_timeout);
      _checkStatus(response);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(_timeout)) {
        bytes.add(chunk);
        if (bytes.length > limit) {
          throw const UpdateException('GitHub’s answer is far too long.');
        }
      }
      return bytes.takeBytes();
    } catch (error) {
      throw _describe(error);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String> download(
    Uri url,
    File file, {
    required int size,
    void Function(int received)? onProgress,
    Future<void>? cancel,
  }) async {
    if (!isReleaseDownload(url)) {
      throw const UpdateException(
          'Pastee only downloads updates from its own releases on GitHub.');
    }
    final client = _client();
    var cancelled = false;
    unawaited(cancel?.then((_) {
      cancelled = true;
      client.close(force: true);
    }));
    IOSink? sink;
    try {
      final request = await client.getUrl(url).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close().timeout(_timeout);
      _checkStatus(response);
      final length = response.contentLength;
      if (length >= 0 && length != size) {
        throw const UpdateException(
            'The download isn’t the size GitHub lists for it. Try again later.');
      }
      final digest = _DigestSink();
      final hasher = sha256.startChunkedConversion(digest);
      final out = sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received > size) {
          throw const UpdateException(
              'The download is bigger than GitHub lists it, so Pastee stopped it.');
        }
        hasher.add(chunk);
        out.add(chunk);
        onProgress?.call(received);
      }
      if (received != size) {
        throw const UpdateException(
            'The download stopped before the end. Try again.');
      }
      hasher.close();
      await out.flush();
      await out.close();
      sink = null;
      return digest.value.toString();
    } catch (error) {
      if (cancelled) throw const UpdateCancelled();
      throw _describe(error);
    } finally {
      await sink?.close().catchError((_) {});
      client.close(force: true);
    }
  }

  static void _checkStatus(HttpClientResponse response) {
    final status = response.statusCode;
    if (status == HttpStatus.ok) return;
    if (status == HttpStatus.tooManyRequests ||
        (status == HttpStatus.forbidden &&
            response.headers.value('x-ratelimit-remaining') == '0')) {
      throw const UpdateException(
          'GitHub is limiting how often it can be asked. Try again in an hour.');
    }
    if (status >= 500) {
      throw UpdateException(
          'GitHub has a problem right now (error $status). Try again later.');
    }
    throw UpdateException('GitHub answered with error $status.');
  }

  static UpdateException _describe(Object error) {
    if (error is UpdateException) return error;
    if (error is SocketException) {
      return const UpdateException(
          'Pastee couldn’t reach GitHub. Check your internet connection.');
    }
    if (error is HandshakeException || error is TlsException) {
      return const UpdateException(
          'Pastee couldn’t make a secure connection to GitHub.');
    }
    if (error is TimeoutException) {
      return const UpdateException('GitHub took too long to answer.');
    }
    if (error is HttpException) {
      return UpdateException(
          'The connection to GitHub broke: ${error.message}');
    }
    if (error is FileSystemException) {
      return UpdateException('Pastee couldn’t save the download: '
          '${error.osError?.message ?? error.message}');
    }
    return UpdateException('$error');
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
