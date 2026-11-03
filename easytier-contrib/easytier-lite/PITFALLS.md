# easytier-lite 踩坑记录（PITFALLS）

本文档记录 lite 版从立项到 0.2.7 全过程中踩过的坑，按「编译 / 打包 / 界面 / CI / 网络 / 部署」分类。
每条坑都付了验证方法或修复提交，供后续维护与二次精简时参考。

---

## 一、编译与 feature 裁剪

### 1. 只有 2.7.0 的 feature 门控是完整的

- **2.0.2 / 2.3.2 的门控是坏的**：`tunnel/quic.rs`、`gateway/tokio_smoltcp/*` 等模块没有 `#[cfg(feature)]`
  包裹，关掉对应 feature 直接 `E0433 cannot find crate quinn`。
- 结论：**做减法只能基于 2.7.x**，老版本关 feature 编不过去，别浪费时间。

### 2. workspace `default-members` 会覆盖 `--no-default-features`

- 测 2.3.2 时四组体积结果完全相同（16,504,120 B）——因为 workspace 里 `easytier-web`
  以 `default-features = true` 依赖 easytier，把裁剪全盘覆盖。
- 正确姿势：`cargo build -p easytier --bin easytier-core` 明确指定包，别依赖全局参数。

### 3. `opt-level = "z"` 要给热路径单独开 O3

- `profile.mini` 全局 `opt-level = "z"` 后 mipsel 从 11.0 MB 降到 6.3 MB，
  但 `aes-gcm` 和 `smoltcp` 是转发热路径，必须单独覆盖回 `opt-level = 3`
  （见根 `Cargo.toml` 的 `[profile.mini.package."aes-gcm"]`），否则吞吐明显劣化。

### 4. `smoltcp` ≠ TUN，两个是完全不同的东西

- `smoltcp` feature 实际映射到 `easytier-core/proxy-smoltcp-stack`，**只是子网代理的用户态协议栈**
  （ICMP/TCP 代答），全程不经过本地网卡。
- `tun` feature（`dep:tun` + `dep:smoltcp` + `linux-netlink`）才负责创建虚拟网卡。
- 只开 smoltcp 的节点：中继、子网代理可用；虚拟 IP 不可 ping、不可访问。

### 5. 编进 tun ≠ 开 tun（0.2.6 的教训）

- 0.2.6 把 `tun` 加回了 feature，但 lite 的 `default_flags()` 里硬编码着
  `no_tun: Some(true)`，运行时开关仍是关——**虚拟网卡照样不创建**，
  症状依然是「对端看到虚拟 IP 上线但 ping 不通」。
- 0.2.7 修复：新增 `--tun` 参数，默认仍关（纯中继/子网代理部署零变化），
  传 `--tun` 才设 `no_tun=false`。
- 教训：**feature 只决定代码编不编，FlagsPatch 运行时开关是另一层**，两层都要查。

### 6. 打洞三件套：`dns-resolver` + `tcp-hole-punch` + 默认监听

- 关掉 `dns-resolver` 时 STUN 客户端读不了 `stun.easytier.cn` 的 TXT 记录，
  日志有 `this build does not include TXT DNS resolution`，UDP 打洞失去公网 STUN 辅助。
- `tcp-hole-punch` 是零依赖纯代码开关（`= []`），关掉时核心直接置
  `disable_tcp_hole_punching`，CGNAT 下少了最后一条路。
- 打洞实现在 `easytier-core/src/connectivity/hole_punch/`，**无任何 cfg 门控**，
  是完整版同款代码，只需把运行时开关拨对。

### 7. `faketcp` 在 Windows 上拖死整个包

- faketcp 经 `pnet_datalink` 静态链接 `packet.dll`（Npcap/WinPcap），
  Windows 机器没装 Npcap 时连 `--help` 都起不来：
  `error while loading shared libraries: packet.dll`。
- faketcp 只在显式写 `faketcp://` 地址时才启用，默认监听不含它，
  普通 udp/kcp 组网完全用不到。0.2.2 起移除，mipsel 还顺带减了 53 KB。

