package mixologist

import "base:runtime"
import "core:log"
import "core:sys/linux"
import "shared:dbus"
import xdp "shared:xdg-desktop-portals"

Shortcut :: enum {
	Raise,
	Lower,
	Reset,
	Max,
	Min,
}

Shortcut_Info := [Shortcut]xdp.GlobalShortcut {
	.Raise = {id = "raise", description = "favor selected", trigger_description = "SHIFT+F12"},
	.Lower = {id = "lower", description = "favor system", trigger_description = "SHIFT+F11"},
	.Reset = {id = "reset", description = "reset", trigger_description = "SHIFT+F10"},
	.Max = {id = "max", description = "isolate selected", trigger_description = "ALT+SHIFT+F12"},
	.Min = {id = "min", description = "isolate system", trigger_description = "ALT+SHIFT+F11"},
}

shortcut_from_str :: proc(input: string) -> Shortcut {
	switch input {
	case "raise":
		return .Raise
	case "lower":
		return .Lower
	case "reset":
		return .Reset
	case "max":
		return .Max
	case "min":
		return .Min
	case:
		log.panic("invalid shortcut id")
	}
}

global_shortcuts_tick :: proc() {
	for xdp.event_poll(&ctx); event in xdp.event_iter(&ctx) {
		#partial switch event.kind {
		case .GlobalShortcutActivated:
			shortcut_id := shortcut_from_str(event.global_shortcut.id)
			switch shortcut_id {
			case .Raise:
				daemon_update_gui_volume({.Add, 0.1})
			case .Lower:
				daemon_update_gui_volume({.Add, -0.1})
			case .Max:
				daemon_update_gui_volume({.Set, 1})
			case .Min:
				daemon_update_gui_volume({.Set, -1})
			case .Reset:
				daemon_update_gui_volume({.Set, 0})
			}
		}
	}
}

@(private = "file")
ctx: xdp.Context

global_shortcuts_init :: proc() -> (fd: linux.Fd, ok: bool) {
	context = shared_state.odin_ctx
	xdp.init(&ctx, "", APP_ID, "mixologist")
	gs_err := xdp.global_shortcuts_init(&ctx)
	if gs_err != nil do return 0, false

	listed_shortcuts, _ := xdp.global_shortcuts_list_shortcuts(&ctx)
	all_shortcuts_bound := true
	for shortcut in Shortcut_Info {
		found := false
		for listed_shortcut in listed_shortcuts {
			if listed_shortcut.id == shortcut.id do found = true
		}
		if !found {
			log.infof("could not find shortcut: %v", shortcut)
			all_shortcuts_bound = false
			break
		}
	}
	xdp.global_shortcuts_slice_delete(listed_shortcuts)
	if !all_shortcuts_bound {
		shortcuts: [len(Shortcut_Info)]xdp.GlobalShortcut
		for shortcut, idx in Shortcut_Info {
			shortcuts[idx] = shortcut
		}
		bound_shortcuts, _ := xdp.global_shortcuts_bind_shortcuts(&ctx, shortcuts[:])
		xdp.global_shortcuts_slice_delete(bound_shortcuts)
	}
	has_fd := dbus.connection_get_unix_fd(ctx.conn, cast(^i32)(&fd))
	if !has_fd do return 0, false
	return fd, true
}

global_shortcuts_fini :: proc() {
	dbus.connection_close(ctx.conn)
	xdp.deinit(&ctx)
}
