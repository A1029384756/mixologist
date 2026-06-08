package xdg_desktop_portals

import "core:fmt"
import "shared:dbus"

DBUS_SESSION_IFACE :: "org.freedesktop.portal.Session"

close_session :: proc(
	ctx: ^Context,
	session_handle: dbus.ObjectPath,
	temp_allocator := context.temp_allocator,
) -> Error {
	object_path := fmt.caprint(session_handle)
	err := dbus.method_call_void(ctx.conn, DBUS_DEST, object_path, DBUS_SESSION_IFACE, "Close")
	return err != nil ? .MethodCall : nil
}
