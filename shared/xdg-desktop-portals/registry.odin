package xdg_desktop_portals

import "shared:dbus"

DBUS_REGISTRY_IFACE :: "org.freedesktop.host.portal.Registry"

Registry_RegisterReq :: struct {
	appid:   string,
	options: struct{} `dbus:"a{sv}"`,
}

registry_register :: proc(ctx: ^Context, appid: string) -> Error {
	err := dbus.method_call_void(
		ctx.conn,
		DBUS_DEST,
		DBUS_PATH,
		DBUS_REGISTRY_IFACE,
		"Register",
		Registry_RegisterReq{appid = appid},
	)
	return err != nil ? .MethodCall : nil
}
