#!/usr/bin/env python3
"""Build an OpenWrt .ipk from the easytier-lite binary and the LuCI files here.

OpenWrt packages are NOT Debian "ar" archives: the container is gzip(tar) with
./debian-binary ("2.0\n"), ./data.tar.gz and ./control.tar.gz inside. Handing
opkg an ar archive makes it report "Malformed package file".

Usage:
    ./build-ipk.py --bin target/mipsel-unknown-linux-musl/mini/easytier-lite \
                   --arch mipsel_24kc --version 0.2.5 --out dist/
"""
import argparse
import gzip
import io
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
LUCI = os.path.join(HERE, "luci")
DATA_ROOT = os.path.join(LUCI, "data")
BIN_DEST = "usr/bin/easytier-lite"

# Everything except the binary; modes are explicit because the checkout may
# lose the executable bit on the init script depending on umask/platform.
EXTRA_FILES = {
    "etc/config/easytier-lite": 0o644,
    "etc/init.d/easytier-lite": 0o755,
    "usr/lib/lua/luci/controller/easytier_lite.lua": 0o644,
    "usr/lib/lua/luci/easytier_lite/i18n.lua": 0o644,
    "usr/lib/lua/luci/model/cbi/easytier_lite.lua": 0o644,
}
CONTROL_FILES = {
    "control": 0o644,
    "conffiles": 0o644,
    "postinst": 0o755,
    "prerm": 0o755,
}


def tar_gz(build):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        build(tf)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, compresslevel=9) as g:
        g.write(raw.getvalue())
    return buf.getvalue()


def add_file(tf, name, data, mode):
    info = tarfile.TarInfo("./" + name)
    info.size = len(data)
    info.mode = mode
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tf.addfile(info, io.BytesIO(data))


def add_dir(tf, name):
    info = tarfile.TarInfo("./" + name if name else ".")
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    tf.addfile(info)


def render_control(arch, version, installed_kb):
    with open(os.path.join(LUCI, "control.in"), encoding="utf-8") as f:
        text = f.read()
    return (text.replace("@ARCH@", arch)
                .replace("@VERSION@", version)
                .replace("@SIZE@", str(installed_kb))).encode()


def build(bin_path, arch, version, out_dir):
    payload = {name: open(os.path.join(DATA_ROOT, name), "rb").read()
               for name in EXTRA_FILES}
    payload[BIN_DEST] = open(bin_path, "rb").read()

    installed_kb = sum(len(v) for v in payload.values()) // 1024

    def data_tar_builder(tf):
        add_dir(tf, "")
        seen = set()
        for name in sorted(payload):
            parts = name.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "/".join(parts[:i])
                if d not in seen:
                    seen.add(d)
                    add_dir(tf, d)
            mode = EXTRA_FILES.get(name, 0o755)
            add_file(tf, name, payload[name], mode)

    control_dir = {}
    for name, mode in CONTROL_FILES.items():
        path = os.path.join(LUCI, name)
        if name == "control":
            control_dir[name] = render_control(arch, version, installed_kb)
        else:
            with open(path, "rb") as f:
                control_dir[name] = f.read()

    def control_tar_builder(tf):
        add_dir(tf, "")
        for name in sorted(control_dir):
            add_file(tf, name, control_dir[name], CONTROL_FILES[name])

    ctl, dat = tar_gz(control_tar_builder), tar_gz(data_tar_builder)

    def outer(tf):
        add_file(tf, "debian-binary", b"2.0\n", 0o644)
        add_file(tf, "data.tar.gz", dat, 0o644)
        add_file(tf, "control.tar.gz", ctl, 0o644)

    blob = tar_gz(outer)
    os.makedirs(out_dir, exist_ok=True)
    name = "luci-app-easytier-lite_%s-1_%s.ipk" % (version, arch)
    path = os.path.join(out_dir, name)
    with open(path, "wb") as f:
        f.write(blob)
    print("%s  (%d B, binary %d B)" % (path, len(blob), len(payload[BIN_DEST])))
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True, help="easytier-lite binary to package")
    ap.add_argument("--arch", required=True, help="OpenWrt arch, e.g. mipsel_24kc")
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "dist"))
    args = ap.parse_args()

    if not os.path.isfile(args.bin):
        sys.exit("no such binary: " + args.bin)
    build(args.bin, args.arch, args.version, args.out)


if __name__ == "__main__":
    main()
