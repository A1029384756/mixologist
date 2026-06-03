package mixologist

import "core:fmt"
import "core:log"
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

IPC_OBJECT_PATH: cstring
IPC_METHOD_WAKE :: "wake"
IPC_METHOD_RULE :: "rule"
IPC_METHOD_VOLUME :: "volume"

ipc_init :: proc() -> IpcError {
	path_cleaned, _ := strings.replace(APP_ID, ".", "/", -1)
	IPC_OBJECT_PATH = fmt.caprintf("/%s", path_cleaned)
	delete(path_cleaned)
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
		reply := dbus.message_new_method_return(message)
		defer dbus.message_unref(reply)
		dbus.connection_send(ctx.conn, reply, nil)
		return .HANDLED
	} else if dbus.message_is_method_call(message, APP_ID, IPC_METHOD_RULE) {
		ls: ListString
		err := dbus.unmarshal(message, &ls)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		daemon_update_gui_rule(ls)
		reply := dbus.message_new_method_return(message)
		defer dbus.message_unref(reply)
		dbus.connection_send(ctx.conn, reply, nil)
		return .HANDLED
	} else if dbus.message_is_method_call(message, APP_ID, IPC_METHOD_VOLUME) {
		v: Volume
		err := dbus.unmarshal(message, &v)
		if err != nil {
			log.errorf("could not unmarshal message: %v", err)
			return .NOT_YET_HANDLED
		}
		switch v.kind {
		case .Add, .Set:
			daemon_update_gui_volume(v)
			reply := dbus.message_new_method_return(message)
			defer dbus.message_unref(reply)
			dbus.connection_send(ctx.conn, reply, nil)
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
	if ctx.conn != nil {
		dbus.connection_close(ctx.conn)
	}
	delete(ctx.service_name)
	delete(IPC_OBJECT_PATH)
}
