-- luci-app-easytier-lite: tiny two-language layer.
--
-- LuCI picks its language at dispatch time: if a zh-cn catalog is installed and
-- enabled in System -> Language (or luci.main.lang = 'zh_cn'), translate()
-- returns Chinese. Rather than shipping a compiled .lmo catalog we simply ask
-- translate() a string that every zh-cn pack carries; a differing answer means
-- Chinese is live, and we serve our own table. Falls back to English.

local i18n = require "luci.i18n"

local ZH = {
	["EasyTier Lite"] = "EasyTier Lite",

	["Minimal EasyTier node for home routers. Private mode is always enabled: "
		.. "only networks listed under Private Group may handshake or relay through this node."] =
		"面向家用路由的精简 EasyTier 节点。私有模式始终开启：只有「私有组」中列出的网络"
		.. "才能与本节点握手，或经由本节点中继。",

	["For inbound hole punching to work, allow TCP/UDP on the listen port from the WAN zone in Firewall settings."] =
		"若要让对端主动打洞进来，请在防火墙中放行 WAN 区域监听端口的 TCP/UDP。",

	["General Settings"] = "基本设置",
	["Service Status"] = "服务状态",
	["Enable"] = "启用",
	["Network Name"] = "网络名称",
	["Network Secret"] = "网络密码",
	["Node Name"] = "节点名称",
	["Name shown on other nodes (--hostname). Leave empty to use the router system hostname. Max 32 chars."] =
		"其他节点上显示的名字（--hostname）。留空则使用路由器系统主机名，最多 32 个字符。",
	["DHCP Virtual IP"] = "自动分配虚拟 IP",
	["Let the network assign a virtual address automatically (-d)."] =
		"由网络自动分配虚拟地址（-d）。",
	["Virtual IPv4"] = "虚拟 IPv4 地址",
	["Static virtual address of this node (--ipv4), e.g. 10.126.126.2/24. Ignored when DHCP is on."] =
		"本节点的固定虚拟地址（--ipv4），例如 10.126.126.2/24。启用 DHCP 时此项无效。",
	["Peer URLs"] = "对端地址",
	["Initial peers to connect to (-p), e.g. tcp://1.2.3.4:11010. The public server should be listed here."] =
		"启动时连接的对端（-p），例如 tcp://1.2.3.4:11010。公网节点填在这里。",
	["Listen Port"] = "监听端口",
	["TCP and UDP listen on this port (-l tcp/udp://0.0.0.0:PORT). Allow it from WAN in the firewall for direct connections."] =
		"TCP 与 UDP 监听该端口（-l tcp/udp://0.0.0.0:PORT）。要允许对端直连，需在防火墙放行 WAN 侧。",
	["Do Not Listen"] = "不监听",
	["Create Virtual NIC"] = "创建虚拟网卡",
	["Create the virtual NIC for this node (--tun), so its virtual IP is pingable and reachable. "
		.. "Needs /dev/net/tun on the device; leave off for relay / subnet-proxy-only duty."] =
		"为本节点创建虚拟网卡（--tun），创建后其虚拟 IP 才能被 ping 通和访问。"
		.. "需要系统支持 /dev/net/tun；只做中继或子网代理时无需勾选。",
	["Only connect out, never accept connections (--no-listener). Use for pure clients; "
		.. "do not enable on the home router that other nodes connect to."] =
		"只主动外连，不接受入站连接（--no-listener）。适用于纯客户端；"
		.. "家里那台供其他节点接入的路由器不要勾选。",
	["Subnet Proxy"] = "子网代理",
	["Local subnets exported to the virtual network (-n), e.g. 192.168.1.0/24."] =
		"暴露到虚拟网络的本地子网（-n），例如 192.168.1.0/24。",
	["Private Group"] = "私有组",
	["Additional networks admitted while private mode is on, in NAME#SECRET form; "
		.. "NAME# admits by name only (--private-group)."] =
		"私有模式开启时额外放行的网络，格式为 名称#密码；只写 名称# 表示仅按名称放行（--private-group）。",
	["Log Level"] = "日志级别",
	["Console log level (--console-log-level). Lines appear in the log view below (via syslog)."] =
		"控制台日志级别（--console-log-level）。内容会经 syslog 出现在下方日志中。",
	["Off"] = "关闭",
	["Error"] = "错误",
	["Warning"] = "警告",
	["Info"] = "信息",
	["Debug"] = "调试",
	["Trace"] = "跟踪",
	["Log (last 40 lines)"] = "日志（最近 40 行）",

	["Running"] = "运行中",
	["Stopped"] = "已停止",
	["Start"] = "启动",
	["Stop"] = "停止",
	["Restart"] = "重启",
	["(no log lines yet; set log level to info or higher)"] = "暂无日志（把日志级别设为 info 或更低后再看）",
}

local lang = nil

-- Ask the loaded catalog directly: "Save & Apply" is translated in every
-- zh-cn pack, so a different answer means Chinese is the active language.
if type(translate) == "function" then
	local probe = translate("Save & Apply")
	if type(probe) == "string" and probe ~= "" and probe ~= "Save & Apply" then
		lang = "zh"
	end
end

if not lang and type(i18n.context) == "table" and type(i18n.context.lang) == "string" then
	lang = i18n.context.lang
end

if not lang then
	local f = io.open("/etc/config/luci", "r")
	if f then
		local body = f:read("*a")
		f:close()
		lang = body:match("option%s+lang%s+['\"]([%w_%-]+)['\"]")
	end
end

local zh = type(lang) == "string" and lang:lower():match("^zh") ~= nil

local M = {}

function M.t(s)
	if zh and ZH[s] then
		return ZH[s]
	end
	return s
end

function M.is_zh()
	return zh
end

return M
