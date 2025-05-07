package mixologist

import "../dbus"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os/os2"
import "core:strings"
import "core:time"

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

GlobalShortcuts_ResponseContext :: struct {
	// possible values
	shortcuts:     []GlobalShortcut,
	// status fields
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

	appid_cstr := strings.clone_to_cstring(appid, context.temp_allocator)
	args, dict: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)
	dbus.message_iter_append_basic(&args, .STRING, &appid_cstr)
	if dbus.message_iter_push_container(&args, .ARRAY, "{sv}", &dict) {}

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
	if dbus.message_iter_push_container(&args, .ARRAY, "{sv}", &dict) {
		_dict_append_entry(
			&dict,
			"handle_token",
			GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
			temp_allocator,
		)
		_dict_append_entry(
			&dict,
			"session_handle_token",
			GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
			temp_allocator,
		)
	}

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
			dbus.message_iter_get_basic(&signal_args, &response_code)

			dbus.message_iter_next(&signal_args)
			dbus.message_iter_recurse(&signal_args, &results)

			handle_iter := Dict_GetKey(&results, "session_handle")
			dbus.message_iter_get_basic(&handle_iter, &session_handle)
			gs.session_handle = strings.clone_from_cstring(session_handle, allocator)
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
	_GlobalShortcuts_dbus_Subscribe(
		&response_context,
		gs.conn,
		handle_token,
		GlobalShortcuts_ShortcutResponseHandler,
		allocator,
		temp_allocator,
	)
	defer _GlobalShortcuts_dbus_Unsubscribe(
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

	args: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)

	session_handle_cstr := strings.clone_to_cstring(gs.session_handle, temp_allocator)
	dbus.message_iter_append_basic(&args, .OBJECT_PATH, &session_handle_cstr)

	shortcuts_array: dbus.MessageIter
	if dbus.message_iter_push_container(&args, .ARRAY, "(sa{sv})", &shortcuts_array) {
		for shortcut in shortcuts {
			shortcut_iter: dbus.MessageIter
			if dbus.message_iter_push_container(&shortcuts_array, .STRUCT, nil, &shortcut_iter) {
				shortcut_id_cstr := strings.clone_to_cstring(shortcut.id, temp_allocator)
				dbus.message_iter_append_basic(&shortcut_iter, .STRING, &shortcut_id_cstr)

				metadata: dbus.MessageIter
				if dbus.message_iter_push_container(&shortcut_iter, .ARRAY, "{sv}", &metadata) {
					_dict_append_entry(&metadata, "description", shortcut.description)
					_dict_append_entry(
						&metadata,
						"preferred_trigger",
						shortcut.trigger_description,
					)
				}
			}
		}
	}

	parent_window := cstring("")
	dbus.message_iter_append_basic(&args, .STRING, &parent_window)

	options: dbus.MessageIter
	if dbus.message_iter_push_container(&args, .ARRAY, "{sv}", &options) {
		_dict_append_entry(&options, "handle_token", handle_token, temp_allocator)
	}

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
	_GlobalShortcuts_dbus_Subscribe(
		&response_context,
		gs.conn,
		handle_token,
		GlobalShortcuts_ShortcutResponseHandler,
		allocator,
		temp_allocator,
	)
	defer _GlobalShortcuts_dbus_Unsubscribe(
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

	args, dict: dbus.MessageIter
	dbus.message_iter_init_append(msg, &args)

	session_handle_cstr := strings.clone_to_cstring(gs.session_handle, temp_allocator)
	dbus.message_iter_append_basic(&args, .OBJECT_PATH, &session_handle_cstr)

	if dbus.message_iter_push_container(&args, .ARRAY, "{sv}", &dict) {
		_dict_append_entry(&dict, "handle_token", handle_token)
	}

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

_GlobalShortcuts_DeserializeShortcuts :: proc(
	iter: ^dbus.MessageIter,
	allocator := context.allocator,
) -> []GlobalShortcut {
	shortcuts_len := dbus.message_iter_get_element_count(iter)
	shortcuts := make([]GlobalShortcut, shortcuts_len, allocator)

	shortcuts_array: dbus.MessageIter
	dbus.message_iter_recurse(iter, &shortcuts_array)

	for &elem in shortcuts {
		shortcut_struct: dbus.MessageIter
		dbus.message_iter_recurse(&shortcuts_array, &shortcut_struct)

		shortcut_id: cstring
		dbus.message_iter_get_basic(&shortcut_struct, &shortcut_id)
		elem.id = strings.clone_from_cstring(shortcut_id, allocator)

		dbus.message_iter_next(&shortcut_struct)
		metadata_dict: dbus.MessageIter
		dbus.message_iter_recurse(&shortcut_struct, &metadata_dict)

		description_iter := Dict_GetKey(&metadata_dict, "description")
		trigger_description_iter := Dict_GetKey(&metadata_dict, "trigger_description")

		description_cstr, trigger_description_cstr: cstring
		dbus.message_iter_get_basic(&description_iter, &description_cstr)
		dbus.message_iter_get_basic(&trigger_description_iter, &trigger_description_cstr)

		elem.description = strings.clone_from_cstring(description_cstr, allocator)
		elem.trigger_description = strings.clone_from_cstring(trigger_description_cstr, allocator)

		dbus.message_iter_next(&shortcuts_array)
	}
	return shortcuts
}

_is_sandboxed :: proc() -> bool {
	return os2.exists("/.flatpak-info")
}

Dict_GetKey :: proc(dict_iter: ^dbus.MessageIter, get: cstring) -> dbus.MessageIter {
	for dbus.message_iter_get_arg_type(dict_iter) == .DICT_ENTRY {
		key_iter, val_iter: dbus.MessageIter
		key: cstring

		dbus.message_iter_recurse(dict_iter, &key_iter)
		dbus.message_iter_get_basic(&key_iter, &key)
		dbus.message_iter_next(&key_iter)
		dbus.message_iter_recurse(&key_iter, &val_iter)

		if key == get {
			return val_iter
		}

		dbus.message_iter_next(dict_iter)
	}

	log.panicf("could not get key: %v", get)
}

_dict_append_entry :: proc(
	dict: ^dbus.MessageIter,
	k, v: string,
	temp_allocator := context.temp_allocator,
) {
	entry, variant: dbus.MessageIter
	key_cstr := strings.clone_to_cstring(k, temp_allocator)
	val_cstr := strings.clone_to_cstring(v, temp_allocator)

	if dbus.message_iter_push_container(dict, .DICT_ENTRY, nil, &entry) {
		dbus.message_iter_append_basic(&entry, .STRING, &key_cstr)
		if dbus.message_iter_push_container(&entry, .VARIANT, "s", &variant) {
			dbus.message_iter_append_basic(&variant, .STRING, &val_cstr)
		}
	}
}

GlobalShortcuts_ShortcutResponseHandler :: proc "c" (
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = GlobalShortcuts_odin_ctx
	response_context := cast(^GlobalShortcuts_ResponseContext)user_data

	if dbus.message_is_signal(msg, "org.freedesktop.portal.Request", "Response") {
		signal_args, results: dbus.MessageIter
		dbus.message_iter_init(msg, &signal_args)
		dbus.message_iter_get_basic(&signal_args, &response_context.response_code)

		dbus.message_iter_next(&signal_args)
		dbus.message_iter_recurse(&signal_args, &results)

		shortcuts_iter := Dict_GetKey(&results, "shortcuts")
		if dbus.message_iter_get_arg_type(&shortcuts_iter) == .ARRAY {
			response_context.shortcuts = _GlobalShortcuts_DeserializeShortcuts(
				&shortcuts_iter,
				response_context.allocator,
			)
		} else {
			log.errorf(
				"expected ARRAY for 'shortcuts', got %v",
				dbus.message_iter_get_arg_type(&shortcuts_iter),
			)
		}

		response_context.completed = true
		return .HANDLED
	}

	return .NOT_YET_HANDLED
}

_GlobalShortcuts_dbus_Subscribe :: proc(
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

_GlobalShortcuts_dbus_Unsubscribe :: proc(
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

	return true
}
