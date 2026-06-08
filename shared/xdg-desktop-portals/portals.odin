package xdg_desktop_portals

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem/virtual"
import "core:time"
import "shared:dbus"

Context :: struct {
	conn:             ^dbus.Connection,
	token_base:       string,
	parent:           string,
	app_id:           string,
	global_shortcuts: GlobalShortcutsContext,
	events:           queue.Queue(Event),
	event_mem:        virtual.Arena,
	odin_ctx:         runtime.Context,
}

init :: proc(ctx: ^Context, parent_window, app_id, token_base: string) {
	_ = virtual.arena_init_growing(&ctx.event_mem)
	ctx.odin_ctx = context
	ctx.parent = parent_window
	ctx.app_id = app_id
	ctx.token_base = token_base

	err: dbus.Error
	dbus.error_init(&err)
	defer if dbus.error_is_set(&err) {dbus.error_free(&err)}
	ctx.conn = dbus.bus_get_private(.SESSION, &err)

	if !is_flatpak() {
		registry_register(ctx, app_id)
	}
}

deinit :: proc(ctx: ^Context) {
	dbus.connection_close(ctx.conn)
	queue.destroy(&ctx.events)
}

generate_token :: proc(base: string, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%s_%v", base, rand.int31(), allocator = allocator)
}

Event :: struct {
	kind:            enum {
		GlobalShortcutActivated,
		GlobalShortcutDeactivated,
		GlobalShortcutChanged,
	},
	global_shortcut: struct {
		id:                  string,
		timestamp:           u64,
		description:         string,
		trigger_description: string,
	},
}

event_poll :: proc(ctx: ^Context) {
	virtual.arena_free_all(&ctx.event_mem)
	dbus.connection_read_write(ctx.conn, 0)
	for dbus.connection_dispatch(ctx.conn) == .DATA_REMAINS {}
}

event_iter :: proc(ctx: ^Context) -> (Event, bool) {
	return queue.pop_front_safe(&ctx.events)
}

Error :: enum {
	None,
	MatchAdd,
	MethodCall,
	PortalResp,
	MissingSessionHandle,
}

Request :: struct {
	response_msg: ^dbus.Message,
	completed:    bool,
	match_rule:   cstring,
	odin_ctx:     runtime.Context,
}

DBUS_DEST :: "org.freedesktop.portal.Desktop"
DBUS_PATH :: "/org/freedesktop/portal/desktop"

portal_call_blocking :: proc(
	$RT: typeid,
	conn: ^dbus.Connection,
	iface, method: cstring,
	req_data: any,
	handle_token: string,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	resp: RT,
	err: Error,
) {
	portal_req: Request
	portal_subscribe(&portal_req, conn, handle_token, temp_allocator) or_return
	defer portal_unsubscribe(&portal_req, conn)

	dbus.method_call_void(conn, DBUS_DEST, DBUS_PATH, iface, method, req_data)
	if !portal_wait(&portal_req, conn) do return {}, .PortalResp

	dbus.unmarshal(portal_req.response_msg, &resp, allocator)
	return resp, nil
}

portal_response_filter :: proc "c" (
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	req := cast(^Request)user_data
	context = req.odin_ctx

	if dbus.message_is_signal(msg, "org.freedesktop.portal.Request", "Response") {
		req.response_msg = dbus.message_ref(msg)
		req.completed = true
		return .HANDLED
	}
	return .NOT_YET_HANDLED
}

portal_subscribe :: proc(
	req: ^Request,
	conn: ^dbus.Connection,
	handle_token: string,
	temp_allocator: runtime.Allocator,
) -> Error {
	request_path := fmt.aprintf(
		"/org/freedesktop/portal/desktop/request/%s/%s",
		string(dbus.bus_get_unique_name(conn))[1:],
		handle_token,
		allocator = temp_allocator,
	)
	_string_subst_bytes(request_path, '.', '_')

	req.match_rule = fmt.caprintf(
		"type='signal',interface='org.freedesktop.portal.Request',member='Response',path='%s'",
		request_path,
		allocator = temp_allocator,
	)
	req.odin_ctx = context

	err: dbus.Error
	dbus.error_init(&err)
	defer if dbus.error_is_set(&err) {dbus.error_free(&err)}
	dbus.bus_add_match(conn, req.match_rule, &err)
	if dbus.error_is_set(&err) do return .MatchAdd
	dbus.connection_add_filter(conn, portal_response_filter, req, nil)
	return nil
}

portal_unsubscribe :: proc(req: ^Request, conn: ^dbus.Connection) {
	dbus.connection_remove_filter(conn, portal_response_filter, req)
	dbus.bus_remove_match(conn, req.match_rule, nil)
	if req.response_msg != nil {
		dbus.message_unref(req.response_msg)
		req.response_msg = nil
	}
}

portal_wait :: proc(req: ^Request, conn: ^dbus.Connection, timeout: time.Duration = 0) -> bool {
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
