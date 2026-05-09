package systray

import "../../dbus"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"

@(private)
tray_count := 0

SNI_OBJECT_PATH :: "/StatusNotifierItem"
SNI_INTERFACE :: "org.kde.StatusNotifierItem"
DBUS_PROPERTIES_INTERFACE :: "org.freedesktop.DBus.Properties"
DBUS_INTROSPECTABLE_INTERFACE :: "org.freedesktop.DBus.Introspectable"

WATCHER_BUS :: "org.kde.StatusNotifierWatcher"
WATCHER_PATH :: "/StatusNotifierWatcher"
WATCHER_INTERFACE :: "org.kde.StatusNotifierWatcher"

@(private = "file")
INTROSPECT_XML := #load("dbus-sni.xml")

Pixmap :: struct {
	width:  i32,
	height: i32,
	data:   []u8,
}

Tooltip :: struct {
	icon_name: string,
	icon_data: []Pixmap,
	title:     string,
	text:      string,
}

// odinfmt:disable
StatusNotifierTray :: struct {
	category:              string   `dbus_name:"Category"`,
	id:                    string   `dbus_name:"Id"`,
	title:                 string   `dbus_name:"Title"`,
	status:                string   `dbus_name:"Status"`,
	window_id:             u32      `dbus_name:"WindowId"`,
	icon_theme_path:       string   `dbus_name:"IconThemePath"`,
	icon_name:             string   `dbus_name:"IconName"`,
	icon_pixmap:           []Pixmap `dbus_name:"IconPixmap"`,
	overlay_icon_name:     string   `dbus_name:"OverlayIconName"`,
	overlay_icon_pixmap:   []Pixmap `dbus_name:"OverlayIconPixmap"`,
	attention_icon_name:   string   `dbus_name:"AttentionIconName"`,
	attention_icon_pixmap: []Pixmap `dbus_name:"AttentionIconPixmap"`,
	attention_movie_name:  string   `dbus_name:"AttentionMovieName"`,
	tool_tip:              Tooltip  `dbus_name:"ToolTip"`,
	item_is_menu:          bool     `dbus_name:"ItemIsMenu"`,
	menu:                  string   `dbus_name:"Menu" dbus:"o"`,
}
// odinfmt:enable

ClickCallback :: #type proc(tray: ^Systray, userdata: rawptr, x, y: i32)
ScrollCallback :: #type proc(tray: ^Systray, userdata: rawptr, delta: i32, orientation: string)

Systray :: struct {
	connection:            ^dbus.Connection,
	service_name:          cstring,
	item:                  StatusNotifierTray,
	menu:                  Menu,
	xdg_activation_token:  string,
	activate_cb:           ClickCallback,
	menu_open_cb:          ClickCallback,
	secondary_activate_cb: ClickCallback,
	scroll_cb:             ScrollCallback,
	userdata:              rawptr,
	allocator:             runtime.Allocator,
	odin_ctx:              runtime.Context,
}

