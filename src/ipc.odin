package mixologist

import "core:log"
import "core:sys/linux"
import "shared:dbus"

IPCServer :: struct {
	service_name: cstring,
	conn:         ^dbus.Connection,
}

@(private = "file")
ctx: IPCServer

IPC_OBJECT_PATH: cstring
IPC_SIGNAL_WAKE :: "Wake"
IPC_METHOD_RULE :: "Rule"
IPC_METHOD_VOLUME :: "Volume"

IPC_DBUS_INTROSPECTION :: #load("mixologist-introspect.xml", string)

ipc_init :: proc() -> dbus.ConectionError {
	ctx.service_name = dbus_bus_name()
	ctx.conn = dbus.connection_open_with_name(ctx.service_name) or_return

	dbus_err: dbus.Error
	dbus.error_init(&dbus_err)
	dbus.connection_try_register_object_path(
		ctx.conn,
		IPC_OBJECT_PATH,
		&{message_function = ipc_dbus_handler},
		nil,
		&dbus_err,
	)
	if dbus.error_is_set(&dbus_err) {
		dbus.error_free(&dbus_err)
		return .SetupErr
	}
	return nil
}

ipc_dbus_handler :: proc "c" (
	connection: ^dbus.Connection,
	message: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = shared_state.odin_ctx

	iface := string(dbus.message_get_interface(message))
	member := string(dbus.message_get_member(message))
	log.debug(iface, member)
	switch iface {
	case "org.freedesktop.DBus.Introspectable":
		if member == "Introspect" {
			dbus.method_return(ctx.conn, message, IPC_DBUS_INTROSPECTION)
		}
	case APP_ID:
		switch member {
		case IPC_SIGNAL_WAKE:
			daemon_wake_gui()
			dbus.method_return(ctx.conn, message)
			return .HANDLED
		case IPC_METHOD_RULE:
			ls: ListString
			err := dbus.unmarshal(message, &ls, context.temp_allocator)
			if err != nil {
				log.errorf("could not unmarshal message: %v", err)
				return .NOT_YET_HANDLED
			}
			daemon_update_gui_rule(ls)
			dbus.method_return(ctx.conn, message)
			return .HANDLED
		case IPC_METHOD_VOLUME:
			v: Volume
			err := dbus.unmarshal(message, &v, context.temp_allocator)
			if err != nil {
				log.errorf("could not unmarshal message: %v", err)
				return .NOT_YET_HANDLED
			}
			switch v.kind {
			case .Add, .Set:
				daemon_update_gui_volume(v)
				dbus.method_return(ctx.conn, message)
			case .Get:
				dbus.method_return(ctx.conn, message, Volume{val = daemon.state.volume})
			}
			return .HANDLED
		}
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
