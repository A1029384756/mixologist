package xdg_desktop_portals

import "core:log"
import "shared:dbus"

DBUS_BACKGROUND_IFACE :: "org.freedesktop.portal.Background"

Background_RequestBackgroundReq :: struct {
	parent_window: string,
	options:       Background_RequestBackgroundOptions `dbus:"a{sv}"`,
}
Background_RequestBackgroundOptions :: struct {
	handle_token:     string,
	reason:           string,
	autostart:        bool,
	commandline:      []string `dbus:"omitempty"`,
	dbus_activatable: bool `dbus_name:"dbus-activatable"`,
}
Background_RequestBackgroundResp :: struct {
	response: u32,
	results:  Background_RequestBackgroundResults `dbus:"a{sv}"`,
}
Background_RequestBackgroundResults :: struct {
	background: bool,
	autostart:  bool,
}

background_request_background :: proc(
	ctx: ^Context,
	reason: string,
	autostart: bool,
	commandline: []string,
	dbus_activatable: bool,
	temp_allocator := context.temp_allocator,
) -> (
	bg, can_autostart: bool,
	err: Error,
) {
	handle_token := generate_token(ctx.token_base, temp_allocator)
	resp := portal_call_blocking(
		Background_RequestBackgroundResp,
		ctx.conn,
		DBUS_BACKGROUND_IFACE,
		"RequestBackground",
		Background_RequestBackgroundReq {
			ctx.parent,
			{handle_token, reason, autostart, commandline, dbus_activatable},
		},
		handle_token,
	) or_return

	return resp.results.background, resp.results.autostart, nil
}

Background_SetStatusReq :: struct {
	options: Background_SetStatusOptions `dbus:"a{sv}"`,
}
Background_SetStatusOptions :: struct {
	message: string,
}

background_set_status :: proc(ctx: ^Context, status: string) -> Error {
	if status_len := len(status); status_len > 96 {
		log.errorf("status message is longer than 96 characters, got: %v", status_len)
	}
	err := dbus.method_call_void(
		ctx.conn,
		DBUS_DEST,
		DBUS_PATH,
		DBUS_BACKGROUND_IFACE,
		"SetStatus",
		Background_SetStatusReq{{status}},
	)
	return err != nil ? .MethodCall : nil
}
