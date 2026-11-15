#!/usr/bin/env bash
# Packages a `flutter build linux --release` bundle for a release:
#   Pastee-<version>-linux-<arch>.tar.gz  unpack anywhere and run pastee/pastee
#   Pastee-<version>-linux-<arch>.deb     /opt/pastee, /usr/bin/pastee, menu
#                                         entry and icons
#
# Usage: linux/packaging/build-packages.sh <bundle dir> <version> <x64|arm64> <output dir>
# Needs dpkg-deb, and dpkg-shlibdeps (package dpkg-dev) for the dependencies.
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <bundle dir> <version> <x64|arm64> <output dir>" >&2
  exit 2
fi
bundle=$1
version=$2
arch=$3
out=$4

case "$arch" in
  x64) deb_arch=amd64 ;;
  arm64) deb_arch=arm64 ;;
  *) echo "unknown architecture: $arch" >&2; exit 2 ;;
esac
if [[ ! -x "$bundle/pastee" ]]; then
  echo "no pastee executable in $bundle" >&2
  exit 1
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Files are root's, readable by all; only the executable and libraries run.
normalize_modes() {
  find "$1" -type d -exec chmod 755 {} +
  find "$1" -type f -exec chmod 644 {} +
  chmod 755 "$1/pastee"
  find "$1/lib" -name '*.so' -exec chmod 755 {} +
}

# ── tarball ──────────────────────────────────────────────────────────────
cp -R "$bundle" "$work/pastee"
normalize_modes "$work/pastee"
tar -C "$work" --owner=0 --group=0 --numeric-owner -czf \
  "$out/Pastee-$version-linux-$arch.tar.gz" pastee

# ── .deb ─────────────────────────────────────────────────────────────────
root=$work/deb
mkdir -p "$root/opt" "$root/usr/bin" "$root/usr/share/applications" \
  "$root/usr/share/doc/pastee"
cp -R "$work/pastee" "$root/opt/pastee"
# The runner finds its data/ and lib/ through /proc/self/exe, so a symlink
# on the PATH is enough.
ln -s ../../opt/pastee/pastee "$root/usr/bin/pastee"
install -m 644 "$here/com.pastee.pastee.desktop" "$root/usr/share/applications/"
for size in 16 32 64 128 256 512; do
  install -D -m 644 \
    "$repo/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png" \
    "$root/usr/share/icons/hicolor/${size}x$size/apps/com.pastee.pastee.png"
done
install -m 644 "$repo/LICENSE" "$root/usr/share/doc/pastee/copyright"

# Depends: the libraries the executable and the bundled libraries link
# against, mapped to packages and minimum versions by dpkg-shlibdeps. The
# bundled libraries themselves come with the package. (DEBIAN/ marks the
# package root, so it can follow $ORIGIN in the RPATH.)
mkdir -p "$root/DEBIAN" "$work/shlibs/debian"
printf 'Source: pastee\n\nPackage: pastee\nArchitecture: any\n' \
  > "$work/shlibs/debian/control"
elf_args=()
while IFS= read -r -d '' file; do
  elf_args+=("-e$file")
done < <(find "$root/opt/pastee" -type f \( -name pastee -o -name '*.so' \) -print0)
depends=$(cd "$work/shlibs" &&
  dpkg-shlibdeps -O --warnings=1 -S"$root" -l"$root/opt/pastee/lib" \
    "${elf_args[@]}")
depends=${depends#shlibs:Depends=}
if [[ "$depends" != *libgtk-3-0* ]]; then
  echo "unexpected dependencies: $depends" >&2
  exit 1
fi

find "$root" -type d -exec chmod 755 {} +
installed_size=$(du -sk --apparent-size --exclude=DEBIAN "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<EOF
Package: pastee
Version: $version
Architecture: $deb_arch
Maintainer: Pastee <https://github.com/jackeratarina/pastee/issues>
Installed-Size: $installed_size
Depends: $depends
Section: utils
Priority: optional
Homepage: https://github.com/jackeratarina/pastee
Description: Instant Shortcut Notes, a keyboard-first clipboard notes app
 Paste text into Pastee and it finds the passwords, usernames, links, codes
 and other fields in it; copy any of them with one key. Summon it from any
 app with a global shortcut (Ctrl+Alt+V by default, or pastee --toggle).
 Items are stored encrypted on your computer and can sit behind a passcode.
EOF
dpkg-deb --root-owner-group -Zxz --build "$root" \
  "$out/Pastee-$version-linux-$arch.deb" >/dev/null

echo "Depends: $depends"
ls -l "$out/Pastee-$version-linux-$arch.tar.gz" "$out/Pastee-$version-linux-$arch.deb"
