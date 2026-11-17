import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'updates.dart';

/// How this copy of Pastee was installed, which decides how it updates.
enum InstallKind {
  /// Pastee.app in a folder you can write to, usually Applications: the new
  /// app replaces it.
  macApp,

  /// Installed with the Windows setup: the new setup runs on its own, without
  /// questions, and starts Pastee again.
  windowsSetup,

  /// The Windows zip, unpacked somewhere you can write to: its files are
  /// replaced.
  windowsPortable,

  /// The .deb, in /opt/pastee: the new package is installed with apt, which
  /// asks for an administrator's password.
  linuxDeb,

  /// The tarball, unpacked somewhere you can write to: its pastee folder is
  /// replaced.
  linuxTarball,
}

/// What an update replaces, and with which download.
@immutable
class InstallTarget {
  const InstallTarget({
    required this.kind,
    required this.path,
    required this.assetSuffix,
    this.allUsers = false,
  });

  final InstallKind kind;

  /// The .app bundle, the Windows or tarball folder, or /opt/pastee.
  final String path;

  /// How the right release file's name ends, e.g. "-linux-x64.deb".
  final String assetSuffix;

  /// [InstallKind.windowsSetup]: installed for all users, so the setup asks
  /// for administrator rights.
  final bool allUsers;

  @override
  bool operator ==(Object other) =>
      other is InstallTarget &&
      other.kind == kind &&
      other.path == path &&
      other.assetSuffix == assetSuffix &&
      other.allUsers == allUsers;

  @override
  int get hashCode => Object.hash(kind, path, assetSuffix, allUsers);

  @override
  String toString() =>
      'InstallTarget($kind, $path, $assetSuffix${allUsers ? ', all users' : ''})';
}

/// Whether this copy of Pastee can update itself: a [target], or the
/// [problem] that stops it (shown with a link to the download page).
@immutable
class InstallProbe {
  const InstallProbe.target(InstallTarget this.target) : problem = null;
  const InstallProbe.unsupported(String this.problem) : target = null;

  final InstallTarget? target;
  final String? problem;

  @override
  String toString() => target?.toString() ?? 'unsupported: $problem';
}

/// What [probeInstall] looks at. Tests make one up.
@immutable
class InstallEnvironment {
  const InstallEnvironment({
    required this.executable,
    required this.platform,
    required this.abi,
    required this.exists,
    required this.canWrite,
    required this.readFile,
    this.environment = const {},
  });

  factory InstallEnvironment.current() => InstallEnvironment(
        executable: Platform.resolvedExecutable,
        platform: defaultTargetPlatform,
        abi: Abi.current(),
        exists: (path) =>
            FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
        canWrite: canWriteTo,
        readFile: (path) {
          try {
            return File(path).readAsStringSync();
          } on FileSystemException {
            return null;
          }
        },
        environment: Platform.environment,
      );

  /// The running program, symbolic links resolved.
  final String executable;
  final TargetPlatform platform;
  final Abi abi;
  final bool Function(String path) exists;

  /// Whether files can be created in, renamed in and removed from folder
  /// [path].
  final bool Function(String path) canWrite;
  final String? Function(String path) readFile;
  final Map<String, String> environment;
}

/// Works out how the copy of Pastee at [InstallEnvironment.executable] was
/// installed, and so whether and how it can update itself.
InstallProbe probeInstall(InstallEnvironment env) {
  switch (env.platform) {
    case TargetPlatform.macOS:
      return _probeMac(env);
    case TargetPlatform.windows:
      return _probeWindows(env);
    case TargetPlatform.linux:
      return _probeLinux(env);
    default:
      return const InstallProbe.unsupported(
          'Pastee updates itself on macOS, Windows and Linux.');
  }
}

const _notRecognized = 'Pastee doesn’t recognize how it was installed, so it '
    'can’t update itself. Download the new version instead.';

String _cantWrite(String folder) =>
    'Pastee can’t replace itself in $folder, because your account can’t '
    'change that folder. Download the new version instead.';

