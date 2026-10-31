import re

FEATS = [
    "aes-gcm",
    "smoltcp",
    "kcp",
    "faketcp",
    "logging",
    "management-rpc",
    "proxy-cidr-monitor",
]

p = "easytier-contrib/easytier-lite/Cargo.toml"
s = open(p, encoding="utf-8").read()
body = "".join('    "%s",\n' % f for f in FEATS)
s = re.sub(
    r"(easytier = \{ workspace = true, features = \[)[^\]]*(\])",
    lambda m: m.group(1) + "\n" + body + m.group(2),
    s,
    flags=re.S,
)
open(p, "w", encoding="utf-8").write(s)

extra = (
    '\n[profile.mini.package."aes-gcm"]\nopt-level = 3\n'
    '\n[profile.mini.package."smoltcp"]\nopt-level = 3\n'
)
with open("Cargo.toml", "a", encoding="utf-8") as f:
    f.write(extra)
print("patched")
