package mixologist

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"
import "dbus"

GlobalShortcuts_odin_ctx: runtime.Context

GlobalShortcuts_Session :: struct {
	conn:           ^dbus.Connection,
	session_handle: string,
	base:           string,
}

GlobalShortcut :: struct {
	id:                  string,
	description:         string,
	trigger_description: string,
}

@(private = "file")
GlobalShortcut_OutMetadata :: struct {
	description:         string `dbus:"s" dbus_name:"description"`,
	trigger_description: string `dbus:"s" dbus_name:"trigger_description"`,
}
@(private = "file")
GlobalShortcut_Out :: struct {
	id:       string `dbus:"s"`,
	metadata: GlobalShortcut_OutMetadata `dbus:"a{sv}"`,
}

@(private = "file")
GlobalShortcut_InMetadata :: struct {
	description:       string `dbus:"s" dbus_name:"description"`,
	preferred_trigger: string `dbus:"s" dbus_name:"preferred_trigger"`,
}
@(private = "file")
GlobalShortcut_In :: struct {
	id:       string `dbus:"s"`,
	metadata: GlobalShortcut_InMetadata `dbus:"a{sv}"`,
}

GlobalShortcuts_ResponseContext :: struct {
	shortcuts:     []GlobalShortcut,
	completed:     bool,
	response_code: u32,
	match_rule:    cstring,
	allocator:     runtime.Allocator,
}

GlobalShortcuts_SignalType :: enum {
	ACTIVATED,
	DEACTIVATED,
	SHORTCUTS_CHANGED,
}
GlobalShortcuts_SignalTypes :: bit_set[GlobalShortcuts_SignalType]

GlobalShortcuts_CreateSessionReq :: struct {
	handle_token:         string `dbus:"s" dbus_name:"handle_token"`,
	session_handle_token: string `dbus:"s" dbus_name:"session_handle_token"`,
}
GlobalShortcuts_CreateSessionResults :: struct {
	session_handle: string `dbus:"o" dbus_name:"session_handle"`,
}
GlobalShortcuts_CreateSessionResp :: struct {
	response: u32 `dbus:"u"`,
	results:  GlobalShortcuts_CreateSessionResults `dbus:"a{sv}"`,
}

GlobalShortcuts_HandleTokenOptions :: struct {
	handle_token: string `dbus:"s" dbus_name:"handle_token"`,
}

GlobalShortcuts_BindShortcutsReq :: struct {
	session_handle: string `dbus:"o"`,
	shortcuts:      []GlobalShortcut_In `dbus:"a(sa{sv})"`,
	parent_window:  string `dbus:"s"`,
	options:        GlobalShortcuts_HandleTokenOptions `dbus:"a{sv}"`,
}

GlobalShortcuts_ListShortcutsReq :: struct {
	session_handle: string `dbus:"o"`,
	options:        GlobalShortcuts_HandleTokenOptions `dbus:"a{sv}"`,
}

GlobalShortcuts_ShortcutsResults :: struct {
	shortcuts: []GlobalShortcut_Out `dbus:"a(sa{sv})" dbus_name:"shortcuts"`,
}
GlobalShortcuts_ShortcutsResp :: struct {
	response: u32 `dbus:"u"`,
	results:  GlobalShortcuts_ShortcutsResults `dbus:"a{sv}"`,
}

Registry_RegisterReq :: struct {
	appid:   string `dbus:"s"`,
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

	args: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)
	dbus.marshal(&args, "sa{sv}", Registry_RegisterReq{appid = appid}, context.temp_allocator)

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
	GlobalShortcuts_odin_ctx = context
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
	delete(gs.session_handle, allocator)
}