### 8. `--hostname` 的归一化在上游核心，CLI 不要重复校验

- 优先级链（`global_ctx.rs`）：运行时节点名 > 配置文件 hostname > `gethostname()`。
- 归一化在 `easytier-core/src/config/toml.rs` 的 `get_hostname`：去控制字符、
  **静默截断到 32 字符**（不报错）、全空则回退系统主机名。
- lite 早期自己加了一层 trim/校验，行为反而和完整版不一致（完整版对
  `--hostname "a\tb"` 静默变 `ab`，自己写的版本却报错）。0.2.5 起删掉，
  CLI 只透传。

---

## 二、ipk 打包（opkg）

### 9. OpenWrt 的 ipk 不是 Debian 的 ar 容器！

- 用 `ar` + `debian-binary/data.tar.gz/control.tar.gz` 打的包（Debian 格式），
  opkg 直接报：
  ```
  pkg_init_from_file: Malformed package file /tmp/upload.ipk
  ```
- **OpenWrt 的 .ipk 外层是 gzip 压缩的 tar**，tar 里依次是：
  `./debian-binary`（内容 `2.0\n`）、`./data.tar.gz`、`./control.tar.gz`；
  内层 tar 为 GNU/ustar 格式，**文件名带 `./` 前缀**，目录项齐全。
- 排障方法：从 downloads.openwrt.org 下载一个官方 mipsel_24kc 包，
  逐字节对照三层结构。
- 仓库里的 `build-ipk.py` 已按正确格式实现，纯 Python 无外部依赖。

### 10. CRLF 会杀死 init 脚本

- Windows 上开发时 `\r\n` 进 shell 脚本，运行报 `\r: command not found`。
- 仓库用 `.gitattributes` 把 `luci/**`、`*.py` 锁死 LF；发布前用
  `grep -c $'\r'` 复查一遍。

---

## 三、LuCI 界面

### 11. 中文跟随平台语言，不用 .lmo 编译包

- LuCI 运行时装载语言包，所以本地 i18n 模块按此探测：
  1. `translate("Save & Apply")` 返回值不是英文 → 中文已生效；
  2. 否则读 `/etc/config/luci` 的 `option lang`；
  3. 都不成立用英文原文。
- 免去 po2lmo 工具链；中文字典见 `luci/data/usr/lib/lua/luci/easytier_lite/i18n.lua`。

### 12. i18n 的 key 是多行字符串拼接，校验必须先还原

- 界面与字典里的 key 都可能写成 `"aaa" ..\n\t\t.. "bbb"`，
  逐行 grep 或简单子串匹配会产生大量误报/漏报。
- 校验脚本先把所有拼接段还原再双向比对（界面用到的 key ⊆ 字典，字典 key ⊆ 界面）。
  一个空格的差异就会静默退回英文。

### 13. CBI 选项联动

- `Flag` 参与 `depends()` 时必须 `rmempty = false`，否则勾选值存不进 UCI。
- 语义联动示例：勾「创建虚拟网卡」才显示「DHCP 虚拟 IP」和「虚拟 IPv4」
  ——没网卡时配 IP 没有意义。

---

## 四、CI（GitHub Actions）

### 14. `cancel-in-progress` 会顶掉旧构建

- 连续推送时旧 run 被自动取消，注意别误以为构建失败；取消的 run
  不会产生 Release（publish 一起被取消），版本序列反而更干净。

### 15. macOS Intel runner 排队取消

- `macos-latest`（x86_64）job 出现过两次排队 15 分钟后被 cancelled，
  `runner_name` 为空，是 GitHub 没分机器，不是代码问题。
- 其他 15 个 target 正常时，可用 rerun-failed-jobs 补跑；
  仍取消就接受缺席（除非确需 Intel macOS 包）。

### 16. 构建产物哈希验证走 API，不走 Release 下载

- `release-assets.githubusercontent.com` 直连经常 TLS 握手失败（本机 -k 也救不了），
  而且带 Authorization 的 302 后 blob 会 401。
