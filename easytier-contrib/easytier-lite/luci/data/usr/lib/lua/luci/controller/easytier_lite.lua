module("luci.controller.easytier_lite", package.seeall)

local l10n = require "luci.easytier_lite.i18n"

function index()
	if not io.open("/etc/config/easytier-lite") then
		return
	end
	entry({"admin", "vpn", "easytier_lite"}, cbi("easytier_lite"), l10n.t("EasyTier Lite"), 60).dependent = false
	entry({"admin", "vpn", "easytier_lite", "start"}, call("action_start")).leaf = true
	entry({"admin", "vpn", "easytier_lite", "stop"}, call("action_stop")).leaf = true
	entry({"admin", "vpn", "easytier_lite", "restart"}, call("action_restart")).leaf = true
end

local function run(cmd)
	luci.sys.exec(cmd)
	luci.http.redirect(luci.dispatcher.build_url("admin/vpn/easytier_lite"))
end

function action_start()
	run("/etc/init.d/easytier-lite enable >/dev/null 2>&1; /etc/init.d/easytier-lite start >/dev/null 2>&1")
end

function action_stop()
	run("/etc/init.d/easytier-lite stop >/dev/null 2>&1")
end

function action_restart()
	run("/etc/init.d/easytier-lite restart >/dev/null 2>&1")
end
