# easytier-lite

A stripped-down EasyTier node meant for old routers: no config file, no config
server, no clap — a dozen flags are the whole surface. Built with
`--profile mini` (opt-level `z`, LTO, panic=abort, strip) and UPX packed, so a
mipsel binary lands around 1.9 MB.

## Package for OpenWrt / ImmortalWrt

`luci/` holds a procd service, a UCI config and a LuCI page (VPN → EasyTier
Lite); `build-ipk.py` wraps them plus a binary into an `.ipk`:

```sh
./build-ipk.py --bin target/mipsel-unknown-linux-musl/mini/easytier-lite \
               --arch mipsel_24kc --version 0.2.5 --out dist
```

Notes on the format: OpenWrt packages are **gzip(tar)**, not Debian `ar`
archives. The outer tar carries `./debian-binary` (`2.0\n`), `./data.tar.gz`
and `./control.tar.gz`; the inner tars are GNU/ustar with `./`-prefixed names.
An `ar` container is rejected by opkg with `Malformed package file`.

The `Release` workflow builds ipk for mipsel_24kc, mips_24kc, arm_arm926ej-s,
arm_cortex-a7_neon-vfpv4, aarch64_cortex-a53 and x86_64 next to the plain
binaries. Those arch names are what `opkg` compares against; for a different
target pass the matching OpenWrt arch to `--arch`.

Install:

```sh
opkg install luci-app-easytier-lite_<version>-1_<arch>.ipk
```

The page lives under *VPN → EasyTier Lite*. All traffic needs the listener port
open on the WAN zone (tcp **and** udp, default 11010), otherwise a successful
hole punch still cannot be reached from outside.
