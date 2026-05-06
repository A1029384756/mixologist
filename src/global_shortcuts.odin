package mixologist

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:time"
import "dbus"

GlobalShortcuts :: struct {
	subscription:   Subscriber,
	conn:           ^dbus.Connection,
	session_handle: dbus.ObjectPath,
	base:           string,
	odin_ctx:       runtime.Context,
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

Shortcut :: enum {
	Raise,
	Lower,
	Reset,
	Max,
	Min,
}

Shortcut_Info := [Shortcut]GlobalShortcut {
	.Raise = {id = "raise", description = "favor selected", trigger_description = "SHIFT+F12"},
	.Lower = {id = "lower", description = "favor system", trigger_description = "SHIFT+F11"},
	.Reset = {id = "reset", description = "reset", trigger_description = "SHIFT+F10"},
	.Max = {id = "max", description = "isolate selected", trigger_description = "ALT+SHIFT+F12"},
	.Min = {id = "min", description = "isolate system", trigger_description = "ALT+SHIFT+F11"},
}

shortcut_from_str :: proc(input: string) -> Shortcut {
	switch input {
	case "raise":
		return .Raise
	case "lower":
		return .Lower
	case "reset":
		return .Reset
	case "max":
		return .Max
	case "min":
		return .Min
	case:
		log.panic("invalid shortcut id")
	}
}

global_shortcuts_tick :: proc(conn: ^dbus.Connection) -> bool {
	return bool(dbus.connection_read_write_dispatch(conn, 5))
}

global_shortcuts_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = ctx.odin_ctx
	interface := cstring("org.freedesktop.portal.GlobalShortcuts")
	activated: if dbus.message_is_signal(msg, interface, "Activated") {
		activation: struct {
			session_handle: dbus.ObjectPath,
			shortcut_id:    string,
			timestamp:      u64,
		}
		unmarshal_err := dbus.unmarshal(msg, &activation, context.allocator)
		if unmarshal_err != nil do break activated
		defer {
			delete(string(activation.session_handle))
			delete(activation.shortcut_id)
		}
		shortcut_id := shortcut_from_str(activation.shortcut_id)
		volume: Volume
		switch shortcut_id {
		case .Raise:
			volume.kind = .Add
			volume.data = 0.1
		case .Lower:
			volume.kind = .Add
			volume.data = -0.1
		case .Max:
			volume.kind = .Set
			volume.data = 1
		case .Min:
			volume.kind = .Set
			volume.data = -1
		case .Reset:
			volume.kind = .Set
			volume.data = 0
		}
		bus_publish(&bus, {sender = .GlobalShortcuts, topic = .Volume, volume = volume})
		return .HANDLED
	}
	return .NOT_YET_HANDLED
}

registry_register :: proc(conn: ^dbus.Connection, appid: string) -> Error {
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

global_shortcuts_generate_token :: proc(base: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s_%v", base, rand.int31(), allocator = allocator)
}

@(private = "file")
ctx: GlobalShortcuts

global_shortcuts_init :: proc() -> bool {
	subscriber_init(&ctx.subscription, .GlobalShortcuts, {.Quit})
	ctx.odin_ctx = context
	bus_subscribe(&bus, ctx.subscription)
	gs_err := _global_shortcuts_init(
		&ctx,
		"dev.cstring.mixologist",
		"mixologist",
		{.ACTIVATED},
		global_shortcuts_handler,
		nil,
		nil,
	)
	if gs_err != nil do return false

	global_shortcuts_create_session(&ctx)
	listed_shortcuts, _ := global_shortcuts_list_shortcuts(&ctx)
	all_shortcuts_bound := true
	for shortcut in Shortcut_Info {
		found := false
		for listed_shortcut in listed_shortcuts {
			if listed_shortcut.id == shortcut.id do found = true
		}
		if !found {
			log.infof("could not find shortcut: %v", shortcut)
			all_shortcuts_bound = false
			break
		}
	}
	global_shortcuts_slice_delete(listed_shortcuts)
	if !all_shortcuts_bound {
		shortcuts: [len(Shortcut_Info)]GlobalShortcut
		for shortcut, idx in Shortcut_Info {
			shortcuts[idx] = shortcut
		}
		bound_shortcuts, _ := global_shortcuts_bind_shortcuts(&ctx, shortcuts[:])
		global_shortcuts_slice_delete(bound_shortcuts)
	}
	return true
}

global_shortcuts_proc :: proc() {
	when PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(os.get_current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
	}

	should_exit := false
	for !should_exit {
		for msg in subscriber_try_poll(&ctx.subscription) {
			#partial switch msg.topic {
			case .Quit:
				should_exit = true
			case:
				log.errorf("unexpected \"%v\" message", msg.topic)
			}
			message_unref(msg)
		}
		global_shortcuts_tick(ctx.conn)
	}
}

global_shortcuts_deinit :: proc() {
	_global_shortcuts_deinit(&ctx)
	subscriber_flush(&ctx.subscription)
	subscriber_destroy(&ctx.subscription)
}

_global_shortcuts_init :: proc(
	gs: ^GlobalShortcuts,
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
		registry_register(gs.conn, appid) or_return
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

_global_shortcuts_deinit :: proc(gs: ^GlobalShortcuts, allocator := context.allocator) {
	dbus.connection_unref(gs.conn)
	delete(string(gs.session_handle), allocator)
}

global_shortcuts_create_session :: proc(
	gs: ^GlobalShortcuts,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> Error {
	handle_token := global_shortcuts_generate_token(gs.base, temp_allocator)

	resp: GlobalShortcuts_CreateSessionResp
	portal_call(
		gs.conn,
		"org.freedesktop.portal.GlobalShortcuts",
		"CreateSession",
		GlobalShortcuts_CreateSessionReq {
			options = {
				handle_token = handle_token,
				session_handle_token = global_shortcuts_generate_token(gs.base, temp_allocator),
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

global_shortcuts_close_session :: proc(
	gs: ^GlobalShortcuts,
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

global_shortcuts_bind_shortcuts :: proc(
	gs: ^GlobalShortcuts,
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

	handle_token := global_shortcuts_generate_token(gs.base, temp_allocator)
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

global_shortcuts_list_shortcuts :: proc(
	gs: ^GlobalShortcuts,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	out: []GlobalShortcut,
	err: Error,
) {
	if len(gs.session_handle) == 0 do return nil, "No session handle available"

	handle_token := global_shortcuts_generate_token(gs.base, temp_allocator)
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

global_shortcuts_slice_delete :: proc(
	shortcuts: []GlobalShortcut,
	allocator := context.allocator,
) {
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
