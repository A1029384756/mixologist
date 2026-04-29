package mixologist

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"
import "dbus"

GlobalShortcuts_Session :: struct {
	conn:           ^dbus.Connection,
	session_handle: dbus.ObjectPath,
	base:           string,
}

GlobalShortcut :: struct {
	id:                  string,
	description:         string,
	trigger_description: string,
}

@(private = "file")
GlobalShortcut_OutMetadata :: struct {
	description:         string,
	trigger_description: string,
}
@(private = "file")
GlobalShortcut_Out :: struct {
	id:       string,
	metadata: GlobalShortcut_OutMetadata `dbus:"a{sv}"`,
}

@(private = "file")
GlobalShortcut_InMetadata :: struct {
	description:       string,
	preferred_trigger: string,
}
@(private = "file")
GlobalShortcut_In :: struct {
	id:       string,
	metadata: GlobalShortcut_InMetadata `dbus:"a{sv}"`,
}

GlobalShortcuts_SignalType :: enum {
	ACTIVATED,
	DEACTIVATED,
	SHORTCUTS_CHANGED,
}
GlobalShortcuts_SignalTypes :: bit_set[GlobalShortcuts_SignalType]

GlobalShortcuts_CreateSessionOptions :: struct {
	handle_token:         string,
	session_handle_token: string,
}
GlobalShortcuts_CreateSessionReq :: struct {
	options: GlobalShortcuts_CreateSessionOptions `dbus:"a{sv}"`,
}
GlobalShortcuts_CreateSessionResults :: struct {
	session_handle: dbus.ObjectPath,
}
GlobalShortcuts_CreateSessionResp :: struct {
	response: u32,
	results:  GlobalShortcuts_CreateSessionResults `dbus:"a{sv}"`,
}

GlobalShortcuts_HandleTokenOptions :: struct {
	handle_token: string,
}

GlobalShortcuts_BindShortcutsReq :: struct {
	session_handle: dbus.ObjectPath,
	shortcuts:      []GlobalShortcut_In,
	parent_window:  string,
	options:        GlobalShortcuts_HandleTokenOptions `dbus:"a{sv}"`,
}

GlobalShortcuts_ListShortcutsReq :: struct {
	session_handle: dbus.ObjectPath,
	options:        GlobalShortcuts_HandleTokenOptions `dbus:"a{sv}"`,
}

GlobalShortcuts_ShortcutsResults :: struct {
	shortcuts: []GlobalShortcut_Out,
}
GlobalShortcuts_ShortcutsResp :: struct {
	response: u32,
	results:  GlobalShortcuts_ShortcutsResults `dbus:"a{sv}"`,
}

Registry_RegisterReq :: struct {
	appid:   string,
	options: struct{} `dbus:"a{sv}"`,
}


Error :: union {
	cstring,
}

Portals_Tick :: proc(conn: ^dbus.Connection) -> bool {
	return bool(dbus.connection_read_write_dispatch(conn, 0))
}

Registry_Register :: proc(conn: ^dbus.Connection, appid: string) -> Error {
	err: dbus.Error
	dbus.error_init(&err)
	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.host.portal.Registry",
		"Register",
	)
	defer dbus.message_unref(msg)

	dbus.marshal(msg, Registry_RegisterReq{appid = appid})
	reply := dbus.connection_send_with_reply_and_block(conn, msg, dbus.TIMEOUT_USE_DEFAULT, &err)
	if dbus.error_is_set(&err) do return err.message
	defer dbus.message_unref(reply)
	return nil
}

GlobalShortcuts_Token_Generate :: proc(base: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s_%v", base, rand.int31(), allocator = allocator)
}

GlobalShortcuts_Init :: proc(
	gs: ^GlobalShortcuts_Session,
	appid, session_base: string,
	signals: GlobalShortcuts_SignalTypes,
	signal_handler: dbus.HandleMessageProc,
	signal_userdata: rawptr,
	signal_data_free: dbus.FreeProc,
) -> Error {
	err: dbus.Error
	dbus.error_init(&err)
	gs.conn = dbus.bus_get(.SESSION, &err)
	if dbus.error_is_set(&err) do return err.message

	gs.base = session_base

	if !_is_sandboxed() {
		Registry_Register(gs.conn, appid) or_return
	}

	if .ACTIVATED in signals {
		dbus.bus_add_match(
			gs.conn,
			"type='signal',interface='org.freedesktop.portal.GlobalShortcuts',member='Activated'",
			&err,
		)
		if dbus.error_is_set(&err) do return err.message
	}
	if .DEACTIVATED in signals {
		dbus.bus_add_match(
			gs.conn,
			"type='signal',interface='org.freedesktop.portal.GlobalShortcuts',member='Deactivated'",
			&err,
		)
		if dbus.error_is_set(&err) do return err.message
	}
	if .SHORTCUTS_CHANGED in signals {
		dbus.bus_add_match(
			gs.conn,
			"type='signal',interface='org.freedesktop.portal.GlobalShortcuts',member='ShortcutsChanged'",
			&err,
		)
		if dbus.error_is_set(&err) do return err.message
	}
	dbus.connection_add_filter(gs.conn, signal_handler, signal_userdata, signal_data_free)

	return nil
}

