import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pastee/services/update_installer.dart';

/// A made-up computer: these paths exist, and these folders are writable.
InstallProbe probe(
  String executable, {
  required TargetPlatform platform,
  Abi? abi,
  Set<String> files = const {},
  Set<String> writable = const {},
  Map<String, String> fileContents = const {},
  Map<String, String> environment = const {},
}) {
  return probeInstall(InstallEnvironment(
    executable: executable,
    platform: platform,
    abi: abi ??
        switch (platform) {
          TargetPlatform.macOS => Abi.macosArm64,
          TargetPlatform.windows => Abi.windowsX64,
          _ => Abi.linuxX64,
        },
    exists: (path) => files.contains(path) || fileContents.containsKey(path),
    canWrite: writable.contains,
    readFile: (path) => fileContents[path],
    environment: environment,
  ));
}

void main() {
  group('macOS', () {
    const exe = '/Applications/Pastee.app/Contents/MacOS/Pastee';

    test('Pastee.app in a folder you can change replaces itself', () {
      final result = probe(exe,
          platform: TargetPlatform.macOS,
          writable: {'/Applications', '/Applications/Pastee.app'});
      expect(
          result.target,
          const InstallTarget(
              kind: InstallKind.macApp,
              path: '/Applications/Pastee.app',
              assetSuffix: '-macos.zip'));
      // The universal app fits Intel Macs too.
      expect(
          probe(exe,
                  platform: TargetPlatform.macOS,
                  abi: Abi.macosX64,
                  writable: {'/Applications', '/Applications/Pastee.app'})
              .target
              ?.assetSuffix,
          '-macos.zip');
    });

    test('says why it can’t', () {
      expect(probe(exe, platform: TargetPlatform.macOS).problem,
          contains('can’t replace itself in /Applications'));
      expect(
          probe('/Volumes/Pastee/Pastee.app/Contents/MacOS/Pastee',
                  platform: TargetPlatform.macOS)
              .problem,
          contains('disk image'));
      expect(
          probe(
              '/private/var/folders/x/AppTranslocation/1234/d/Pastee.app/Contents/MacOS/Pastee',
              platform: TargetPlatform.macOS,
              writable: {
                '/private/var/folders/x/AppTranslocation/1234/d'
              }).problem,
          contains('temporary copy'));
      expect(
          probe('/usr/local/bin/pastee', platform: TargetPlatform.macOS)
              .problem,
          contains('doesn’t recognize'));
    });
  });

  group('Windows', () {
    const perUser = r'C:\Users\me\AppData\Local\Programs\Pastee';
    const env = {
      'ProgramFiles': r'C:\Program Files',
      'ProgramFiles(x86)': r'C:\Program Files (x86)',
      'ProgramW6432': r'C:\Program Files',
    };

    test('an installed copy runs the new setup, for the user or all users', () {
      expect(
          probe('$perUser\\pastee.exe',
                  platform: TargetPlatform.windows,
                  files: {'$perUser\\unins000.exe'},
                  environment: env)
              .target,
          const InstallTarget(
              kind: InstallKind.windowsSetup,
              path: perUser,
              assetSuffix: '-windows-x64-setup.exe'));
      const machine = r'C:\Program Files\Pastee';
      expect(
          probe('$machine\\pastee.exe',
                  platform: TargetPlatform.windows,
                  files: {'$machine\\unins000.exe'},
                  environment: env)
              .target
              ?.allUsers,
          isTrue);
      // Windows paths ignore case.
      expect(
          probe(r'c:\program files\pastee\pastee.exe',
                  platform: TargetPlatform.windows,
                  files: {r'c:\program files\pastee\unins000.exe'},
                  environment: env)
              .target
              ?.allUsers,
          isTrue);
    });

    test('the zip replaces its files where you unpacked it', () {
      const folder = r'D:\Tools\Pastee';
      expect(
          probe('$folder\\pastee.exe',
                  platform: TargetPlatform.windows,
                  files: {'$folder\\data\\flutter_assets'},
                  writable: {folder},
                  environment: env)
              .target,
          const InstallTarget(
              kind: InstallKind.windowsPortable,
              path: folder,
              assetSuffix: '-windows-x64.zip'));
      expect(
          probe('$folder\\pastee.exe',
                  platform: TargetPlatform.windows,
                  files: {'$folder\\data\\flutter_assets'},
                  environment: env)
              .problem,
          contains('can’t replace itself'));
      expect(
          probe(r'C:\elsewhere\pastee.exe', platform: TargetPlatform.windows)
              .problem,
          contains('doesn’t recognize'));
    });

    test('only x64 has a download', () {
      expect(
          probe('$perUser\\pastee.exe',
              platform: TargetPlatform.windows,
              abi: Abi.windowsArm64,
              files: {'$perUser\\unins000.exe'}).problem,
          contains('processor'));
    });
  });

  group('Linux', () {
    const bundle = {'data/flutter_assets', 'lib/libapp.so'};
    Set<String> bundleIn(String folder) =>
        {for (final f in bundle) '$folder/$f'};

    test('the .deb installs the new package', () {
      const list =
          '/.\n/opt\n/opt/pastee\n/opt/pastee/pastee\n/usr/bin/pastee\n';
      expect(
          probe('/opt/pastee/pastee',
              platform: TargetPlatform.linux,
              files: bundleIn('/opt/pastee'),
              fileContents: {'/var/lib/dpkg/info/pastee.list': list}).target,
          const InstallTarget(
              kind: InstallKind.linuxDeb,
              path: '/opt/pastee',
              assetSuffix: '-linux-x64.deb'));
      expect(
          probe('/opt/pastee/pastee',
                  platform: TargetPlatform.linux,
                  abi: Abi.linuxArm64,
                  fileContents: {'/var/lib/dpkg/info/pastee.list': list})
              .target
              ?.assetSuffix,
          '-linux-arm64.deb');
      // /opt/pastee that dpkg doesn't know about: someone unpacked the
      // tarball there.
      expect(
          probe('/opt/pastee/pastee',
                  platform: TargetPlatform.linux,
                  files: bundleIn('/opt/pastee'))
              .problem,
          contains('can’t replace itself in /opt'));
    });

    test('the tarball replaces its folder', () {
      const folder = '/home/me/apps/pastee';
      expect(
          probe('$folder/pastee',
              platform: TargetPlatform.linux,
              files: bundleIn(folder),
              writable: {folder, '/home/me/apps'}).target,
          const InstallTarget(
              kind: InstallKind.linuxTarball,
              path: folder,
              assetSuffix: '-linux-x64.tar.gz'));
      expect(
          probe('$folder/pastee',
              platform: TargetPlatform.linux,
              abi: Abi.linuxArm64,
              files: bundleIn(folder),
              writable: {folder, '/home/me/apps'}).target?.assetSuffix,
          '-linux-arm64.tar.gz');
      expect(
          probe('$folder/pastee',
              platform: TargetPlatform.linux,
              files: bundleIn(folder),
              writable: {folder}).problem,
          contains('can’t replace itself in /home/me/apps'));
      expect(
          probe('/usr/local/bin/pastee', platform: TargetPlatform.linux)
              .problem,
          contains('doesn’t recognize'));
      expect(
          probe('$folder/pastee',
              platform: TargetPlatform.linux,
              abi: Abi.linuxRiscv64,
              files: bundleIn(folder),
              writable: {folder, '/home/me/apps'}).problem,
          contains('processor'));
    });
  });

  test('cleaning up only ever deletes update folders', () {
    expect(isUpdateFolder('/home/me/apps/.pastee-update-1.4.1'), isTrue);
    expect(isUpdateFolder('/tmp/pastee-update-123456'), isTrue);
    if (Platform.isWindows) {
      expect(isUpdateFolder(r'C:\Users\me\AppData\Local\Temp\pastee-update-1'),
          isTrue);
    }
    for (final path in ['/home/me', '/', '/home/me/apps/pastee', '', '/tmp']) {
      expect(isUpdateFolder(path), isFalse, reason: path);
    }
  });

  test('canWriteTo tells writable folders from others', () {
    final temp = Directory.systemTemp.createTempSync('pastee-write-test');
    addTearDown(() => temp.deleteSync(recursive: true));
    expect(canWriteTo(temp.path), isTrue);
    expect(canWriteTo(p.join(temp.path, 'missing')), isFalse);
    if (!Platform.isWindows && Platform.environment['USER'] != 'root') {
      expect(canWriteTo('/'), isFalse);
    }
  });

  group('the finishing script (macOS and Linux)', () {
    late Directory temp;
    late String target;
    late String staging;
    late String marker;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('pastee finish ’\$x" [1]');
      target = p.join(temp.path, 'apps', 'pastee');
      staging = p.join(temp.path, 'apps', '.pastee-update-1.4.1');
      marker = p.join(temp.path, 'restarted');
      await Directory(p.join(target, 'data')).create(recursive: true);
      await File(p.join(target, 'VERSION')).writeAsString('old');
      await File(p.join(target, 'data', 'mine.txt')).writeAsString('old data');
      await Directory(p.join(staging, 'pastee', 'data'))
          .create(recursive: true);
      await File(p.join(staging, 'pastee', 'VERSION')).writeAsString('new');
    });

    tearDown(() => temp.delete(recursive: true));

    /// Runs the script for a "Pastee" that quits after [runFor], with a
    /// restart command that leaves [marker] behind.
    Future<(int, Duration)> finish({
      required String replace,
      required String with_,
      required String staging,
      Duration runFor = const Duration(milliseconds: 600),
    }) async {
      final pastee =
          await Process.start('sleep', ['${runFor.inMilliseconds / 1000}']);
      final started = DateTime.now();
      final script = await Process.start('/bin/sh', [
        '-c',
        posixFinishScript,
        'pastee-update',
        '${pastee.pid}',
        replace,
        with_,
        staging,
        '--',
        '/bin/sh',
        '-c',
        r'echo "$@" > "$0"',
        marker,
        'started',
        'again',
      ]);
      // Pastee is still running: nothing may change yet.
      await Future<void>.delayed(runFor ~/ 3);
      expect(await File(p.join(target, 'VERSION')).readAsString(), 'old');
      final code = await script.exitCode;
      await pastee.exitCode;
      return (code, DateTime.now().difference(started));
    }

    test('swaps in the new version once Pastee has quit, then starts it',
        () async {
      final (code, took) = await finish(
          replace: target, with_: p.join(staging, 'pastee'), staging: staging);
      expect(code, 0);
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 550)));
      expect(await File(p.join(target, 'VERSION')).readAsString(), 'new');
      expect(await Directory(staging).exists(), isFalse,
          reason: 'the old version and the staging folder are gone');
      expect(await File(marker).readAsString(), 'started again\n');
    });

    test('keeps the old version when the new one can’t go in', () async {
      final (code, _) = await finish(
          replace: target, with_: p.join(staging, 'missing'), staging: staging);
      expect(code, 0);
      expect(await File(p.join(target, 'VERSION')).readAsString(), 'old');
      expect(await File(p.join(target, 'data', 'mine.txt')).readAsString(),
          'old data');
      expect(await File(marker).readAsString(), 'started again\n');
    });

    test('after a package update, only starts Pastee again', () async {
      final (code, _) = await finish(replace: '', with_: '', staging: '');
      expect(code, 0);
      expect(await File(p.join(target, 'VERSION')).readAsString(), 'old');
      expect(await Directory(staging).exists(), isTrue);
      expect(await File(marker).readAsString(), 'started again\n');
    });
  }, skip: Platform.isWindows ? 'needs /bin/sh' : null);

  test('a helper gets a systemd scope only where Pastee runs as a service', () {
    // KDE's autostart with systemd: a service, stopped (with everything it
    // started) when Pastee quits.
    expect(
        runsAsUserService('0::/user.slice/user-1000.slice/user@1000.service/'
            'app.slice/app-com.pastee.pastee@autostart.service\n'),
        isTrue);
    // GNOME, KDE's menu, a terminal: scopes, which don't do that.
    expect(
        runsAsUserService('0::/user.slice/user-1000.slice/user@1000.service/'
            'app.slice/app-gnome-com.pastee.pastee-4242.scope\n'),
        isFalse);
    expect(runsAsUserService('0::/user.slice/user-1000.slice/session-2.scope'),
        isFalse);
    expect(runsAsUserService('0::/system.slice/docker.service'), isFalse);
    expect(runsAsUserService(''), isFalse);
  });

  test('PowerShell gets its script encoded and by full path', () {
    final (program, arguments) = windowsPowerShell('Write-Host “hi” ’');
    expect(p.basename(program).toLowerCase(), 'powershell.exe');
    expect(program, contains('WindowsPowerShell'));
    expect(arguments.sublist(0, arguments.length - 1), [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand'
    ]);
    final bytes = base64.decode(arguments.last);
    final units = [
      for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8
    ];
    expect(String.fromCharCodes(units), 'Write-Host “hi” ’');
  });

  group('the Windows helpers', () {
    // Windows PowerShell 5.1 on Windows, which is what Pastee runs there;
    // PowerShell 7 elsewhere, when it's installed (GitHub's Ubuntu runners
    // have it).
    final shell = Platform.isWindows ? null : _onPath('pwsh');
    late Directory temp;
    late String marker;
    late String restart;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('pastee ps’test [1]');
      marker = p.join(temp.path, 'restarted.txt');
      restart = await _script(temp, 'restart',
          windows: 'echo started> "%~dp0restarted.txt"',
          posix: 'echo started > "$marker"');
    });

    tearDown(() async {
      if (!Platform.isWindows) {
        await Process.run('chmod', ['-R', 'u+w', temp.path]);
      }
      // A started "Pastee" (cmd.exe) may still have the folder as its
      // working directory for a moment, which Windows doesn't let go.
      for (var i = 0;; i++) {
        try {
          await temp.delete(recursive: true);
          return;
        } on FileSystemException {
          if (i == 50) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    /// Runs [script] the way Pastee does, for a "Pastee" that has quit.
    Future<void> run(String script, Map<String, String> environment) async {
      final pastee = await Process.start(
          Platform.isWindows ? 'cmd.exe' : 'true',
          Platform.isWindows ? ['/c', 'exit'] : []);
      await pastee.exitCode;
      final (program, arguments) = windowsPowerShell(script, program: shell);
      if (!Platform.isWindows) {
        // PowerShell 7 can't hide a window outside Windows.
        final style = arguments.indexOf('-WindowStyle');
        arguments.removeRange(style, style + 2);
      }
      final result = await Process.run(program, arguments, environment: {
        'PASTEE_UPDATE_PID': '${pastee.pid}',
        ...environment,
      });
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }

    Future<bool> restarted() async {
      for (var i = 0; i < 50 && !File(marker).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return File(marker).existsSync();
    }

    group('setup', () {
      late String args;

      Future<void> runSetup(int exitCode) async {
        args = p.join(temp.path, 'args.txt');
        final setup = await _script(temp, 'setup',
            // The space keeps cmd from reading "1>" in /relaunch=1 as a
            // redirection.
            windows: 'echo %* > "%~dp0args.txt"\r\nexit /b $exitCode',
            posix: 'echo "\$@" > "$args"\nexit $exitCode');
        await run(windowsSetupScript, {
          'PASTEE_UPDATE_SETUP': setup,
          'PASTEE_UPDATE_APP': restart,
        });
      }

      test('a setup that worked starts Pastee itself', () async {
        await runSetup(0);
        final passed =
            File(args).readAsStringSync().trim().split(RegExp(r'\s+'));
        expect(passed, [
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/relaunch=1',
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(File(marker).existsSync(), isFalse);
      });

      test('a setup that didn’t finish gets the old Pastee started again',
          () async {
        await runSetup(2);
        expect(await restarted(), isTrue);
      });
    });

    group('zip', () {
      late String target;
      late String source;
      late String work;

      setUp(() async {
        target = p.join(temp.path, 'Pastee');
        work = p.join(temp.path, 'pastee-update-1');
        source = p.join(work, 'new');
        for (final (folder, files) in [
          (
            target,
            {
              'pastee.exe': 'old exe',
              'data/app.so': 'old app',
              'notes.txt': 'mine',
            }
          ),
          (
            source,
            {
              'pastee.exe': 'new exe',
              'data/app.so': 'new app',
              'data/new.dat': 'new file',
            }
          ),
        ]) {
          for (final MapEntry(key: name, value: text) in files.entries) {
            final file = File(p.join(folder, name));
            await file.parent.create(recursive: true);
            await file.writeAsString(text);
          }
        }
      });

      Future<void> finish() => run(windowsFinishScript, {
            'PASTEE_UPDATE_TARGET': target,
            'PASTEE_UPDATE_SOURCE': source,
            'PASTEE_UPDATE_WORK': work,
            'PASTEE_UPDATE_RESTART': restart,
          });

      String read(String name) => File(p.join(target, name)).readAsStringSync();

      test('replaces Pastee’s files and leaves yours', () async {
        await finish();
        expect(await restarted(), isTrue);
        expect(read('pastee.exe'), 'new exe');
        expect(read('data/app.so'), 'new app');
        expect(read('data/new.dat'), 'new file');
        expect(read('notes.txt'), 'mine');
        expect(Directory(work).existsSync(), isFalse);
      });

      test('puts the old files back when one can’t be replaced', () async {
        if (Platform.isWindows) {
          markTestSkipped('locks files differently on Windows');
          return;
        }
        // pastee.exe is set aside and replaced, then the backup folder for
        // data/ turns out to be read-only, so app.so can't be.
        final backup = Directory(p.join(work, 'previous', 'data'));
        await backup.create(recursive: true);
        await Process.run('chmod', ['a-w', backup.path]);
        await finish();
        expect(await restarted(), isTrue);
        expect(read('pastee.exe'), 'old exe');
        expect(read('data/app.so'), 'old app');
        expect(read('notes.txt'), 'mine');
        expect(File(p.join(target, 'data', 'new.dat')).existsSync(), isFalse);
        expect(Directory(work).existsSync(), isFalse,
            reason: 'everything went back, so the backup can go');
      });
    });
  },
      skip: Platform.isWindows || _onPath('pwsh') != null
          ? null
          : 'needs PowerShell');
}

/// An executable script called [name] in [dir]: a .cmd file running
/// [windows] on Windows, a shell script running [posix] elsewhere. cmd.exe
/// reads batch files in the OEM code page, so [windows] names files by
/// `%~dp0` (the script's own folder) rather than spelling out a path.
Future<String> _script(Directory dir, String name,
    {required String windows, required String posix}) async {
  if (Platform.isWindows) {
    final file = File(p.join(dir.path, '$name.cmd'));
    await file.writeAsString('@echo off\r\n$windows\r\n');
    return file.path;
  }
  final file = File(p.join(dir.path, '$name.sh'));
  await file.writeAsString('#!/bin/sh\n$posix\n');
  await Process.run('chmod', ['+x', file.path]);
  return file.path;
}

String? _onPath(String program) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File(p.join(dir, program)).existsSync()) {
      return p.join(dir, program);
    }
  }
  return null;
}