- 可靠通道：**API 的 Actions artifact 下载**（先取 `redirect_url` 再匿名下载，
  落在 `productionresultssa6.blob.core.windows.net`）。
- 更省事的：GitHub Release API 的资产带 `digest`（sha256）字段，
  **不下载就能校验整包**。
- 交叉验证思路：镜像站（gh-proxy 等）回源直转的包 + 官方 CI artifact，
  两条独立来源哈希一致即可闭环。

---

## 五、网络与环境（本机开发侧）

### 17. TLS / 代理三件套

- `curl` 访问 GitHub 系必须 `-k`；`git` 必须 `GIT_SSL_NO_VERIFY=1`。
- git 的 schannel 后端 push 经常握手失败：`git -c http.sslBackend=openssl push`
  且常需重试 2-3 次。
- GitHub 被墙/抖动时：镜像站（gh-proxy.com 等）能拉 Release 产物；
  API 端点（api.github.com）往往比网页端先恢复，抓到 200 窗口就赶紧下载。
- 本地有 Caddy 类反代占 127.0.0.1:443 时，注意它只是应答本地，上游 502 依然不通。

### 18. Git Bash `/tmp` 与 Windows Python 不互通

- `curl -o /tmp/x.json` 写进 Git Bash 的临时目录，随后调用的 Windows 原生
  Python 读不到。输出文件一律用工作目录相对路径。

### 19. UPX 壳内扫不到字符串

- 验证二进制里有没有某功能，直接 `strings` 是没用的——CI 产物全部 UPX 压缩。
- 先 `upx -d` 解壳再扫；验证过 tun 的例子：解壳后可见
  `TunDeviceError`（`#[cfg(feature = "tun")]` 门控的错误变体）、
  `virtual_nic`、`netlink` 符号。

---

## 六、路由器部署

### 20. 主路由打洞的两个前置条件（与 easytier 无关但必做）

- **WAN 防火墙放行监听端口**（默认 11010 的 tcp+udp）。OpenWrt 默认 WAN input 全 drop，
  打洞成功入向包也会被吃掉：
  ```
  config rule
      option name 'easytier'
      option src 'wan'
      option proto 'tcp udp'
      option dest_port '11010'
      option target 'ACCEPT'
  ```
- **多拨 / mwan3 会毁掉 STUN**：STUN 探测到的出口地址与实际线路不一致，打洞反复失败。
  需要把 easytier 流量策略路由到单条 WAN。
- 宽带是公网 IP（PPPoE 拿到公网地址）时根本不用打洞，直连即可；
  IPv6 公网可达时优先写 IPv6 对端，比打洞省事。

### 21. 主路由上不用开 `upnp`

- lite 装在 NAT 网关本体上，向自己申请端口映射没有意义。
  除非部署在旁路由/子网内设备上，才考虑开 `upnp`。

### 22. Padavan（老毛子）不能用这个 ipk 的服务与界面

- ipk 里的 procd 服务、LuCI 页面是 OpenWrt 体系的东西，Padavan 上无效。
- Padavan 只取纯二进制（musl 静态，解压即用），手动按原参数启动。
- Padavan 内核需带 TUN 支持（`/dev/net/tun` 存在），K2P 常见固件一般都有；
  `--tun` 起不来先查这个设备节点。

---

## 附：体积演进参考（mipsel zip）

| 版本 | 大小 | 变化原因 |
|---|---|---|
| 0.2.0 | 1,739,720 | profile.mini + B 档 feature |
| 0.2.1 | 1,732,913 | +`--hostname` |
| 0.2.2 | 1,714,827 | −faketcp（连带去掉 Windows Npcap 依赖） |
| 0.2.5 | 1,902,086 | +dns-resolver +tcp-hole-punch（+187 KB，几乎全是 hickory DNS） |
| 0.2.6 | 2,028,090 | +tun（rust-tun + netlink-sys，+126 KB） |
| 0.2.7 | 2,028,363 | +`--tun` 参数（+273 B，纯开关） |

对 128 MB Flash 的 K2P 无压力；`opt-level="z"` 全局压缩 + 热路径单独 O3 的组合
是体积与性能的平衡点。