GlobalShortcuts_Deinit :: proc(gs: ^GlobalShortcuts_Session, allocator := context.allocator) {
	dbus.connection_unref(gs.conn)
	delete(string(gs.session_handle), allocator)
}

GlobalShortcuts_CreateSession :: proc(
	gs: ^GlobalShortcuts_Session,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> Error {
	handle_token := GlobalShortcuts_Token_Generate(gs.base, temp_allocator)

	resp: GlobalShortcuts_CreateSessionResp
	portal_call(
		gs.conn,
		"org.freedesktop.portal.GlobalShortcuts",
		"CreateSession",
		GlobalShortcuts_CreateSessionReq {
			options = {
				handle_token = handle_token,
				session_handle_token = GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
			},
		},
		handle_token,
		&resp,
		allocator,
		temp_allocator,
	) or_return

	if resp.response != 0 {
		log.infof("createsession error response code: %d", resp.response)
		return "CreateSession failed"
	}

	gs.session_handle = resp.results.session_handle
	log.debugf("obtained session handle: %s", gs.session_handle)
	return nil
}

GlobalShortcuts_CloseSession :: proc(
	gs: ^GlobalShortcuts_Session,
	allocator := context.temp_allocator,
) -> Error {
	if len(gs.session_handle) == 0 do return "No session handle available"

	err: dbus.Error
	dbus.error_init(&err)

	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		strings.clone_to_cstring(string(gs.session_handle), allocator),
		"org.freedesktop.portal.Session",
		"Close",
	)
	defer dbus.message_unref(msg)

	reply := dbus.connection_send_with_reply_and_block(
		gs.conn,
		msg,
		dbus.TIMEOUT_USE_DEFAULT,
		&err,
	)
	if dbus.error_is_set(&err) do return err.message
	defer dbus.message_unref(reply)
	return nil
}

GlobalShortcuts_BindShortcuts :: proc(
	gs: ^GlobalShortcuts_Session,
	shortcuts: []GlobalShortcut,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	out: []GlobalShortcut,
	err: Error,
) {
	if len(gs.session_handle) == 0 do return nil, "No session handle available"

	wire_shortcuts := make([]GlobalShortcut_In, len(shortcuts), temp_allocator)
	for s, i in shortcuts {
		wire_shortcuts[i] = {
			id = s.id,
			metadata = {description = s.description, preferred_trigger = s.trigger_description},
		}
	}

	handle_token := GlobalShortcuts_Token_Generate(gs.base, temp_allocator)
	resp: GlobalShortcuts_ShortcutsResp
	portal_call(
		gs.conn,
		"org.freedesktop.portal.GlobalShortcuts",
		"BindShortcuts",
		GlobalShortcuts_BindShortcutsReq {
			session_handle = gs.session_handle,
			shortcuts = wire_shortcuts,
			parent_window = "",
			options = {handle_token = handle_token},
		},
		handle_token,
		&resp,
		allocator,
		temp_allocator,
	) or_return

	if resp.response != 0 {
		log.infof("bindshortcuts error response code: %d", resp.response)
	}
	return _flatten_shortcuts(resp.results.shortcuts, allocator), nil
}

GlobalShortcuts_ListShortcuts :: proc(
	gs: ^GlobalShortcuts_Session,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	out: []GlobalShortcut,
	err: Error,
) {
	if len(gs.session_handle) == 0 do return nil, "No session handle available"

	handle_token := GlobalShortcuts_Token_Generate(gs.base, temp_allocator)
	resp: GlobalShortcuts_ShortcutsResp
	portal_call(
		gs.conn,
		"org.freedesktop.portal.GlobalShortcuts",
		"ListShortcuts",
		GlobalShortcuts_ListShortcutsReq {
			session_handle = gs.session_handle,
			options = {handle_token = handle_token},
		},
		handle_token,
		&resp,
		allocator,
		temp_allocator,
	) or_return

	if resp.response != 0 {
		log.infof("listshortcuts error response code: %d", resp.response)
	}
	return _flatten_shortcuts(resp.results.shortcuts, allocator), nil
}

