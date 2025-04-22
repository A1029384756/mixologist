package mixologist

import "../dbus"
import "core:fmt"
import "core:math/rand"
import "core:os/os2"
import "core:strings"

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
	request_path: cstring
	dbus.message_iter_init(reply, &reply_args)
	dbus.message_iter_get_basic(&reply_args, &request_path)

	for dbus.connection_read_write_dispatch(gs.conn, 100) {
		signal_msg := dbus.connection_pop_message(gs.conn)
		if signal_msg == nil do continue
		defer dbus.message_unref(signal_msg)

		if dbus.message_is_signal(signal_msg, "org.freedesktop.portal.Request", "Response") {
			signal_path := dbus.message_get_path(signal_msg)
			if signal_path != request_path do continue

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
		_dict_append_entry(
			&options,
			"handle_token",
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
	if dbus.error_is_set(&err) do return nil, err.message
	defer dbus.message_unref(reply)

	reply_args: dbus.MessageIter
	request_path: cstring
	if !dbus.message_iter_init(reply, &reply_args) {
		return nil, "Failed to parse BindShortcuts reply"
	}
	dbus.message_iter_get_basic(&reply_args, &request_path)

	for dbus.connection_read_write_dispatch(gs.conn, 100) {
		signal_msg := dbus.connection_pop_message(gs.conn)
		if signal_msg == nil do continue
		defer dbus.message_unref(signal_msg)

		if dbus.message_is_signal(signal_msg, "org.freedesktop.portal.Request", "Response") {
			signal_path := dbus.message_get_path(signal_msg)
			if signal_path != request_path do continue

			signal_args, results: dbus.MessageIter
			response_code: u32

			dbus.message_iter_init(signal_msg, &signal_args)
			dbus.message_iter_get_basic(&signal_args, &response_code)

			dbus.message_iter_next(&signal_args)
			dbus.message_iter_recurse(&signal_args, &results)

			shortcuts_iter := Dict_GetKey(&results, "shortcuts")
			return _GlobalShortcuts_DeserializeShortcuts(&shortcuts_iter, allocator), nil
		}
	}
	return nil, "failed to parse BindShortcuts reply"
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
		_dict_append_entry(
			&dict,
			"handle_token",
			GlobalShortcuts_Token_Generate(gs.base, temp_allocator),
		)
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
	request_path: cstring
	if !dbus.message_iter_init(reply, &reply_args) {
		return nil, "Failed to parse ListShortcuts reply"
	}
	dbus.message_iter_get_basic(&reply_args, &request_path)

	for dbus.connection_read_write_dispatch(gs.conn, 100) {
		signal_msg := dbus.connection_pop_message(gs.conn)
		if signal_msg == nil do continue
		defer dbus.message_unref(signal_msg)

		if dbus.message_is_signal(signal_msg, "org.freedesktop.portal.Request", "Response") {
			signal_path := dbus.message_get_path(signal_msg)
			if signal_path != request_path do continue

			signal_args, results: dbus.MessageIter
			response_code: u32

			dbus.message_iter_init(signal_msg, &signal_args)
			dbus.message_iter_get_basic(&signal_args, &response_code)

			dbus.message_iter_next(&signal_args)
			dbus.message_iter_recurse(&signal_args, &results)

			shortcuts_iter := Dict_GetKey(&results, "shortcuts")
			return _GlobalShortcuts_DeserializeShortcuts(&shortcuts_iter, allocator), nil
		}
	}
	return nil, "failed to parse ListShortcuts reply"
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

	fmt.panicf("could not get key: %v", get)
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
