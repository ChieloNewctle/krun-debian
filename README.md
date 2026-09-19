# krun-debian

[![License](https://img.shields.io/badge/license-MIT-informational.svg)](#license)
[![Build status](https://github.com/ChieloNewctle/krun-debian/actions/workflows/build-deb.yml/badge.svg)](https://github.com/ChieloNewctle/oci-hook-block-private-net/actions)

Debian packaging for `krun-chielo`: a standalone
[crun](https://github.com/containers/crun) build with
[libkrun](https://github.com/libkrun/libkrun) /
[libkrunfw](https://github.com/libkrun/libkrunfw), installed under
`/opt/krun-chielo`.

Pinned versions are in `deb.sh` and bumped by Renovate from upstream Git tags.

## Install

`deb` is available on `fury.io`. To add the repository to `apt`:

```bash
curl https://apt.fury.io/chielo/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/fury-chielo.gpg
sudo tee /etc/apt/sources.list.d/fury-chielo.sources > /dev/null <<EOF
Types: deb
URIs: https://apt.fury.io/chielo/
Suites: /
Signed-By: /etc/apt/keyrings/fury-chielo.gpg
EOF
sudo apt update
sudo apt install krun-chielo
```

The package drops `/etc/containers/containers.conf.d/47-krun-chielo.conf`, so
Podman sees runtime `krun-chielo`.

## Usage

Host needs `/dev/kvm` and the user should be in the group `kvm`.

```bash
podman run --runtime krun-chielo ...
```

## Build

`deb.sh` is meant to run in `rust:1-trixie` (needs `rustc`/`cargo` for libkrun,
and Debian tooling for the kernel payload and `.deb`).

## License

Packaging in this repository is under the [MIT License](./LICENSE).

The `.deb` ships upstream binaries. Their licenses apply to those components:
[crun](https://github.com/containers/crun) (GPL-2.0-or-later),
[libkrun](https://github.com/libkrun/libkrun) (Apache-2.0),
[libkrunfw](https://github.com/libkrun/libkrunfw) (LGPL-2.1-only, plus a bundled
Linux kernel under GPL-2.0-only).
