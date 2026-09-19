#!/bin/bash
set -euo pipefail

PKG_NAME="${PKG_NAME:-krun-chielo}"
VERSION="${VERSION:-1.0.0}"

# renovate: datasource=github-tags depName=libkrun/libkrun
KRUN_VER=v1.19.4
# renovate: datasource=github-tags depName=libkrun/libkrunfw
FW_VER=v5.6.1
# renovate: datasource=github-tags depName=containers/crun
CRUN_VER=1.29.1

PREFIX="${PREFIX:-/opt/$PKG_NAME}"

VERSION_CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)
test -n "$VERSION_CODENAME"
PKG_VER="${VERSION}+${VERSION_CODENAME}+libkrun${KRUN_VER#v}+crun${CRUN_VER}+fw${FW_VER#v}"

ARCH="$(dpkg --print-architecture)"

DEBROOT="/tmp/debroot-${PKG_NAME}-${PKG_VER}-${ARCH}"

JOBS="$(nproc)"

KRUN_LIBFW_SO_NAME=libkrunfw.so.$(cut -d. -f1 <<<"${FW_VER#v}")
CRUN_LIBKRUN_SO_NAME=libkrun.so.$(cut -d. -f1 <<<"${KRUN_VER#v}")

apt install --no-install-recommends -y \
  curl git build-essential pkgconf autoconf automake libtool python3 \
  libbz2-dev libclang-dev libjson-c-dev libcap-dev libseccomp-dev libsystemd-dev \
  patchelf

clone() {
  git clone --depth=1 --shallow-submodules --recurse-submodules --branch="$2" "$1"
}

clone https://github.com/libkrun/libkrun.git "$KRUN_VER"
clone https://github.com/containers/crun.git "$CRUN_VER"

read -r KERNEL_VER KERNEL_REMOTE <<<"$(
  curl -fsSL "https://raw.githubusercontent.com/libkrun/libkrunfw/${FW_VER}/Makefile" |
    sed -n '/^KERNEL_VERSION *=/p;/^KERNEL_REMOTE *=/p' |
    make -f - -s --eval 'print:;@echo $(KERNEL_VERSION) $(KERNEL_REMOTE)' print
)"
test -n "$KERNEL_VER" && test -n "$KERNEL_REMOTE"

case "$ARCH" in
amd64) FW_ARCH=x86_64 ;;
arm64) FW_ARCH=aarch64 ;;
riscv64) FW_ARCH=riscv64 ;;
*)
  echo "unsupported arch: $ARCH" >&2
  exit 1
  ;;
esac

curl -fsSL -o "libkrunfw-${FW_ARCH}.tgz" \
  "https://github.com/libkrun/libkrunfw/releases/download/${FW_VER}/libkrunfw-${FW_ARCH}.tgz"
mkdir -p libkrunfw
tar -xzf "libkrunfw-${FW_ARCH}.tgz" -C libkrunfw
FW_LIB="$(find libkrunfw -name "$KRUN_LIBFW_SO_NAME" | head -n1)"
test -n "$FW_LIB"

(
  cd libkrun
  make -j"$JOBS"
)
KRUN_LIB="$(find libkrun/target/release -maxdepth 1 -name "$CRUN_LIBKRUN_SO_NAME"'.*' ! -type l | head -n1)"
test -n "$KRUN_LIB"

(
  cd crun
  ./autogen.sh
  ./configure \
    --with-libkrun \
    CFLAGS="-I$PWD/../libkrun/include"
  make -j"$JOBS"
)
test -x crun/crun

mkdir -p "$DEBROOT$PREFIX/bin" "$DEBROOT$PREFIX/lib" "$DEBROOT/DEBIAN"

install -m755 crun/crun "$DEBROOT$PREFIX/bin/krun"
cp -L "$KRUN_LIB" "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME"
cp -L "$FW_LIB" "$DEBROOT$PREFIX/lib/$KRUN_LIBFW_SO_NAME"
chmod 755 "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME" "$DEBROOT$PREFIX/lib/$KRUN_LIBFW_SO_NAME"

patchelf --set-rpath "$PREFIX/lib" "$DEBROOT$PREFIX/bin/krun"
patchelf --set-rpath "$PREFIX/lib" "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME"

