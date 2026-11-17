import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/services/updates.dart';

const repo = 'https://github.com/$updateRepository';

Map<String, Object?> asset(String name,
        {int size = 3,
        String? digest,
        String? url,
        String? state = 'uploaded'}) =>
    {
      'name': name,
      'browser_download_url': url ?? '$repo/releases/download/v1.4.1/$name',
      'size': size,
      'state': state,
      'digest': digest,
    };

Map<String, Object?> release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String body = '### New\n- **Updates.** Pastee updates itself.\n\n'
      '## Install\n\nDownload `Pastee-*-macos.dmg`.',
  List<Map<String, Object?>>? assets,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': '$repo/releases/tag/$tag',
      'published_at': '2026-11-20T10:00:00Z',
      'body': body,
      'assets': assets ?? [asset('Pastee-${tag.substring(1)}-linux-x64.deb')],
    };

String hex(String char) => List.filled(64, char).join();

void main() {
  group('Version', () {
    test('reads tags and version numbers', () {
      expect('${Version.tryParse('v1.4.0')}', '1.4.0');
      expect('${Version.tryParse('1.4')}', '1.4.0');
      expect('${Version.tryParse('2')}', '2.0.0');
      expect('${Version.tryParse(' 1.4.0-beta.1 ')}', '1.4.0-beta.1');
      expect('${Version.tryParse('1.4.0+7')}', '1.4.0');
      for (final text in ['dev', '', 'v', '1.4.0.1', '1..4', 'x1.4.0', null]) {
        expect(Version.tryParse(text), isNull, reason: '$text');
      }
    });

    test('orders like Semantic Versioning', () {
      final ordered = [
        '0.9.9',
        '1.4.0',
        '1.4.1',
        '1.10.0-alpha',
        '1.10.0-alpha.1',
        '1.10.0-beta.2',
        '1.10.0-beta.11',
        '1.10.0-rc.1',
        '1.10.0',
        '2.0.0',
      ].map((v) => Version.tryParse(v)!).toList();
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(ordered[i] < ordered[i + 1], isTrue,
            reason: '${ordered[i]} < ${ordered[i + 1]}');
        expect(ordered[i + 1] > ordered[i], isTrue);
      }
      expect(Version.tryParse('v1.4'), Version.tryParse('1.4.0'));
      expect(
          Version.tryParse('1.4.0-rc.1') == Version.tryParse('1.4.0'), isFalse);
    });
  });

  group('Release.fromGitHub', () {
    test('reads the version, notes, page, date and files', () {
      final sha = hex('a');
      final parsed = Release.fromGitHub(release('v1.4.1', assets: [
        asset('Pastee-1.4.1-linux-x64.deb',
            size: 7500000, digest: 'sha256:$sha'),
        asset('SHA256SUMS.txt', size: 900),
      ]))!;
      expect(parsed.version, const Version(1, 4, 1));
      expect(parsed.tag, 'v1.4.1');
      expect(parsed.page, Uri.parse('$repo/releases/tag/v1.4.1'));
      expect(parsed.publishedAt, DateTime.utc(2026, 11, 20, 10));
      expect(parsed.assets, hasLength(2));
      final deb = parsed.assetEndingWith('-linux-x64.deb')!;
      expect(deb.size, 7500000);
      expect(deb.sha256, sha);
      expect(
          deb.url,
          Uri.parse(
              '$repo/releases/download/v1.4.1/Pastee-1.4.1-linux-x64.deb'));
      expect(parsed.checksums?.name, 'SHA256SUMS.txt');
      expect(parsed.checksums?.sha256, isNull);
    });

    test('the notes stop where the install guide starts', () {
      expect(Release.fromGitHub(release('v1.4.1'))!.notes,
          '### New\n- **Updates.** Pastee updates itself.');
      expect(Release.fromGitHub(release('v1.4.1', body: 'Just this.'))!.notes,
          'Just this.');
      expect(releaseNotes('## Install\nonly the guide'), '');
    });

    test('drafts, pre-releases and tags that are not versions are left out',
        () {
      expect(Release.fromGitHub(release('v1.4.1', draft: true)), isNull);
      expect(Release.fromGitHub(release('v1.4.1', prerelease: true)), isNull);
      expect(Release.fromGitHub(release('v1.5.0-beta.1')), isNull);
      expect(Release.fromGitHub(release('nightly')), isNull);
      expect(Release.fromGitHub('not a release'), isNull);
    });

    test('only finished uploads to this repository count as files', () {
      final parsed = Release.fromGitHub(release('v1.4.1', assets: [
        asset('elsewhere.deb', url: 'https://example.com/elsewhere.deb'),
        asset('other-repo.deb',
            url:
                'https://github.com/someone/pastee/releases/download/v1/x.deb'),
        asset('plain-http.deb',
            url:
                'http://github.com/$updateRepository/releases/download/v1/x.deb'),
        asset('half-uploaded.deb', state: 'starter'),
        asset('empty.deb', size: 0),
        asset('odd-digest.deb', digest: 'md5:abc'),
        asset('short-digest.deb', digest: 'sha256:abc'),
      ]))!;
      expect(parsed.assets.map((a) => a.name),
          ['odd-digest.deb', 'short-digest.deb']);
      expect(parsed.assets.map((a) => a.sha256), [null, null]);
    });

    test('a page that is not this repository’s release becomes one', () {
      final json = release('v1.4.1')..['html_url'] = 'https://example.com/x';
      expect(Release.fromGitHub(json)!.page,
          Uri.parse('$repo/releases/tag/v1.4.1'));
    });

    test('survives being cached', () {
      final parsed = Release.fromGitHub(release('v1.4.1', assets: [
        asset('Pastee-1.4.1-macos.zip',
            size: 20500000, digest: 'sha256:${hex('b')}'),
        asset('SHA256SUMS.txt', size: 900),
      ]))!;
      final back = Release.fromJson(jsonDecode(jsonEncode(parsed.toJson())))!;
      expect(back.version, parsed.version);
      expect(back.tag, parsed.tag);
      expect(back.notes, parsed.notes);
      expect(back.page, parsed.page);
      expect(back.publishedAt, parsed.publishedAt);
      expect([for (final a in back.assets) a.toJson()],
          [for (final a in parsed.assets) a.toJson()]);
      expect(Release.fromJson({'tag': 'dev', 'assets': []}), isNull);
      expect(Release.fromJson('junk'), isNull);
    });
  });

  group('checksums', () {
    test('SHA256SUMS.txt is read by file name', () {
      final sums = parseChecksums('${hex('A')}  Pastee-1.4.1-macos.dmg\n'
          '${hex('b')} *Pastee-1.4.1-windows-x64.zip\r\n'
          'not a line\n'
          '${hex('c').substring(1)}  short.txt\n');
      expect(sums, {
        'Pastee-1.4.1-macos.dmg': hex('a'),
        'Pastee-1.4.1-windows-x64.zip': hex('b'),
      });
    });

    test('GitHub’s digest and SHA256SUMS.txt must agree, and one must be there',
        () {
      ReleaseAsset file(String? sha) => ReleaseAsset(
          name: 'x.deb',
          url: Uri.parse('$repo/releases/download/v1/x.deb'),
          size: 3,
          sha256: sha);
      expect(expectedChecksum(file(hex('a')), {'x.deb': hex('a')}), hex('a'));
      expect(expectedChecksum(file(hex('a')), null), hex('a'));
      expect(expectedChecksum(file(null), {'x.deb': hex('b')}), hex('b'));
      expect(
          () => expectedChecksum(file(hex('a')), {'x.deb': hex('b')}),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('don’t agree'))));
      expect(
          () => expectedChecksum(file(null), {'other.deb': hex('b')}),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('no checksum'))));
    });
  });

  group('GitHubReleaseSource', () {
    late HttpServer server;
    late Future<void> Function(HttpRequest request) handle;
    final requests = <HttpRequest>[];
    late Directory temp;

    setUp(() async {
      requests.clear();
      temp = await Directory.systemTemp.createTemp('pastee-updates-test');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add(request);
        await handle(request);
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    /// Every https request, to GitHub or anywhere, goes to [server] instead.
    GitHubReleaseSource source() => GitHubReleaseSource(
          userAgent: 'Pastee/1.4.0',
          httpClient: () => HttpClient()
            ..connectionFactory = (uri, proxyHost, proxyPort) =>
                Socket.startConnect(InternetAddress.loopbackIPv4, server.port),
        );

    Future<void> reply(HttpRequest request, Object body,
        {int status = 200, Map<String, String> headers = const {}}) async {
      final bytes = body is List<int> ? body : utf8.encode('$body');
      request.response
        ..statusCode = status
        ..contentLength = bytes.length;
      headers.forEach(request.response.headers.set);
      request.response.add(bytes);
      await request.response.close();
    }

    test('lists the releases, newest version first, as Pastee', () async {
      handle = (request) => reply(
          request,
          jsonEncode([
            release('v1.4.1'),
            release('v1.10.0'),
            release('v1.5.0', draft: true),
            release('v1.6.0-beta.1', prerelease: true),
            release('v1.3.0'),
          ]));
      final releases = await source().releases();
      expect(releases.map((r) => '${r.version}'), ['1.10.0', '1.4.1', '1.3.0']);
      final request = requests.single;
      expect(request.uri.path, '/repos/$updateRepository/releases');
      expect(request.uri.queryParameters, {'per_page': '20'});
      expect(request.headers.host, 'api.github.com');
      expect(request.headers.value('user-agent'), 'Pastee/1.4.0');
      expect(request.headers.value('accept'), 'application/vnd.github+json');
      expect(request.headers.value('x-github-api-version'), '2022-11-28');
    });

    test('says when GitHub limits requests', () async {
      handle = (request) => reply(request, '{"message": "rate limit"}',
          status: 403, headers: {'x-ratelimit-remaining': '0'});
      await expectLater(
          source().releases(),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('limiting'))));
    });

    test('says what other errors mean', () async {
      handle = (request) => reply(request, 'oops', status: 502);
      await expectLater(
          source().releases(),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('error 502'))));
      handle = (request) => reply(request, '<html>not json');
      await expectLater(
          source().releases(),
          throwsA(isA<UpdateException>().having(
              (e) => e.message, 'message', contains('doesn’t understand'))));
    });

    test('says when GitHub can’t be reached', () async {
      final offline = GitHubReleaseSource(
        userAgent: 'Pastee/1.4.0',
        httpClient: () => HttpClient()
          ..connectionFactory = (uri, proxyHost, proxyPort) =>
              throw const SocketException('Network is unreachable'),
      );
      await expectLater(
          offline.releases(),
          throwsA(isA<UpdateException>().having(
              (e) => e.message, 'message', contains('internet connection'))));
    });

    test('downloads through GitHub’s redirect and returns the SHA-256',
        () async {
      final bytes = List.generate(200000, (i) => i % 251);
      handle = (request) async {
        if (request.headers.host == 'github.com') {
          expect(request.headers.value('accept'), 'application/octet-stream');
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location',
                'https://release-assets.githubusercontent.com/signed?x=1');
          await request.response.close();
        } else {
          await reply(request, bytes);
        }
      };
      final file = File('${temp.path}/Pastee.deb');
      final progress = <int>[];
      final sha = await source().download(
          Uri.parse(
              '$repo/releases/download/v1.4.1/Pastee-1.4.1-linux-x64.deb'),
          file,
          size: bytes.length,
          onProgress: progress.add);
      expect(sha, sha256.convert(bytes).toString());
      expect(await file.readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(requests.map((r) => r.headers.host),
          ['github.com', 'release-assets.githubusercontent.com']);
    });

    test('downloads only from this repository’s releases', () async {
      handle = (request) => reply(request, 'evil');
      for (final url in [
        'https://example.com/Pastee.deb',
        'https://github.com/someone/else/releases/download/v1/x.deb',
        'http://github.com/$updateRepository/releases/download/v1/x.deb',
      ]) {
        await expectLater(
            source().download(Uri.parse(url), File('${temp.path}/x'), size: 4),
            throwsA(isA<UpdateException>()));
      }
      expect(requests, isEmpty);
    });

    test('stops a download that isn’t the size GitHub lists', () async {
      final url = Uri.parse('$repo/releases/download/v1.4.1/x.deb');
      handle = (request) => reply(request, List.filled(10, 1));
      await expectLater(
          source().download(url, File('${temp.path}/a'), size: 4),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('size'))));
      // Without a Content-Length, it stops once there's more than expected.
      handle = (request) async {
        request.response.bufferOutput = false;
        for (var i = 0; i < 4; i++) {
          request.response.add(List.filled(1000, 1));
          await request.response.flush();
        }
        await request.response.close();
      };
      await expectLater(
          source().download(url, File('${temp.path}/b'), size: 1500),
          throwsA(isA<UpdateException>()
              .having((e) => e.message, 'message', contains('bigger'))));
      // A short one.
      handle = (request) => reply(request, List.filled(2, 1));
      await expectLater(
          source().download(url, File('${temp.path}/c'), size: 2000),
          throwsA(isA<UpdateException>()));
    });

    test('a cancelled download stops', () async {
      final url = Uri.parse('$repo/releases/download/v1.4.1/x.deb');
      final finish = Completer<void>();
      handle = (request) async {
        request.response
          ..bufferOutput = false
          ..contentLength = 2000;
        request.response.add(List.filled(1000, 1));
        await request.response.flush();
        await finish.future;
        await request.response.close().catchError((_) {});
      };
      final cancel = Completer<void>();
      final download = source().download(url, File('${temp.path}/d'),
          size: 2000, cancel: cancel.future, onProgress: (received) {
        if (received >= 1000 && !cancel.isCompleted) cancel.complete();
      });
      await expectLater(download, throwsA(isA<UpdateCancelled>()));
      finish.complete();
    });

    test('fetches SHA256SUMS.txt', () async {
      handle = (request) => reply(request, '${hex('a')}  x.deb\n');
      expect(
          parseChecksums(await source().fetchText(
              Uri.parse('$repo/releases/download/v1.4.1/SHA256SUMS.txt'))),
          {'x.deb': hex('a')});
    });
  });
}
