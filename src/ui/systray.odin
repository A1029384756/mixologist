package ui

import "../dbus"
import "core:fmt"
import "core:image"
import "core:log"
import "core:os"

@(private)
tray_count := 0

SNI_OBJECT_PATH :: "/StatusNotifierItem"

Systray :: struct {
	connection:            ^dbus.Connection,
	service_name:          cstring,
	icon:                  []byte,
	title, tooltop:        string,
	// tray menu click
	activate_cb:           SystrayClickCallback,
	menu_open_cb:          SystrayClickCallback,
	secondary_activate_cb: SystrayClickCallback,
	userdata:              rawptr,
}
SystrayClickCallback :: #type proc(tray: ^Systray, userdata: rawptr)

systray_new :: proc(allocator := context.allocator) -> (tray: ^Systray, ok: bool) {
	tray = new(Systray, allocator)

	err: dbus.Error
	dbus.error_init(&err)

	tray.connection = dbus.bus_get_private(.SESSION, &err)
	defer if dbus.error_is_set(&err) {
		dbus.error_free(&err)
		free(tray)
	}
	if dbus.error_is_set(&err) {
		return nil, false
	}
	defer if dbus.error_is_set(&err) {
		dbus.connection_close(tray.connection)
	}

	tray_count += 1
	if app_id, found := os.lookup_env("FLATPAK_ID", allocator); found {
		tray.service_name = fmt.caprintf("%s.tray-%d", app_id, tray_count, allocator)
		delete(app_id)
	} else {
		tray.service_name = fmt.caprintf(
			"org.kde.StatusNotifierItem-%d-%d",
			os.get_pid(),
			tray_count,
		)
	}
	request_name_status := dbus.bus_request_name(
		tray.connection,
		tray.service_name,
		{.REPLACE_EXISTING},
		&err,
	)
	if dbus.error_is_set(&err) {
		log.errorf("Unable to create tray: %s - %s", err.name, err.message)
		return nil, false
	}
	if request_name_status != .REPLY_PRIMARY_OWNER {
		log.errorf("Unable to create tray, could not request unique name")
		dbus.connection_close(tray.connection)
	}

	register_object_status := dbus.connection_try_register_object_path(
		tray.connection,
		SNI_OBJECT_PATH,
		&{message_function = tray_message_handler},
		nil,
		&err,
	)
	if dbus.error_is_set(&err) {
		log.errorf("Unable to create tray: %s - %s", err.name, err.message)
		return nil, false
	}
	if !register_object_status {
		log.errorf("Unable to create tray: could not register object path")
		return nil, false
	}

	return tray, true
}

tray_message_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	userdata: rawptr,
) -> dbus.HandlerResult {
	return .NOT_YET_HANDLED
}