InstallProbe _probeMac(InstallEnvironment env) {
  // …/Pastee.app/Contents/MacOS/Pastee
  final path = p.posix;
  final macOS = path.dirname(env.executable);
  final contents = path.dirname(macOS);
  final bundle = path.dirname(contents);
  if (path.basename(macOS) != 'MacOS' ||
      path.basename(contents) != 'Contents' ||
      path.extension(bundle) != '.app') {
    return const InstallProbe.unsupported(_notRecognized);
  }
  // Gatekeeper runs a quarantined app that was never moved from its
  // read-only, randomly named copy.
  if (bundle.contains('/AppTranslocation/')) {
    return const InstallProbe.unsupported(
        'macOS is running Pastee from a temporary copy. Move Pastee to your '
        'Applications folder, open it from there and try again.');
  }
  final folder = path.dirname(bundle);
  if (!env.canWrite(folder) || !env.canWrite(bundle)) {
    if (bundle.startsWith('/Volumes/')) {
      return const InstallProbe.unsupported(
          'Pastee is running from its disk image. Drag it into your '
          'Applications folder, open it from there and try again.');
    }
    return InstallProbe.unsupported(_cantWrite(folder));
  }
  return InstallProbe.target(InstallTarget(
      kind: InstallKind.macApp, path: bundle, assetSuffix: '-macos.zip'));
}

InstallProbe _probeWindows(InstallEnvironment env) {
  if (env.abi != Abi.windowsX64) {
    return const InstallProbe.unsupported(
        'There’s no Pastee download for this processor yet.');
  }
  final path = p.windows;
  final folder = path.dirname(env.executable);
  // The setup puts its uninstaller next to pastee.exe; the zip has none.
  if (env.exists(path.join(folder, 'unins000.exe'))) {
    final allUsers = [
      env.environment['ProgramFiles'],
      env.environment['ProgramW6432'],
      env.environment['ProgramFiles(x86)'],
    ].any((root) =>
        root != null && root.isNotEmpty && path.isWithin(root, folder));
    return InstallProbe.target(InstallTarget(
      kind: InstallKind.windowsSetup,
      path: folder,
      assetSuffix: '-windows-x64-setup.exe',
      allUsers: allUsers,
    ));
  }
  if (!env.exists(path.join(folder, 'data', 'flutter_assets'))) {
    return const InstallProbe.unsupported(_notRecognized);
  }
  if (!env.canWrite(folder)) {
    return InstallProbe.unsupported(_cantWrite(folder));
  }
  return InstallProbe.target(InstallTarget(
      kind: InstallKind.windowsPortable,
      path: folder,
      assetSuffix: '-windows-x64.zip'));
}

InstallProbe _probeLinux(InstallEnvironment env) {
  final arch = switch (env.abi) {
    Abi.linuxX64 => 'x64',
    Abi.linuxArm64 => 'arm64',
    _ => null,
  };
  if (arch == null) {
    return const InstallProbe.unsupported(
        'There’s no Pastee download for this processor yet.');
  }
  final path = p.posix;
  final folder = path.dirname(env.executable);
  if (folder == debFolder) {
    final files = env.readFile('/var/lib/dpkg/info/pastee.list') ??
        env.readFile(
            '/var/lib/dpkg/info/pastee:${arch == 'x64' ? 'amd64' : 'arm64'}.list');
    if (files != null && files.split('\n').contains(env.executable)) {
      return InstallProbe.target(InstallTarget(
          kind: InstallKind.linuxDeb,
          path: folder,
          assetSuffix: '-linux-$arch.deb'));
    }
  }
  if (!env.exists(path.join(folder, 'data', 'flutter_assets')) ||
      !env.exists(path.join(folder, 'lib', 'libapp.so'))) {
    return const InstallProbe.unsupported(_notRecognized);
  }
  final parent = path.dirname(folder);
  if (!env.canWrite(parent) || !env.canWrite(folder)) {
    return InstallProbe.unsupported(_cantWrite(parent));
  }
  return InstallProbe.target(InstallTarget(
      kind: InstallKind.linuxTarball,
      path: folder,
      assetSuffix: '-linux-$arch.tar.gz'));
}

/// Where the .deb installs Pastee.
const debFolder = '/opt/pastee';