mkdir -p "$DEBROOT/etc/containers/containers.conf.d"
cat >"$DEBROOT/etc/containers/containers.conf.d/47-$PKG_NAME.conf" <<EOF
[engine.runtimes]
$PKG_NAME = ["$PREFIX/bin/krun"]
EOF

depends_from_ldd() {
  ldd "$1" | awk '
    / => / {
      lib=$1
      if (lib ~ /^libsystemd\.so/)  print "libsystemd0"
      else if (lib ~ /^libseccomp\.so/) print "libseccomp2"
      else if (lib ~ /^libcap\.so/)     print "libcap2"
      else if (lib ~ /^libjson-c\.so/)  print "libjson-c5"
      else if (lib ~ /^libbz2\.so/)     print "libbz2-1.0"
      else if (lib ~ /^libgcc_s\.so/)   print "libgcc-s1"
      else if (lib ~ /^libc\.so/)       print "libc6"
    }
  '
}
mapfile -t deps < <({
  depends_from_ldd "$DEBROOT$PREFIX/bin/krun"
  depends_from_ldd "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME"
} | sort -u)
IFS=', '
DEP_LINE="${deps[*]}"
unset IFS
[ -n "$DEP_LINE" ] || DEP_LINE="libc6"

cat >"$DEBROOT/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VER
Section: admin
Priority: optional
Architecture: $ARCH
Maintainer: Chielo <mail@chielo.org>
Depends: $DEP_LINE
Description: Standalone krun runtime at $PREFIX
EOF

readelf -d "$DEBROOT$PREFIX/bin/krun" | grep -E 'RPATH|RUNPATH' || true
readelf -d "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME" | grep -E 'RPATH|RUNPATH' || true
ldd "$DEBROOT$PREFIX/bin/krun"
ldd "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME"

docdir="$DEBROOT/usr/share/doc/$PKG_NAME"
install -d -m0755 "$docdir"
cat >"$docdir/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $PKG_NAME
Source: https://github.com/ChieloNewctle/krun-debian
Comment:
 This package redistributes unmodified upstream binaries.
 Corresponding source:
   packaging: https://github.com/ChieloNewctle/krun-debian
   crun ${CRUN_VER}: https://github.com/containers/crun/archive/refs/tags/${CRUN_VER}.tar.gz
   libkrun ${KRUN_VER}: https://github.com/libkrun/libkrun/archive/refs/tags/${KRUN_VER}.tar.gz
   libkrunfw ${FW_VER}: https://github.com/libkrun/libkrunfw/archive/refs/tags/${FW_VER}.tar.gz
   guest kernel ${KERNEL_VER}: ${KERNEL_REMOTE}

Files: *
Copyright: 2026 Chielo <mail@chielo.org>
License: MIT

Files: ${PREFIX#/}/bin/krun
Copyright: crun contributors
License: GPL-2.0-or-later
Comment: Built from containers/crun ${CRUN_VER}.

Files: ${PREFIX#/}/lib/${CRUN_LIBKRUN_SO_NAME}
Copyright: libkrun contributors
License: Apache-2.0
Comment: Built from libkrun/libkrun ${KRUN_VER}.

Files: ${PREFIX#/}/lib/${KRUN_LIBFW_SO_NAME}
Copyright: libkrunfw contributors
           Linux kernel contributors
License: LGPL-2.1-only and GPL-2.0-only
Comment: From libkrun/libkrunfw ${FW_VER} release, guest kernel ${KERNEL_VER}.

License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation
 the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.

License: GPL-2.0-or-later
 On Debian systems, /usr/share/common-licenses/GPL-2.
 https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

License: GPL-2.0-only
 On Debian systems, /usr/share/common-licenses/GPL-2.
 https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

License: LGPL-2.1-only
 On Debian systems, /usr/share/common-licenses/LGPL-2.1.
 https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html

License: Apache-2.0
 On Debian systems, /usr/share/common-licenses/Apache-2.0.
 https://www.apache.org/licenses/LICENSE-2.0
EOF

DEB="${PKG_NAME}_${PKG_VER}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$DEBROOT" "$DEB"
dpkg-deb -c "$DEB"
echo "built $DEB"