init :: proc(tray: ^Systray, item: StatusNotifierTray, allocator := context.allocator) -> bool {
	tray.allocator = allocator
	tray.odin_ctx = context
	tray.item = item
	if tray.item.menu == "" do tray.item.menu = "/"

	err: dbus.Error
	dbus.error_init(&err)

	tray.connection = dbus.bus_get_private(.SESSION, &err)
	dbus.connection_set_exit_on_disconnect(tray.connection, false)
	if dbus.error_is_set(&err) {
		dbus.error_free(&err)
		return false
	}
	defer if dbus.error_is_set(&err) {
		dbus.connection_close(tray.connection)
	}

	tray_count += 1
	if app_id, found := os.lookup_env("FLATPAK_ID", allocator); found {
		tray.service_name = fmt.caprintf("%s.tray-%d", app_id, tray_count, allocator = allocator)
		delete(app_id, allocator)
	} else {
		tray.service_name = fmt.caprintf(
			"org.kde.StatusNotifierItem-%d-%d",
			os.get_pid(),
			tray_count,
			allocator = allocator,
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
		return false
	}
	if request_name_status != .REPLY_PRIMARY_OWNER {
		log.errorf("Unable to create tray, could not request unique name")
		dbus.connection_close(tray.connection)
		return false
	}

	register_object_status := dbus.connection_try_register_object_path(
		tray.connection,
		SNI_OBJECT_PATH,
		&{message_function = tray_message_handler},
		tray,
		&err,
	)
	if dbus.error_is_set(&err) {
		log.errorf("Unable to create tray: %s - %s", err.name, err.message)
		return false
	}
	if !register_object_status {
		log.errorf("Unable to create tray: could not register object path")
		return false
	}

	if tray.item.menu != "/" {
		menu_init(&tray.menu, tray.connection, tray.item.menu, allocator)
	}

	register_with_watcher(tray.connection, tray.service_name)

	return true
}

pump :: proc(tray: ^Systray) {
	dbus.connection_read_write_dispatch(tray.connection, 0)
}

deinit :: proc(tray: ^Systray) {
	menu_deinit(&tray.menu)

	if tray.connection != nil {
		dbus.connection_unregister_object_path(tray.connection, SNI_OBJECT_PATH)
		if tray.service_name != "" {
			err: dbus.Error
			dbus.error_init(&err)
			dbus.bus_release_name(tray.connection, tray.service_name, &err)
			if dbus.error_is_set(&err) do dbus.error_free(&err)
		}
		dbus.connection_close(tray.connection)
		dbus.connection_unref(tray.connection)
	}

	free_pixmap_slice(tray.item.icon_pixmap)
	free_pixmap_slice(tray.item.overlay_icon_pixmap)
	free_pixmap_slice(tray.item.attention_icon_pixmap)

	if len(tray.xdg_activation_token) > 0 do delete(tray.xdg_activation_token, tray.allocator)
	if tray.service_name != "" do delete(tray.service_name, tray.allocator)

	tray^ = {}
}

@(private = "file")
register_with_watcher :: proc(conn: ^dbus.Connection, service_name: cstring) {
	msg := dbus.message_new_method_call(
		WATCHER_BUS,
		WATCHER_PATH,
		WATCHER_INTERFACE,
		"RegisterStatusNotifierItem",
	)
	if msg == nil {
		log.warn("could not allocate watcher registration message")
		return
	}
	defer dbus.message_unref(msg)

	if dbus.marshal(msg, service_name) != nil {
		log.warn("failed to append watcher registration arg")
		return
	}

	if !dbus.connection_send(conn, msg, nil) {
		log.warn("failed to send watcher registration (host may not be running)")
	}
}

@(private)
send_empty_reply :: proc(conn: ^dbus.Connection, msg: ^dbus.Message) -> dbus.HandlerResult {
	if dbus.message_get_no_reply(msg) do return .HANDLED
	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_get_all :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	tray: ^Systray,
) -> dbus.HandlerResult {
	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	GetAllReply :: struct {
		properties: StatusNotifierTray `dbus:"a{sv}"`,
	}
	if err := dbus.marshal(reply, GetAllReply{tray.item}); err != nil {
		log.errorf("tray GetAll marshal failed: %v", err)
		return .NOT_YET_HANDLED
	}
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_introspect :: proc(conn: ^dbus.Connection, msg: ^dbus.Message) -> dbus.HandlerResult {
	reply := dbus.message_new_method_return(msg)
	if reply == nil do return .NEED_MEMORY
	defer dbus.message_unref(reply)

	if dbus.marshal(reply, string(INTROSPECT_XML)) != nil do return .NEED_MEMORY
	if !dbus.connection_send(conn, reply, nil) do return .NEED_MEMORY
	return .HANDLED
}

@(private = "file")
handle_click :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	tray: ^Systray,
	cb: ClickCallback,
) -> dbus.HandlerResult {
	args: struct {
		x, y: i32,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	if cb != nil do cb(tray, tray.userdata, args.x, args.y)
	return send_empty_reply(conn, msg)
}

@(private = "file")
handle_scroll :: proc(
	conn: ^dbus.Connection,
	msg: ^dbus.Message,
	tray: ^Systray,
) -> dbus.HandlerResult {
	args: struct {
		delta:       i32,
		orientation: string,
	}
	if dbus.unmarshal(msg, &args, context.temp_allocator) != nil do return .NOT_YET_HANDLED

	if tray.scroll_cb != nil do tray.scroll_cb(tray, tray.userdata, args.delta, args.orientation)
	return send_empty_reply(conn, msg)
}

@(private = "file")
emit_signal :: proc(tray: ^Systray, name: cstring) {
	msg := dbus.message_new_signal(SNI_OBJECT_PATH, SNI_INTERFACE, name)
	if msg == nil {
		log.warnf("could not allocate signal %s", name)
		return
	}
	defer dbus.message_unref(msg)
	if !dbus.connection_send(tray.connection, msg, nil) {
		log.warnf("failed to send signal %s", name)
	}
}

emit_new_title :: proc(tray: ^Systray) {emit_signal(tray, "NewTitle")}
emit_new_icon :: proc(tray: ^Systray) {emit_signal(tray, "NewIcon")}
emit_new_overlay_icon :: proc(tray: ^Systray) {emit_signal(tray, "NewOverlayIcon")}
emit_new_attention_icon :: proc(tray: ^Systray) {emit_signal(tray, "NewAttentionIcon")}
emit_new_tooltip :: proc(tray: ^Systray) {emit_signal(tray, "NewToolTip")}

emit_new_status :: proc(tray: ^Systray) {
	msg := dbus.message_new_signal(SNI_OBJECT_PATH, SNI_INTERFACE, "NewStatus")
	if msg == nil {
		log.warn("could not allocate NewStatus signal")
		return
	}
	defer dbus.message_unref(msg)

	if dbus.marshal(msg, tray.item.status) != nil {
		log.warn("failed to marshal NewStatus payload")
		return
	}
	if !dbus.connection_send(tray.connection, msg, nil) {
		log.warn("failed to send NewStatus signal")
	}
}

set_title :: proc(tray: ^Systray, title: string) {
	tray.item.title = title
	emit_new_title(tray)
}

set_status :: proc(tray: ^Systray, status: string) {
	tray.item.status = status
	emit_new_status(tray)
}

set_icon_name :: proc(tray: ^Systray, name: string) {
	tray.item.icon_name = name
	emit_new_icon(tray)
}

@(private = "file")
clone_pixmap_slice :: proc(pixmap: []Pixmap) -> []Pixmap {
	out := make([]Pixmap, len(pixmap))
	for p, i in pixmap {
		out[i].width = p.width
		out[i].height = p.height
		out[i].data = slice.clone(p.data)
	}
	return out
}

@(private = "file")
free_pixmap_slice :: proc(pixmap: []Pixmap) {
	for p in pixmap do delete(p.data)
	delete(pixmap)
}

set_icon_pixmap :: proc(tray: ^Systray, pixmap: []Pixmap) {
	free_pixmap_slice(tray.item.icon_pixmap)
	tray.item.icon_pixmap = clone_pixmap_slice(pixmap)
	emit_new_icon(tray)
}

set_overlay_icon_name :: proc(tray: ^Systray, name: string) {
	tray.item.overlay_icon_name = name
	emit_new_overlay_icon(tray)
}

set_overlay_icon_pixmap :: proc(tray: ^Systray, pixmap: []Pixmap) {
	free_pixmap_slice(tray.item.overlay_icon_pixmap)
	tray.item.overlay_icon_pixmap = clone_pixmap_slice(pixmap)
	emit_new_overlay_icon(tray)
}

set_attention_icon_name :: proc(tray: ^Systray, name: string) {
	tray.item.attention_icon_name = name
	emit_new_attention_icon(tray)
}

set_attention_icon_pixmap :: proc(tray: ^Systray, pixmap: []Pixmap) {
	free_pixmap_slice(tray.item.attention_icon_pixmap)
	tray.item.attention_icon_pixmap = clone_pixmap_slice(pixmap)
	emit_new_attention_icon(tray)
}

set_tooltip :: proc(tray: ^Systray, tooltip: Tooltip) {
	tray.item.tool_tip = tooltip
	emit_new_tooltip(tray)
}

@(private = "file")
tray_message_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	userdata: rawptr,
) -> dbus.HandlerResult {
	tray := (^Systray)(userdata)
	context = tray.odin_ctx

	iface := string(dbus.message_get_interface(msg))
	member := string(dbus.message_get_member(msg))

	switch iface {
	case DBUS_INTROSPECTABLE_INTERFACE:
		if member == "Introspect" do return handle_introspect(connection, msg)
	case DBUS_PROPERTIES_INTERFACE:
		if member == "GetAll" do return handle_get_all(connection, msg, tray)
	case SNI_INTERFACE:
		switch member {
		case "Activate":
			return handle_click(connection, msg, tray, tray.activate_cb)
		case "SecondaryActivate":
			return handle_click(connection, msg, tray, tray.secondary_activate_cb)
		case "ContextMenu":
			return handle_click(connection, msg, tray, tray.menu_open_cb)
		case "Scroll":
			return handle_scroll(connection, msg, tray)
		}
	}

	return .NOT_YET_HANDLED
}