/// Whether your account can create, rename and delete entries in folder
/// [path].
bool canWriteTo(String path) {
  if (Platform.isWindows) {
    // Folder permissions on Windows are ACLs, which _waccess doesn't read:
    // try it.
    try {
      Directory(path).createTempSync('.pastee-write-check-').deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
  return using((arena) =>
      _access(path.toNativeUtf8(allocator: arena), _writeAndSearch) == 0);
}

const _writeAndSearch = 2 | 1; // W_OK | X_OK

typedef _AccessNative = Int32 Function(Pointer<Utf8> path, Int32 mode);
typedef _AccessDart = int Function(Pointer<Utf8> path, int mode);

final _access = DynamicLibrary.process()
    .lookupFunction<_AccessNative, _AccessDart>('access');

/// A step of [UpdateInstaller.install], for the progress shown meanwhile.
enum InstallStep {
  /// Unpacking and checking the new version.
  unpacking,

  /// The system is asking for an administrator's password (Linux .deb).
  waitingForPassword,

  /// Starting the Windows setup.
  startingSetup,
}

/// Puts a downloaded update in place.
///
/// Everything that can go wrong is tried while Pastee still runs, so a
/// problem leaves the current version as it is. Then a small helper process
/// waits for Pastee to quit, puts the new version in place (keeping the old
/// one if that fails) and starts Pastee again.
abstract class UpdateInstaller {
  /// How this copy of Pastee can update itself, or why it can't.
  InstallProbe probe();

  /// A new, empty folder for the download.
  Future<Directory> createWorkspace();

  /// Deletes a folder made by [createWorkspace] or [install].
  Future<void> discard(String path);

  /// Prepares [download] of [release] for [target] and starts the helper
  /// that finishes once Pastee has quit. When it returns, Pastee must quit.
  ///
  /// Returns the folders the helper still needs. They are deleted when
  /// Pastee starts again, if the helper hasn't done that itself.
  Future<List<String>> install(
    File download,
    Release release,
    InstallTarget target, {
    void Function(InstallStep step)? onStep,
  });
}

/// The name of the folders updates are unpacked in, next to the app they
/// replace. Only folders named like this are ever deleted on cleanup.
const updateFolderPrefix = '.pastee-update-';

/// The name of the folders downloads are saved in, in the temporary folder.
const workspacePrefix = 'pastee-update-';

/// Whether [path] is a folder an update made, so that cleaning up can never
/// delete anything else.
bool isUpdateFolder(String path) {
  final name = p.basename(path);
  return name.startsWith(updateFolderPrefix) ||
      name.startsWith(workspacePrefix);
}

class SystemUpdateInstaller implements UpdateInstaller {
  SystemUpdateInstaller({InstallEnvironment Function()? environment})
      : _environment = environment ?? InstallEnvironment.current;

  final InstallEnvironment Function() _environment;

  @override
  InstallProbe probe() => probeInstall(_environment());

  @override
  Future<Directory> createWorkspace() =>
      Directory.systemTemp.createTemp(workspacePrefix);

  @override
  Future<void> discard(String path) async {
    if (!isUpdateFolder(path)) return;
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException catch (error) {
      debugPrint('Pastee: could not delete $path: $error');
    }
  }

  @override
  Future<List<String>> install(
    File download,
    Release release,
    InstallTarget target, {
    void Function(InstallStep step)? onStep,
  }) {
    switch (target.kind) {
      case InstallKind.macApp:
        onStep?.call(InstallStep.unpacking);
        return _installMac(download, release, target);
      case InstallKind.linuxTarball:
        onStep?.call(InstallStep.unpacking);
        return _installTarball(download, release, target);
      case InstallKind.linuxDeb:
        onStep?.call(InstallStep.waitingForPassword);
        return _installDeb(download, target);
      case InstallKind.windowsSetup:
        onStep?.call(InstallStep.startingSetup);
        return _installWindowsSetup(download, target);
      case InstallKind.windowsPortable:
        onStep?.call(InstallStep.unpacking);
        return _installWindowsPortable(download, target);
    }
  }

  /// A new folder with a random name next to [target], so that putting the
  /// new version in place is a rename on the same disk. Made atomically and
  /// private to your account: nobody else can prepare it or slip files in.
  Future<Directory> _stagingNextTo(String target) =>
      Directory(p.dirname(target)).createTemp(updateFolderPrefix);

  Future<List<String>> _installMac(
      File download, Release release, InstallTarget target) async {
    final staging = await _stagingNextTo(target.path);
    try {
      await _run('/usr/bin/ditto', ['-x', '-k', download.path, staging.path],
          'unpack the update');
      final app = p.join(staging.path, 'Pastee.app');
      final info = p.join(app, 'Contents', 'Info.plist');
      if (!await File(info).exists()) {
        throw const UpdateException(
            'The download doesn’t contain Pastee for macOS.');
      }
      final id = await _plistValue(info, 'CFBundleIdentifier');
      final version = await _plistValue(info, 'CFBundleShortVersionString');
      if (id != 'com.pastee.pastee' || version != '${release.version}') {
        throw UpdateException('The download is not Pastee ${release.version} '
            '(it says $id $version).');
      }
      // The bundle's signature covers every file in it, so this catches a
      // damaged unpack.
      await _run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app],
          'check the new version’s signature');
      // Downloaded by Pastee itself, it has no quarantine flag; make sure.
      await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', app]);
      await _startFinisher(
        replace: target.path,
        with_: app,
        staging: staging.path,
        restart: ['/usr/bin/open', target.path],
      );
      return [staging.path];
    } catch (_) {
      await discard(staging.path);
      rethrow;
    }
  }

  Future<List<String>> _installTarball(
      File download, Release release, InstallTarget target) async {
    final staging = await _stagingNextTo(target.path);
    try {
      await _run(
          'tar',
          ['-xzf', download.path, '-C', staging.path, '--no-same-owner'],
          'unpack the update');
      final pastee = p.join(staging.path, 'pastee');
      if (!await File(p.join(pastee, 'pastee')).exists() ||
          !await Directory(p.join(pastee, 'data', 'flutter_assets')).exists()) {
        throw const UpdateException(
            'The download doesn’t contain Pastee for Linux.');
      }
      await _startFinisher(
        replace: target.path,
        with_: pastee,
        staging: staging.path,
        restart: [p.join(target.path, 'pastee')],
      );
      return [staging.path];
    } catch (_) {
      await discard(staging.path);
      rethrow;
    }
  }

  // The package was checked before this, but it sits in a folder of yours
  // until apt reads it as root, so a program running as you could still swap
  // it in the meantime. Checking it again as root would put a shell script in
  // the password prompt instead of the apt command; such a program could
  // fake that prompt anyway.
  Future<List<String>> _installDeb(File download, InstallTarget target) async {
    // apt reads the package as root, and warns when its download user can't.
    await _chmod(download.parent.path, 0x1ed); // 0755
    await _chmod(download.path, 0x1a4); // 0644
    final pkexec = await _find('pkexec');
    final command = File('/usr/bin/apt-get').existsSync()
        ? ['/usr/bin/apt-get', 'install', '-y', download.path]
        : ['/usr/bin/dpkg', '-i', download.path];
    if (pkexec == null) {
      throw UpdateException('Installing the package needs an administrator’s '
          'password, and this system has no pkexec to ask for it. Run '
          '"sudo apt install ${download.path}" in a terminal instead.');
    }
    final process = await Process.start(pkexec, command);
    // Nothing is typed in: a question would wait forever otherwise.
    unawaited(process.stdin.close().catchError((_) {}));
    final output = StringBuffer();
    final err = process.stderr
        .transform(const SystemEncoding().decoder)
        .forEach(output.write);
    final out = process.stdout.drain<void>();
    final code = await process.exitCode;
    await Future.wait([err, out]).catchError((_) => <void>[]);
    if (code == 126) {
      throw const UpdateException(
          'The update wasn’t installed: the password prompt was closed.');
    }
    if (code != 0) {
      final detail = _lastLines(output.toString());
      throw UpdateException(code == 127 && detail.isEmpty
          ? 'The system didn’t allow the update to be installed.'
          : 'The package couldn’t be installed: $detail');
    }
    await _startFinisher(restart: [p.join(target.path, 'pastee')]);
    return [];
  }

  Future<List<String>> _installWindowsSetup(
      File download, InstallTarget target) async {
    final work = download.parent.path;
    final (program, arguments) = windowsPowerShell(windowsSetupScript);
    await Process.start(
      program,
      arguments,
      environment: {
        'PASTEE_UPDATE_PID': '$pid',
        'PASTEE_UPDATE_SETUP': download.path,
        'PASTEE_UPDATE_APP': p.join(target.path, 'pastee.exe'),
      },
      mode: ProcessStartMode.detached,
      // Not Pastee's folder, which the setup is about to change.
      workingDirectory: work,
    );
    // The setup still runs from there.
    return [work];
  }

  Future<List<String>> _installWindowsPortable(
      File download, InstallTarget target) async {
    final work = download.parent;
    final staged = await Directory(p.join(work.path, 'new')).create();
    final tar = p.join(_systemRoot, 'System32', 'tar.exe');
    if (await File(tar).exists()) {
      await _run(
          tar, ['-xf', download.path, '-C', staged.path], 'unpack the update');
    } else {
      // Windows 10 before 1803 has no tar.
      final (program, arguments) = windowsPowerShell(
          r'Expand-Archive -LiteralPath $env:PASTEE_UPDATE_ZIP '
          r'-DestinationPath $env:PASTEE_UPDATE_SOURCE -Force');
      await _run(program, arguments, 'unpack the update', environment: {
        'PASTEE_UPDATE_ZIP': download.path,
        'PASTEE_UPDATE_SOURCE': staged.path,
      });
    }
    if (!await File(p.join(staged.path, 'pastee.exe')).exists()) {
      throw const UpdateException(
          'The download doesn’t contain Pastee for Windows.');
    }
    final (program, arguments) = windowsPowerShell(windowsFinishScript);
    await Process.start(
      program,
      arguments,
      environment: {
        'PASTEE_UPDATE_PID': '$pid',
        'PASTEE_UPDATE_TARGET': target.path,
        'PASTEE_UPDATE_SOURCE': staged.path,
        'PASTEE_UPDATE_WORK': work.path,
      },
      mode: ProcessStartMode.detached,
      // Not Pastee's folder: Windows can't change a folder some process has
      // as its working directory.
      workingDirectory: work.path,
    );
    return [work.path];
  }

  /// Starts [posixFinishScript], which outlives Pastee.
  Future<void> _startFinisher({
    String replace = '',
    String with_ = '',
    String staging = '',
    required List<String> restart,
  }) async {
    final arguments = [
      '-c',
      posixFinishScript,
      'pastee-update',
      '$pid',
      replace,
      with_,
      staging,
      '--',
      ...restart,
    ];
    final scope = await _ownScope();
    await Process.start(
      scope.isEmpty ? '/bin/sh' : scope.first,
      [...scope.skip(1), if (scope.isNotEmpty) '/bin/sh', ...arguments],
      mode: ProcessStartMode.detached,
      workingDirectory: '/',
    );
  }

  /// When Pastee runs as a systemd service (KDE's autostart with systemd
  /// older than 250 does that), quitting stops the service, and with it every
  /// process Pastee started, the helper included. A scope of its own keeps
  /// the helper alive. Empty when that isn't needed or doesn't work.
  static Future<List<String>> _ownScope() async {
    if (!Platform.isLinux) return const [];
    try {
      final cgroups = await File('/proc/self/cgroup').readAsString();
      if (!runsAsUserService(cgroups)) return const [];
      final systemdRun = await _find('systemd-run');
      if (systemdRun == null) return const [];
      final scope = [systemdRun, '--user', '--scope', '--quiet', '--'];
      final probe = await Process.run(scope.first, [...scope.skip(1), 'true'])
          .timeout(const Duration(seconds: 5));
      return probe.exitCode == 0 ? scope : const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _run(
      String executable, List<String> arguments, String what,
      {Map<String, String>? environment}) async {
    final ProcessResult result;
    try {
      result =
          await Process.run(executable, arguments, environment: environment);
    } on ProcessException catch (error) {
      throw UpdateException('Pastee couldn’t $what: ${error.message}');
    }
    if (result.exitCode != 0) {
      final detail = _lastLines('${result.stderr}');
      throw UpdateException('Pastee couldn’t $what'
          '${detail.isEmpty ? ' (error ${result.exitCode})' : ': $detail'}');
    }
  }

  static Future<String?> _plistValue(String plist, String key) async {
    final result = await Process.run(
        '/usr/libexec/PlistBuddy', ['-c', 'Print :$key', plist]);
    return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
  }

  static Future<String?> _find(String program) async {
    for (final dir in [
      ...?Platform.environment['PATH']?.split(':'),
      '/usr/bin',
      '/bin',
    ]) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, program);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  static Future<void> _chmod(String path, int mode) async {
    using((arena) => _chmodNative(path.toNativeUtf8(allocator: arena), mode));
  }
}

String get _systemRoot => Platform.environment['SystemRoot'] ?? r'C:\Windows';

/// Whether /proc/self/cgroup ([cgroups]) says this process belongs to a
/// service of the user's systemd, rather than to a scope like the ones
/// desktops and terminals start apps in.
bool runsAsUserService(String cgroups) => cgroups
    .split('\n')
    .map((line) => line.trim())
    .any((line) => line.contains('/user@') && line.endsWith('.service'));

/// How to run [script] with Windows PowerShell: by its full path (a program
/// named powershell.exe next to Pastee mustn't run instead), and as an
/// encoded command, which an execution policy set by Group Policy doesn't
/// block the way it blocks script files. The script reads its inputs from
/// environment variables, so no path is ever quoted into it.
(String, List<String>) windowsPowerShell(String script, {String? program}) {
  final units = script.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[2 * i] = units[i] & 0xff;
    bytes[2 * i + 1] = units[i] >> 8;
  }
  return (
    program ??
        p.join(_systemRoot, 'System32', 'WindowsPowerShell', 'v1.0',
            'powershell.exe'),
    [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      base64.encode(bytes),
    ],
  );
}

typedef _ChmodNative = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

final _chmodNative =
    DynamicLibrary.process().lookupFunction<_ChmodNative, _ChmodDart>('chmod');

/// The last few lines a command printed, for an error message. apt's note
/// that it read the package as root isn't one of them.
String _lastLines(String output) {
  final lines = [
    for (final line in output.split('\n'))
      if (line.trim().isNotEmpty && !line.contains('unsandboxed')) line.trim(),
  ];
  return lines.skip(lines.length > 3 ? lines.length - 3 : 0).join(' ');
}

/// Finishes an update on macOS and Linux once Pastee has quit.
///
/// Arguments: Pastee's process ID, what to replace and its replacement (both
/// empty when the package manager already did it), a folder to delete when
/// done, then `--` and the command that starts Pastee again. The replacement
/// goes in with two renames on the same disk; if the second fails, the old
/// version goes back. The folder is deleted only once something is in
/// place, so a failure never takes both versions with it.
const posixFinishScript = r'''
pid=$1 target=$2 new=$3 staging=$4
shift 4
[ "$1" = "--" ] && shift
running() {
  kill -0 "$1" 2>/dev/null || return 1
  # A process that has quit but not yet been reaped by its parent.
  case $(ps -o stat= -p "$1" 2>/dev/null) in Z*) return 1 ;; esac
  return 0
}
n=0
while running "$pid"; do
  n=$((n + 1))
  if [ "$n" -gt 600 ]; then exit 1; fi
  sleep 0.1
done
if [ -n "$target" ] && [ -n "$new" ] && [ -n "$staging" ]; then
  old="$staging/previous"
  if mv "$target" "$old"; then
    if mv "$new" "$target"; then
      touch "$target" 2>/dev/null
    else
      mv "$old" "$target"
    fi
  fi
fi
if [ -n "$staging" ] && [ -e "$target" ]; then rm -rf "$staging"; fi
[ "$#" -gt 0 ] && exec "$@"
''';

/// Runs the new Windows setup once Pastee has quit. A setup that doesn't
/// finish (administrator rights declined, an error) changes nothing, and
/// then this starts the old Pastee again; after a successful update the
/// setup starts the new one itself (pastee.iss, /relaunch=1).
///
/// Inputs: PASTEE_UPDATE_PID, PASTEE_UPDATE_SETUP and PASTEE_UPDATE_APP (the
/// pastee.exe to start if the setup fails). No install-mode switch: the setup
/// finds how the current copy was installed by itself, so it updates that
/// copy rather than installing a second one.
const windowsSetupScript = r'''
$ErrorActionPreference = 'Stop'
# Start-Process reads its working directory as a wildcard pattern, so a
# folder like "Apps [2]" must be escaped to mean itself.
function Literal([string]$Path) { $Path -replace '([\[\]*?`])', '`$1' }
$id = [int]$env:PASTEE_UPDATE_PID
try { Wait-Process -Id $id -Timeout 60 } catch { }
if (Get-Process -Id $id -ErrorAction SilentlyContinue) { exit 1 }
$code = -1
try {
  $setup = Start-Process -FilePath $env:PASTEE_UPDATE_SETUP -PassThru -ArgumentList @(
    '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/relaunch=1')
  # Windows PowerShell reports no exit code unless the handle was taken early.
  $null = $setup.Handle
  $setup.WaitForExit()
  $code = $setup.ExitCode
} catch { }
if ($code -ne 0) {
  $app = $env:PASTEE_UPDATE_APP
  Start-Process -FilePath $app -WorkingDirectory (Literal (Split-Path -Parent $app))
}
''';

/// Finishes an update of the Windows zip once Pastee has quit: replaces its
/// files one by one, keeping the old ones until all are in and putting them
/// back if one can't be replaced. Then it starts Pastee again and deletes the
/// download, unless some old file couldn't be put back: then the backup is
/// kept, renamed so that cleaning up doesn't delete it. Files that aren't
/// Pastee's stay as they are.
///
/// Inputs: PASTEE_UPDATE_PID, PASTEE_UPDATE_TARGET (Pastee's folder),
/// PASTEE_UPDATE_SOURCE (the new files), PASTEE_UPDATE_WORK (the download
/// folder, for the backup) and optionally PASTEE_UPDATE_RESTART (what to
/// start instead of pastee.exe). Runs in Windows PowerShell 5.1 and
/// PowerShell 7.
const windowsFinishScript = r'''
$ErrorActionPreference = 'Stop'
# Start-Process reads its working directory as a wildcard pattern, so a
# folder like "Apps [2]" must be escaped to mean itself.
function Literal([string]$Path) { $Path -replace '([\[\]*?`])', '`$1' }
$id = [int]$env:PASTEE_UPDATE_PID
$target = $env:PASTEE_UPDATE_TARGET
$work = $env:PASTEE_UPDATE_WORK
$restart = $env:PASTEE_UPDATE_RESTART
if (-not $restart) { $restart = Join-Path $target 'pastee.exe' }
try { Wait-Process -Id $id -Timeout 60 } catch { }
if (Get-Process -Id $id -ErrorAction SilentlyContinue) { exit 1 }

function Retry([scriptblock]$Action) {
  for ($i = 0; $i -lt 20; $i++) {
    try { & $Action; return } catch { Start-Sleep -Milliseconds 250 }
  }
  & $Action
}

$backup = Join-Path $work 'previous'
$replaced = @()
$added = @()
$updated = $true
$sourceRoot = (Get-Item -LiteralPath $env:PASTEE_UPDATE_SOURCE).FullName.TrimEnd('\', '/')
try {
  foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File) {
    $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $target $relative
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $destination) {
      $saved = Join-Path $backup $relative
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $saved) | Out-Null
      Retry { Move-Item -LiteralPath $destination -Destination $saved -Force }
      $replaced += $relative
    } else {
      $added += $relative
    }
    Retry { Copy-Item -LiteralPath $file.FullName -Destination $destination -Force }
  }
} catch {
  $updated = $false
}
$restored = $true
if (-not $updated) {
  foreach ($relative in $added) {
    try { Retry { Remove-Item -LiteralPath (Join-Path $target $relative) -Force } } catch { }
  }
  foreach ($relative in $replaced) {
    try {
      Retry { Move-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $target $relative) -Force }
    } catch { $restored = $false }
  }
}
try { Start-Process -FilePath $restart -WorkingDirectory (Literal $target) } catch { }
if ($updated -or $restored) {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Rename-Item -LiteralPath $work -NewName ((Split-Path -Leaf $work) + '-kept') -ErrorAction SilentlyContinue
}
''';
