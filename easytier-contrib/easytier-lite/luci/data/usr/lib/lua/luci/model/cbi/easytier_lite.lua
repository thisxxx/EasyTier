-- luci-app-easytier-lite: configuration page for easytier-lite
-- Only exposes options the lite binary actually supports:
--   --network-name --network-secret --hostname --ipv4 -d -p -l --no-listener
--   -n --private-group --console-log-level
-- Private mode is always on in the lite build and cannot be turned off here.

local sys = require "luci.sys"
local util = require "luci.util"
local l10n = require "luci.easytier_lite.i18n"
local T = l10n.t

local function esc(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
	return s
end

local pid = sys.exec("pidof easytier-lite")
local running = (pid ~= nil and pid ~= "")

local function status_html()
	local url = luci.dispatcher.build_url("admin/vpn/easytier_lite")
	if running then
		local links = string.format(
			'<a href="%s/restart">%s</a> &middot; <a href="%s/stop">%s</a>',
			url, T("Restart"), url, T("Stop"))
		return string.format(
			'<span style="color:green;font-weight:bold">%s</span> (pid %s) &nbsp; %s',
			T("Running"), esc(util.trim(pid)), links)
	end
	return string.format(
		'<span style="color:red;font-weight:bold">%s</span> &nbsp; <a href="%s/start">%s</a>',
		T("Stopped"), url, T("Start"))
end

local function log_html()
	local out = sys.exec("logread -l 300 2>/dev/null | grep easytier-lite | tail -n 40")
	if out == nil or out == "" then
		out = T("(no log lines yet; set log level to info or higher)")
	end
	return "<pre style=\"max-height:360px;overflow:auto;background:#f5f5f5;padding:6px;font-size:12px\">"
		.. esc(out) .. "</pre>"
end

m = Map("easytier-lite", T("EasyTier Lite"),
	T("Minimal EasyTier node for home routers. Private mode is always enabled: "
		.. "only networks listed under Private Group may handshake or relay through this node.")
	.. "<br />"
	.. T("For inbound hole punching to work, allow TCP/UDP on the listen port from the WAN zone in Firewall settings."))

s = m:section(NamedSection, "config", "easytier_lite", T("General Settings"))
s.addremove = false
s.anonymous = false

o = s:option(DummyValue, "_status", T("Service Status"))
o.rawhtml = true
o.cfgvalue = function() return status_html() end

o = s:option(Flag, "enabled", T("Enable"))
o.rmempty = false

o = s:option(Value, "network_name", T("Network Name"))
o.rmempty = false
o.placeholder = "home-net"

o = s:option(Value, "network_secret", T("Network Secret"))
o.password = true

o = s:option(Value, "hostname", T("Node Name"),
	T("Name shown on other nodes (--hostname). Leave empty to use the router system hostname. Max 32 chars."))
o.placeholder = "k2p"

o = s:option(Flag, "dhcp", T("DHCP Virtual IP"),
	T("Let the network assign a virtual address automatically (-d)."))
o.default = "0"
o.rmempty = false

o = s:option(Value, "ipv4", T("Virtual IPv4"),
	T("Static virtual address of this node (--ipv4), e.g. 10.126.126.2/24. Ignored when DHCP is on."))
o.datatype = "ip4addr"
o.placeholder = "10.126.126.2/24"
o:depends("dhcp", "0")

o = s:option(DynamicList, "peers", T("Peer URLs"),
	T("Initial peers to connect to (-p), e.g. tcp://1.2.3.4:11010. The public server should be listed here."))

o = s:option(Value, "listen_port", T("Listen Port"),
	T("TCP and UDP listen on this port (-l tcp/udp://0.0.0.0:PORT). Allow it from WAN in the firewall for direct connections."))
o.datatype = "port"
o.default = "11010"
o.placeholder = "11010"
o:depends("no_listener", "0")

o = s:option(Flag, "no_listener", T("Do Not Listen"),
	T("Only connect out, never accept connections (--no-listener). Use for pure clients; "
		.. "do not enable on the home router that other nodes connect to."))
o.default = "0"
o.rmempty = false

o = s:option(DynamicList, "proxy_networks", T("Subnet Proxy"),
	T("Local subnets exported to the virtual network (-n), e.g. 192.168.1.0/24."))

o = s:option(DynamicList, "private_groups", T("Private Group"),
	T("Additional networks admitted while private mode is on, in NAME#SECRET form; "
		.. "NAME# admits by name only (--private-group)."))

o = s:option(ListValue, "log_level", T("Log Level"),
	T("Console log level (--console-log-level). Lines appear in the log view below (via syslog)."))
o.default = "info"
o:value("off", T("Off"))
o:value("error", T("Error"))
o:value("warn", T("Warning"))
o:value("info", T("Info"))
o:value("debug", T("Debug"))
o:value("trace", T("Trace"))

o = s:option(DummyValue, "_log", T("Log (last 40 lines)"))
o.rawhtml = true
o.cfgvalue = function() return log_html() end

m.on_after_commit = function()
	local en = m.uci:get("easytier-lite", "config", "enabled")
	if en == "1" then
		luci.sys.exec("/etc/init.d/easytier-lite restart >/dev/null 2>&1")
	end
end

return m
