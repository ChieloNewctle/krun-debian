#!/bin/bash
set -euo pipefail

PKG_NAME="${PKG_NAME:-krun-chielo}"

# renovate: datasource=github-tags depName=libkrun/libkrun
KRUN_VER="${LIBKRUN_VER:-v1.19.4}"
# renovate: datasource=github-tags depName=libkrun/libkrunfw
FW_VER="${KRUNFW_VER:-v5.6.1}"
# renovate: datasource=github-tags depName=containers/crun
CRUN_VER="${CRUN_VER:-1.29.1}"

PREFIX="${PREFIX:-/opt/krun-chielo}"

PKG_VER="${KRUN_VER#v}+crun${CRUN_VER}+fw${FW_VER#v}"

ARCH="$(dpkg --print-architecture)"

DEBROOT="/tmp/debroot-${PKG_NAME}-${PKG_VER}-${ARCH}"

JOBS="$(nproc)"

KRUN_LIBFW_SO_NAME=libkrunfw.so.$(cut -d. -f1 <<<"${FW_VER#v}")
CRUN_LIBKRUN_SO_NAME=libkrun.so.$(cut -d. -f1 <<<"${KRUN_VER#v}")

apt install --no-install-recommends -y \
  bc flex bison python3-pyelftools libelf-dev \
  libbz2-dev libclang-dev libjson-c-dev libcap-dev libseccomp-dev libsystemd-dev \
  patchelf

clone() {
  git clone --depth=1 --shallow-submodules --recurse-submodules --branch="$2" "$1"
}

clone https://github.com/libkrun/libkrunfw.git "$FW_VER"
clone https://github.com/libkrun/libkrun.git "$KRUN_VER"
clone https://github.com/containers/crun.git "$CRUN_VER"

(
  cd libkrunfw
  kernel_version=$(awk -F'= *' '/^KERNEL_VERSION *=/{print $2; exit}' Makefile)
  make -j"$JOBS" \
    ${GUESTARCH:+ARCH="$GUESTARCH"} \
    ${KERNEL_REMOTE_BASE:+KERNEL_REMOTE="${KERNEL_REMOTE_BASE%/}/v$(cut -d. -f1 <<<"${kernel_version#linux-}").x/$kernel_version.tar.xz"}
)
FW_LIB="$(find libkrunfw -maxdepth 1 -name "$KRUN_LIBFW_SO_NAME"'.*' ! -type l | head -n1)"
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
cat >"$DEBROOT/etc/containers/containers.conf.d/47-krun-chielo.conf" <<'EOF'
[engine.runtimes]
krun-chielo = ["/opt/krun-chielo/bin/krun"]
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
Maintainer: local
Depends: $DEP_LINE
Description: Standalone krun runtime at $PREFIX
EOF

readelf -d "$DEBROOT$PREFIX/bin/krun" | grep -E 'RPATH|RUNPATH' || true
readelf -d "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME" | grep -E 'RPATH|RUNPATH' || true
ldd "$DEBROOT$PREFIX/bin/krun"
ldd "$DEBROOT$PREFIX/lib/$CRUN_LIBKRUN_SO_NAME"

DEB="${PKG_NAME}_${PKG_VER}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$DEBROOT" "$DEB"
dpkg-deb -c "$DEB"
echo "built $DEB"
