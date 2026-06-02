package mixologist

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "dbus"

IPCServer :: struct {
	service_name: cstring,
	conn:         ^dbus.Connection,
}

@(private = "file")
ctx: IPCServer

IpcError :: enum {
	None,
	CannotConnect,
	NameTaken,
	SetupErr,
}

IPC_INTERFACE :: "dev.cstring.mixologist"
IPC_OBJECT_PATH :: "/dev/cstring/mixologist"
IPC_SIGNAL_MATCH ::
	"type='signal',interface='" + IPC_INTERFACE + "',path='" + IPC_OBJECT_PATH + "'"
IPC_METHOD_MATCH ::
	"type='method',interface='" + IPC_INTERFACE + "',path='" + IPC_OBJECT_PATH + "'"
IPC_SIGNAL_WAKE :: "wake"
IPC_METHOD_RULE :: "rule"
IPC_METHOD_VOLUME :: "volume"

ipc_init :: proc() -> IpcError {
	// connect to and activate bus
	dbus_err: dbus.Error
	dbus.error_init(&dbus_err)
	defer if dbus.error_is_set(&dbus_err) {dbus.error_free(&dbus_err)}

	ctx.conn = dbus.bus_get_private(.SESSION, &dbus_err)
	if dbus.error_is_set(&dbus_err) {return .CannotConnect}
	dbus.connection_set_exit_on_disconnect(ctx.conn, false)

	if app_id, found := os.lookup_env("FLATPAK_ID", context.allocator); found {
		ctx.service_name = strings.clone_to_cstring(app_id)
		delete(app_id, context.allocator)
	} else {
		ctx.service_name = strings.clone_to_cstring("dev.cstring.mixologist")
	}
	ret_code := dbus.bus_request_name(ctx.conn, ctx.service_name, {.DO_NOT_QUEUE}, &dbus_err)
	if dbus.error_is_set(&dbus_err) {return .CannotConnect}

	if ret_code != .REPLY_PRIMARY_OWNER {return .NameTaken}

	// register signals and messages
	dbus.bus_add_match(ctx.conn, IPC_SIGNAL_MATCH, &dbus_err)
	if dbus.error_is_set(&dbus_err) {return .SetupErr}

	dbus.bus_add_match(ctx.conn, IPC_SIGNAL_MATCH, &dbus_err)
	if dbus.error_is_set(&dbus_err) {return .SetupErr}

	dbus.connection_add_filter(ctx.conn, ipc_dbus_handler, nil, nil)
	return nil
}

ipc_dbus_handler :: proc "c" (
	connection: ^dbus.Connection,
	message: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = shared_state.odin_ctx

	if dbus.message_is_signal(message, IPC_INTERFACE, IPC_SIGNAL_WAKE) {
		daemon_wake_gui()
		return .HANDLED
	} else if dbus.message_is_method_call(message, IPC_INTERFACE, IPC_METHOD_RULE) {
		ls: ListString
		err := dbus.unmarshal(message, &ls)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		daemon_update_gui_rule(ls)
		return .HANDLED
	} else if dbus.message_is_method_call(message, IPC_INTERFACE, IPC_METHOD_VOLUME) {
		v: Volume
		err := dbus.unmarshal(message, &v)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		switch v.kind {
		case .Add, .Set:
			daemon_update_gui_volume(v)
		case .Get:
			reply := dbus.message_new_method_return(message)
			defer dbus.message_unref(reply)
			dbus.marshal(reply, Volume{val = daemon.state.volume})
			dbus.connection_send(ctx.conn, reply, nil)
		}
		return .HANDLED
	}

	return .NOT_YET_HANDLED
}

ipc_server_fd :: proc() -> linux.Fd {
	fd: i32
	dbus.connection_get_unix_fd(ctx.conn, &fd)
	return linux.Fd(fd)
}

ipc_server_tick :: proc() {
	dbus.connection_read_write(ctx.conn, 0)
	for dbus.connection_dispatch(ctx.conn) == .DATA_REMAINS {}
}

ipc_fini :: proc() {
	dbus.connection_close(ctx.conn)
	delete(ctx.service_name)
}
