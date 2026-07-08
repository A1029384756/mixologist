package mixologist

import "core:log"
import "core:slice"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "shared:dbus"
import "shared:plutosvg"
import "shared:plutosvg/plutovg"
import "shared:systray"
import sdl "vendor:sdl3"

TRAY_ICON :: #load("../data/mixologist.svg")

@(private = "file")
ctx: Systray
Systray :: struct {
	tray:           systray.Systray,
	icon:           ^plutosvg.surface_t,
	tray_id_toggle: i32,
	tray_id_quit:   i32,
}

systray_init :: proc() -> (fd: linux.Fd, ok: bool) {
	icon_document := plutosvg.document_load_from_data(
		raw_data(TRAY_ICON),
		i32(len(TRAY_ICON)),
		-1,
		-1,
		nil,
		nil,
	)
	ctx.icon = plutosvg.document_render_to_surface(icon_document, nil, -1, -1, {}, nil, nil)

	systray.init(
		&ctx.tray,
		{
			category = "ApplicationStatus",
			id = "Mixologist",
			title = "Mixologist",
			status = "Active",
			menu = "/StatusNotifierItem/menu",
			tool_tip = {title = "Mixologist"},
		},
	)
	ctx.tray.userdata = &ctx
	ctx.tray.activate_cb = proc(tray: ^systray.Systray, userdata: rawptr, x, y: i32) {
		chan.send(shared_state.daemon_chan, Toggle{})
		_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
	}
	ctx.tray.menu.userdata = &ctx
	ctx.tray.menu.activate_cb = on_tray_menu_activate

	ctx.tray_id_toggle = systray.menu_add_item(&ctx.tray.menu, 0, {label = "Show / Hide"})
	_ = systray.menu_add_item(&ctx.tray.menu, 0, {type = .Separator})
	ctx.tray_id_quit = systray.menu_add_item(&ctx.tray.menu, 0, {label = "Quit"})
	pixel_count := int(ctx.icon.width * ctx.icon.height)
	src := slice.bytes_from_ptr(ctx.icon.data, pixel_count * 4)
	swizzled := make([]u8, pixel_count * 4, context.temp_allocator)
	for i in 0 ..< pixel_count {
		base := i * 4
		swizzled[base + 0] = src[base + 3]
		swizzled[base + 1] = src[base + 2]
		swizzled[base + 2] = src[base + 1]
		swizzled[base + 3] = src[base + 0]
	}
	systray.set_icon_pixmap(
		&ctx.tray,
		{{width = ctx.icon.width, height = ctx.icon.height, data = swizzled}},
	)

	ok = cast(bool)dbus.connection_get_unix_fd(ctx.tray.connection, cast(^i32)(&fd))
	if !ok do log.errorf("could not get fd for tray")
	return fd, ok
}

systray_tick :: proc() {
	systray.pump(&ctx.tray)
}

systray_fini :: proc() {
	systray.deinit(&ctx.tray)
	plutovg.surface_destroy(ctx.icon)
}

on_tray_menu_activate :: proc(menu: ^systray.Menu, id: i32, userdata: rawptr) {
	if !sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) do return
	ctx := cast(^Systray)userdata
	switch id {
	case ctx.tray_id_toggle:
		chan.send(shared_state.daemon_chan, Toggle{})
		_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
	case ctx.tray_id_quit:
		handle_term(.SIGINT)
	}
}