GlobalShortcuts_CreateSession :: proc(
	gs: ^GlobalShortcuts_Session,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> Error {
	err: dbus.Error
	dbus.error_init(&err)
	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.GlobalShortcuts",
		"CreateSession",
	)
	defer dbus.message_unref(msg)

	args, dict: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)
	dbus.marshal(
		&args,
		"a{sv}",
		GlobalShortcuts_CreateSessionReq {
			GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
			GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
		},
		temp_allocator,
	)

	reply := dbus.connection_send_with_reply_and_block(
		gs.conn,
		msg,
		dbus.TIMEOUT_USE_DEFAULT,
		&err,
	)
	if dbus.error_is_set(&err) do return err.message
	defer dbus.message_unref(reply)

	reply_args: dbus.MessageIter
	received_path: cstring
	dbus.message_iter_init(reply, &reply_args)
	dbus.message_iter_get_basic(&reply_args, &received_path)
	log.infof("received request path: %s", received_path)

	for dbus.connection_read_write_dispatch(gs.conn, 100) {
		signal_msg := dbus.connection_pop_message(gs.conn)
		if signal_msg == nil do continue
		defer dbus.message_unref(signal_msg)

		if dbus.message_is_signal(signal_msg, "org.freedesktop.portal.Request", "Response") {
			signal_path := dbus.message_get_path(signal_msg)
			if signal_path != received_path do continue

			signal_args, results: dbus.MessageIter
			response_code: u32
			session_handle: cstring

			dbus.message_iter_init(signal_msg, &signal_args)
			createsession_resp: GlobalShortcuts_CreateSessionResp
			if err := dbus.unmarshal(
				&signal_args,
				"ua{sv}",
				&createsession_resp,
				context.allocator,
			); err != nil {
				log.error("could not get session handle")
			}
			gs.session_handle = createsession_resp.results.session_handle
			log.debugf("obtained session handle: %s", gs.session_handle)
			return nil
		}
	}

	return "Timed out waiting for Response signal"
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
		strings.clone_to_cstring(gs.session_handle, allocator),
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
	[]GlobalShortcut,
	Error,
) {
	if len(gs.session_handle) == 0 do return nil, "No session handle available"

	err: dbus.Error
	dbus.error_init(&err)

	handle_token := GlobalShortcuts_Token_Generate(gs.base, temp_allocator)
	response_context: GlobalShortcuts_ResponseContext
	GlobalShortcuts_dbus_Subscribe(
		&response_context,
		gs.conn,
		handle_token,
		GlobalShortcuts_ShortcutResponseHandler,
		allocator,
		temp_allocator,
	)
	defer GlobalShortcuts_dbus_Unsubscribe(
		&response_context,
		gs.conn,
		GlobalShortcuts_ShortcutResponseHandler,
	)

	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.GlobalShortcuts",
		"BindShortcuts",
	)
	defer dbus.message_unref(msg)

	wire_shortcuts := make([]GlobalShortcut_In, len(shortcuts), temp_allocator)
	for s, i in shortcuts {
		wire_shortcuts[i] = {
			id = s.id,
			metadata = {description = s.description, preferred_trigger = s.trigger_description},
		}
	}

	args: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)
	dbus.marshal(
		&args,
		"oa(sa{sv})sa{sv}",
		GlobalShortcuts_BindShortcutsReq {
			session_handle = gs.session_handle,
			shortcuts = wire_shortcuts,
			parent_window = "",
			options = {handle_token = handle_token},
		},
		temp_allocator,
	)

	reply := dbus.connection_send_with_reply_and_block(
		gs.conn,
		msg,
		dbus.TIMEOUT_USE_DEFAULT,
		&err,
	)
	if dbus.error_is_set(&err) do return nil, err.message
	defer dbus.message_unref(reply)
	log.infof("sent global shortcut bind request")

	reply_args: dbus.MessageIter
	received_path: cstring
	if !dbus.message_iter_init(reply, &reply_args) {
		return nil, "Failed to parse BindShortcuts reply"
	}
	dbus.message_iter_get_basic(&reply_args, &received_path)
	log.infof("received request path: %s", received_path)

	_GlobalShortcuts_dbus_wait_for_response(&response_context, gs.conn)

	if response_context.response_code != 0 {
		log.infof("bindshortcuts error response code: %d", response_context.response_code)
	}

	if len(response_context.shortcuts) == 0 {
		log.info("no shortcuts returned")
		return nil, nil
	}

	res_shortcuts := response_context.shortcuts
	response_context.shortcuts = nil
	return res_shortcuts, nil
}

