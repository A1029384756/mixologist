package xdg_desktop_portals

import "base:runtime"
import "core:container/queue"
import "core:log"
import "core:mem/virtual"
import "shared:dbus"

GlobalShortcutsContext :: struct {
	session_handle: dbus.ObjectPath,
}

GlobalShortcutsActivation :: struct {
	session_handle: dbus.ObjectPath,
	shortcut_id:    string,
	timestamp:      u64,
}
GlobalShortcutsDeactivation :: distinct GlobalShortcutsActivation
GlobalShortcutsChange :: struct {
	session_handle: dbus.ObjectPath,
	shortcuts:      []GlobalShortcut_Out,
}

GlobalShortcut :: struct {
	id:                  string,
	description:         string,
	trigger_description: string,
}

GlobalShortcut_OutMetadata :: struct {
	description:         string,
	trigger_description: string,
}
GlobalShortcut_Out :: struct {
	id:       string,
	metadata: GlobalShortcut_OutMetadata `dbus:"a{sv}"`,
}

GlobalShortcut_InMetadata :: struct {
	description:       string,
	preferred_trigger: string,
}
GlobalShortcut_In :: struct {
	id:       string,
	metadata: GlobalShortcut_InMetadata `dbus:"a{sv}"`,
}

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

DBUS_GLOBALSHORTCUTS_IFACE :: "org.freedesktop.portal.GlobalShortcuts"

global_shortcuts_init :: proc(ctx: ^Context) -> Error {
	global_shortcuts_create_session(ctx) or_return

	err: dbus.Error
	dbus.error_init(&err)
	defer if dbus.error_is_set(&err) {dbus.error_free(&err)}
	dbus.connection_add_filter(ctx.conn, _global_shortcut_handler, ctx, nil)

	return nil
}

_global_shortcut_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	ctx := cast(^Context)user_data
	context = ctx.odin_ctx
	arena := virtual.arena_allocator(&ctx.event_mem)

	activated: if dbus.message_is_signal(msg, DBUS_GLOBALSHORTCUTS_IFACE, "Activated") {
		activation: GlobalShortcutsActivation
		dbus.unmarshal(msg, &activation, arena) or_break activated
		queue.append(
			&ctx.events,
			Event {
				kind = .GlobalShortcutActivated,
				global_shortcut = {id = activation.shortcut_id, timestamp = activation.timestamp},
			},
		)
		return .HANDLED
	} else if dbus.message_is_signal(msg, DBUS_GLOBALSHORTCUTS_IFACE, "Deactivated") {
		deactivation: GlobalShortcutsDeactivation
		dbus.unmarshal(msg, &deactivation, arena) or_break activated
		queue.append(
			&ctx.events,
			Event {
				kind = .GlobalShortcutDeactivated,
				global_shortcut = {
					id = deactivation.shortcut_id,
					timestamp = deactivation.timestamp,
				},
			},
		)
		return .HANDLED
	} else if dbus.message_is_signal(msg, DBUS_GLOBALSHORTCUTS_IFACE, "ShortcutsChanged") {
		change: GlobalShortcutsChange
		dbus.unmarshal(msg, &change, arena) or_break activated
		for shortcut in change.shortcuts {
			queue.append(
				&ctx.events,
				Event {
					kind = .GlobalShortcutChanged,
					global_shortcut = {
						id = shortcut.id,
						description = shortcut.metadata.description,
						trigger_description = shortcut.metadata.trigger_description,
					},
				},
			)
		}
		return .HANDLED
	}

	return .NOT_YET_HANDLED
}

global_shortcuts_deinit :: proc(ctx: ^Context, temp_allocator := context.temp_allocator) -> Error {
	return global_shortcuts_close_session(ctx, temp_allocator)
}

global_shortcuts_create_session :: proc(
	ctx: ^Context,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> Error {
	handle_token := generate_token(ctx.token_base, temp_allocator)

	resp := portal_call_blocking(
		GlobalShortcuts_CreateSessionResp,
		ctx.conn,
		DBUS_GLOBALSHORTCUTS_IFACE,
		"CreateSession",
		GlobalShortcuts_CreateSessionReq {
			options = {
				handle_token = handle_token,
				session_handle_token = generate_token(ctx.token_base, temp_allocator),
			},
		},
		handle_token,
		allocator,
		temp_allocator,
	) or_return

	if resp.response != 0 {
		log.infof("createsession error response code: %d", resp.response)
		return .PortalResp
	}

	ctx.global_shortcuts.session_handle = resp.results.session_handle
	log.debugf("obtained session handle: %s", ctx.global_shortcuts.session_handle)
	return nil
}

global_shortcuts_close_session :: proc(
	ctx: ^Context,
	temp_allocator := context.temp_allocator,
) -> Error {
	if ctx.global_shortcuts.session_handle == "" {return .MissingSessionHandle}
	return close_session(ctx, ctx.global_shortcuts.session_handle, temp_allocator)
}

global_shortcuts_bind_shortcuts :: proc(
	ctx: ^Context,
	shortcuts: []GlobalShortcut,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	out: []GlobalShortcut,
	err: Error,
) {
	if ctx.global_shortcuts.session_handle == "" {return {}, .MissingSessionHandle}

	wire_shortcuts := make([]GlobalShortcut_In, len(shortcuts), temp_allocator)
	for s, i in shortcuts {
		wire_shortcuts[i] = {
			id = s.id,
			metadata = {description = s.description, preferred_trigger = s.trigger_description},
		}
	}

	handle_token := generate_token(ctx.token_base, temp_allocator)
	resp := portal_call_blocking(
		GlobalShortcuts_ShortcutsResp,
		ctx.conn,
		DBUS_GLOBALSHORTCUTS_IFACE,
		"BindShortcuts",
		GlobalShortcuts_BindShortcutsReq {
			session_handle = ctx.global_shortcuts.session_handle,
			shortcuts = wire_shortcuts,
			parent_window = "",
			options = {handle_token = handle_token},
		},
		handle_token,
		allocator,
		temp_allocator,
	) or_return

	if resp.response != 0 {
		log.infof("bindshortcuts error response code: %d", resp.response)
	}
	return _flatten_shortcuts(resp.results.shortcuts, allocator), nil
}

global_shortcuts_list_shortcuts :: proc(
	ctx: ^Context,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	out: []GlobalShortcut,
	err: Error,
) {
	if ctx.global_shortcuts.session_handle == "" {return {}, .MissingSessionHandle}

	handle_token := generate_token(ctx.token_base, temp_allocator)
	resp := portal_call_blocking(
		GlobalShortcuts_ShortcutsResp,
		ctx.conn,
		DBUS_GLOBALSHORTCUTS_IFACE,
		"ListShortcuts",
		GlobalShortcuts_ListShortcutsReq {
			session_handle = ctx.global_shortcuts.session_handle,
			options = {handle_token = handle_token},
		},
		handle_token,
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
