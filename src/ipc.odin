package mixologist

import "core:log"
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

IPC_OBJECT_PATH: cstring
IPC_METHOD_WAKE :: "wake"
IPC_METHOD_RULE :: "rule"
IPC_METHOD_VOLUME :: "volume"

ipc_init :: proc() -> IpcError {
	ctx.conn, ctx.service_name = dbus_open_connection_with_name() or_return
	dbus.connection_add_filter(ctx.conn, ipc_dbus_handler, nil, nil)
	return nil
}

ipc_dbus_handler :: proc "c" (
	connection: ^dbus.Connection,
	message: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = shared_state.odin_ctx

	if dbus.message_is_method_call(message, APP_ID, IPC_METHOD_WAKE) {
		daemon_wake_gui()
		dbus_method_return(ctx.conn, message)
		return .HANDLED
	} else if dbus.message_is_method_call(message, APP_ID, IPC_METHOD_RULE) {
		ls: ListString
		err := dbus.unmarshal(message, &ls, context.temp_allocator)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		daemon_update_gui_rule(ls)
		dbus_method_return(ctx.conn, message)
		return .HANDLED
	} else if dbus.message_is_method_call(message, APP_ID, IPC_METHOD_VOLUME) {
		v: Volume
		err := dbus.unmarshal(message, &v, context.temp_allocator)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		switch v.kind {
		case .Add, .Set:
			daemon_update_gui_volume(v)
			dbus_method_return(ctx.conn, message)
		case .Get:
			dbus_method_return(ctx.conn, message, Volume{val = daemon.state.volume})
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
	if ctx.conn != nil {
		dbus.connection_close(ctx.conn)
	}
	delete(ctx.service_name)
}
