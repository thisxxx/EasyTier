-- luci-app-easytier-lite: configuration page for easytier-lite
-- Only exposes options the lite binary actually supports:
--   --network-name --network-secret --hostname --ipv4 -d -p -l --no-listener
--   -n --private-group --console-log-level
-- Private mode is always on in the lite build and cannot be turned off here.

local sys = require "luci.sys"
local util = require "luci.util"

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
			url, translate("Restart"), url, translate("Stop"))
		return string.format(
			'<span style="color:green;font-weight:bold">%s</span> (pid %s) &nbsp; %s',
			translate("Running"), esc(util.trim(pid)), links)
	end
	return string.format(
		'<span style="color:red;font-weight:bold">%s</span> &nbsp; <a href="%s/start">%s</a>',
		translate("Stopped"), url, translate("Start"))
end

local function log_html()
	local out = sys.exec("logread -l 300 2>/dev/null | grep easytier-lite | tail -n 40")
	if out == nil or out == "" then
		out = translate("(no log lines yet; set log level to info or higher)")
	end
	return "<pre style=\"max-height:360px;overflow:auto;background:#f5f5f5;padding:6px;font-size:12px\">"
		.. esc(out) .. "</pre>"
end

m = Map("easytier-lite", translate("EasyTier Lite"),
	translate("Minimal EasyTier node for home routers. Private mode is always enabled: only networks listed under Private Group may handshake or relay through this node.")
	.. "<br />"
	.. translate("For inbound hole punching to work, allow TCP/UDP on the listen port from the WAN zone in Firewall settings."))

s = m:section(NamedSection, "config", "easytier_lite", translate("General Settings"))
s.addremove = false
s.anonymous = false

o = s:option(DummyValue, "_status", translate("Service Status"))
o.rawhtml = true
o.cfgvalue = function() return status_html() end

o = s:option(Flag, "enabled", translate("Enable"))
o.rmempty = false

o = s:option(Value, "network_name", translate("Network Name"))
o.rmempty = false
o.placeholder = "home-net"

o = s:option(Value, "network_secret", translate("Network Secret"))
o.password = true

o = s:option(Value, "hostname", translate("Node Name"),
	translate("Name shown on other nodes (--hostname). Leave empty to use the router system hostname. Max 32 chars."))
o.placeholder = "k2p"

o = s:option(Flag, "dhcp", translate("DHCP Virtual IP"),
	translate("Let the network assign a virtual address automatically (-d)."))
o.default = "0"
o.rmempty = false

o = s:option(Value, "ipv4", translate("Virtual IPv4"),
	translate("Static virtual address of this node (--ipv4), e.g. 10.126.126.2/24. Ignored when DHCP is on."))
o.datatype = "ip4addr"
o.placeholder = "10.126.126.2/24"
o:depends("dhcp", "0")

o = s:option(DynamicList, "peers", translate("Peer URLs"),
	translate("Initial peers to connect to (-p), e.g. tcp://1.2.3.4:11010. The public server should be listed here."))

o = s:option(Value, "listen_port", translate("Listen Port"),
	translate("TCP and UDP listen on this port (-l tcp/udp://0.0.0.0:PORT). Allow it from WAN in the firewall for direct connections."))
o.datatype = "port"
o.default = "11010"
o.placeholder = "11010"
o:depends("no_listener", "0")

o = s:option(Flag, "no_listener", translate("Do Not Listen"),
	translate("Only connect out, never accept connections (--no-listener). Use for pure clients; do not enable on the home router that other nodes connect to."))
o.default = "0"
o.rmempty = false

o = s:option(DynamicList, "proxy_networks", translate("Subnet Proxy"),
	translate("Local subnets exported to the virtual network (-n), e.g. 192.168.1.0/24."))

o = s:option(DynamicList, "private_groups", translate("Private Group"),
	translate("Additional networks admitted while private mode is on, in NAME#SECRET form; NAME# admits by name only (--private-group)."))

o = s:option(ListValue, "log_level", translate("Log Level"),
	translate("Console log level (--console-log-level). Lines appear in the log view below (via syslog)."))
o.default = "info"
o:value("off", translate("Off"))
o:value("error", translate("Error"))
o:value("warn", translate("Warning"))
o:value("info", translate("Info"))
o:value("debug", translate("Debug"))
o:value("trace", translate("Trace"))

o = s:option(DummyValue, "_log", translate("Log (last 40 lines)"))
o.rawhtml = true
o.cfgvalue = function() return log_html() end

m.on_after_commit = function()
	local en = m.uci:get("easytier-lite", "config", "enabled")
	if en == "1" then
		luci.sys.exec("/etc/init.d/easytier-lite restart >/dev/null 2>&1")
	end
end

return m