@(private = "file")
_flatten_shortcuts :: proc(
	wire: []GlobalShortcut_Out,
	allocator: runtime.Allocator,
) -> []GlobalShortcut {
	if len(wire) == 0 do return nil
	flat := make([]GlobalShortcut, len(wire), allocator)
	for w, i in wire {
		flat[i] = {
			id                  = w.id,
			description         = w.metadata.description,
			trigger_description = w.metadata.trigger_description,
		}
	}
	delete(wire, allocator)
	return flat
}

GlobalShortcuts_SliceDelete :: proc(shortcuts: []GlobalShortcut, allocator := context.allocator) {
	for shortcut in shortcuts {
		delete(shortcut.id, allocator)
		delete(shortcut.trigger_description, allocator)
		delete(shortcut.description, allocator)
	}
	delete(shortcuts, allocator)
}

_is_sandboxed :: proc() -> bool {
	return os.exists("/.flatpak-info")
}

@(private = "file")
Portal_Request :: struct {
	response_msg: ^dbus.Message,
	completed:    bool,
	match_rule:   cstring,
	odin_ctx:     runtime.Context,
}

@(private = "file")
portal_response_filter :: proc "c" (
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	req := cast(^Portal_Request)user_data
	context = req.odin_ctx

	if dbus.message_is_signal(msg, "org.freedesktop.portal.Request", "Response") {
		req.response_msg = dbus.message_ref(msg)
		req.completed = true
		return .HANDLED
	}
	return .NOT_YET_HANDLED
}

@(private = "file")
portal_subscribe :: proc(
	req: ^Portal_Request,
	conn: ^dbus.Connection,
	handle_token: string,
	temp_allocator := context.temp_allocator,
) -> Error {
	err: dbus.Error
	dbus.error_init(&err)

	request_path := fmt.aprintf(
		"/org/freedesktop/portal/desktop/request/%s/%s",
		string(dbus.bus_get_unique_name(conn))[1:],
		handle_token,
		allocator = temp_allocator,
	)
	string_subst_bytes(request_path, '.', '_')

	req.match_rule = fmt.caprintf(
		"type='signal',interface='org.freedesktop.portal.Request',member='Response',path='%s'",
		request_path,
		allocator = temp_allocator,
	)
	req.odin_ctx = context

	dbus.bus_add_match(conn, req.match_rule, &err)
	if dbus.error_is_set(&err) do return err.message
	dbus.connection_add_filter(conn, portal_response_filter, req, nil)
	return nil
}

@(private = "file")
portal_unsubscribe :: proc(req: ^Portal_Request, conn: ^dbus.Connection) {
	dbus.connection_remove_filter(conn, portal_response_filter, req)
	dbus.bus_remove_match(conn, req.match_rule, nil)
	if req.response_msg != nil {
		dbus.message_unref(req.response_msg)
		req.response_msg = nil
	}
}

@(private = "file")
portal_wait :: proc(
	req: ^Portal_Request,
	conn: ^dbus.Connection,
	timeout: time.Duration = 0,
) -> bool {
	start := time.now()
	for !req.completed {
		if !dbus.connection_read_write_dispatch(conn, 100) {
			log.errorf("dbus dispatch failure")
			return false
		}
		if timeout > 0 && time.since(start) > timeout {
			log.errorf("timed out waiting for response signal")
			return false
		}
	}
	return true
}

@(private = "file")
portal_call :: proc(
	conn: ^dbus.Connection,
	iface, method: cstring,
	req_data: any,
	handle_token: string,
	resp_out: ^$T,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> Error {
	err: dbus.Error
	dbus.error_init(&err)

	portal_req: Portal_Request
	portal_subscribe(&portal_req, conn, handle_token, temp_allocator) or_return
	defer portal_unsubscribe(&portal_req, conn)

	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		iface,
		method,
	)
	defer dbus.message_unref(msg)

	dbus.marshal(msg, req_data, temp_allocator)
	reply := dbus.connection_send_with_reply_and_block(conn, msg, dbus.TIMEOUT_USE_DEFAULT, &err)
	if dbus.error_is_set(&err) do return err.message
	defer dbus.message_unref(reply)

	if !portal_wait(&portal_req, conn) do return "timed out waiting for portal response"

	dbus.unmarshal(portal_req.response_msg, resp_out, allocator)
	return nil
}