GlobalShortcuts_ListShortcuts :: proc(
	gs: ^GlobalShortcuts_Session,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	shortcuts: []GlobalShortcut,
	error: Error,
) {
	if len(gs.session_handle) == 0 do return nil, "No session handle available"

	err: dbus.Error
	dbus.error_init(&err)

	handle_token := GlobalShortcuts_Token_Generate(gs.base, temp_allocator)
	response_context: GlobalShortcuts_ResponseContext
	GlobalShortcuts_dbus_Subscribe(
		&response_context,
		gs.conn,
		handle_token,
		GlobalShortcuts_ShortcutResponseHandler,
		allocator,
		temp_allocator,
	)
	defer GlobalShortcuts_dbus_Unsubscribe(
		&response_context,
		gs.conn,
		GlobalShortcuts_ShortcutResponseHandler,
	)

	msg := dbus.message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.GlobalShortcuts",
		"ListShortcuts",
	)
	defer dbus.message_unref(msg)

	args: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)
	dbus.marshal(
		&args,
		"oa{sv}",
		GlobalShortcuts_ListShortcutsReq {
			session_handle = gs.session_handle,
			options = {handle_token = handle_token},
		},
		temp_allocator,
	)

	reply := dbus.connection_send_with_reply_and_block(
		gs.conn,
		msg,
		dbus.TIMEOUT_USE_DEFAULT,
		&err,
	)
	if dbus.error_is_set(&err) do return
	defer dbus.message_unref(reply)

	reply_args: dbus.MessageIter
	received_path: cstring
	if !dbus.message_iter_init(reply, &reply_args) {
		return nil, "Failed to parse ListShortcuts reply"
	}
	dbus.message_iter_get_basic(&reply_args, &received_path)
	log.infof("received request path: %s", received_path)

	_GlobalShortcuts_dbus_wait_for_response(&response_context, gs.conn)
	if response_context.response_code != 0 {
		log.infof("listshortcuts error response code: %d", response_context.response_code)
	}

	if len(response_context.shortcuts) == 0 {
		log.info("no shortcuts returned")
		return nil, nil
	}

	shortcuts = response_context.shortcuts
	response_context.shortcuts = nil
	return
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

GlobalShortcuts_ShortcutResponseHandler :: proc "c" (
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = GlobalShortcuts_odin_ctx
	response_context := cast(^GlobalShortcuts_ResponseContext)user_data

	if dbus.message_is_signal(msg, "org.freedesktop.portal.Request", "Response") {
		signal_args: dbus.MessageIter
		dbus.message_iter_init(msg, &signal_args)
		resp: GlobalShortcuts_ShortcutsResp
		if err := dbus.unmarshal(&signal_args, "ua{sv}", &resp, response_context.allocator);
		   err != nil {
			response_context.completed = true
			return .NOT_YET_HANDLED
		}
		response_context.response_code = resp.response

		// Move wire entries into the flat public shape. String headers are
		// shared, so freeing the wire's outer slice header is enough — the
		// underlying string bytes live on through the flat slice.
		flat := make([]GlobalShortcut, len(resp.results.shortcuts), response_context.allocator)
		for w, i in resp.results.shortcuts {
			flat[i] = {
				id                  = w.id,
				description         = w.metadata.description,
				trigger_description = w.metadata.trigger_description,
			}
		}
		delete(resp.results.shortcuts, response_context.allocator)
		response_context.shortcuts = flat
		response_context.completed = true
		return .HANDLED
	}

	response_context.completed = true
	return .NOT_YET_HANDLED
}

GlobalShortcuts_dbus_Subscribe :: proc(
	ctx: ^GlobalShortcuts_ResponseContext,
	conn: ^dbus.Connection,
	handle_token: string,
	handler: dbus.HandleMessageProc,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) {
	err: dbus.Error
	dbus.error_init(&err)

	request_path := fmt.aprintf(
		"/org/freedesktop/portal/desktop/request/%s/%s",
		string(dbus.bus_get_unique_name(conn))[1:],
		handle_token,
		allocator = temp_allocator,
	)
	string_subst_bytes(request_path, '.', '_')
	ctx.allocator = allocator

	ctx.match_rule = fmt.caprintf(
		"type='signal',interface='org.freedesktop.portal.Request',member='Response',path='%s'",
		request_path,
		allocator = temp_allocator,
	)
	dbus.bus_add_match(conn, ctx.match_rule, &err)
	if dbus.error_is_set(&err) {
		log.panicf("could not add match rule %s", err.message)
	}

	dbus.connection_add_filter(conn, handler, ctx, nil)
}

GlobalShortcuts_dbus_Unsubscribe :: proc(
	ctx: ^GlobalShortcuts_ResponseContext,
	conn: ^dbus.Connection,
	handler: dbus.HandleMessageProc,
) {
	dbus.connection_remove_filter(conn, handler, ctx)
	dbus.bus_remove_match(conn, ctx.match_rule, nil)
	if ctx.shortcuts != nil {
		GlobalShortcuts_SliceDelete(ctx.shortcuts, ctx.allocator)
	}
}

_GlobalShortcuts_dbus_wait_for_response :: proc(
	ctx: ^GlobalShortcuts_ResponseContext,
	conn: ^dbus.Connection,
	timeout: time.Duration = 0,
) -> bool {
	start_time := time.now()
	for !ctx.completed {
		if !dbus.connection_read_write_dispatch(conn, 100) {
			log.errorf("dbus dispatch failure")
			return false
		}

		if timeout > 0 && time.since(start_time) > timeout {
			log.errorf("timed out waiting for response signal")
			return false
		}
	}

	log.debugf("dbus response received")
	return true
}
