package mixologist

import "core:log"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import pw "pipewire"
import sdl "vendor:sdl3"

daemon: Daemon
Daemon :: struct {
	features:          bit_set[enum {
		Shortcuts,
		Tray,
	}],
	state:             State,
	state_status:      StateDirtyFlags,
	config_save_timer: linux.Fd,
	volume_save_timer: linux.Fd,
	fds:               [dynamic; 16]linux.Poll_Fd,
	n_sys_fds:         int,
}

FD_QUIT :: 0
FD_STATE :: 1
FD_PW :: 2
FD_IPC :: 3
FD_CFG :: 4
FD_VOL :: 5
FD_GS: int
FD_TRAY: int

daemon_init :: proc() {
	state_populate(&daemon.state)

	pw_fd := pw_init()
	daemon.config_save_timer, _ = linux.timerfd_create(.MONOTONIC, {})
	daemon.volume_save_timer, _ = linux.timerfd_create(.MONOTONIC, {})

	append(&daemon.fds, linux.Poll_Fd{fd = shared_state.quit_eventfd, events = {.IN}})
	append(&daemon.fds, linux.Poll_Fd{fd = shared_state.state_eventfd, events = {.IN}})
	append(&daemon.fds, linux.Poll_Fd{fd = pw_fd, events = {.IN}})
	append(&daemon.fds, linux.Poll_Fd{fd = ipc_server_fd(), events = {.IN}})
	append(&daemon.fds, linux.Poll_Fd{fd = daemon.config_save_timer, events = {.IN}})
	append(&daemon.fds, linux.Poll_Fd{fd = daemon.volume_save_timer, events = {.IN}})
	if gs_fd, has_gs := global_shortcuts_init(); has_gs {
		append(&daemon.fds, linux.Poll_Fd{fd = gs_fd, events = {.IN}})
		daemon.features += {.Shortcuts}
		FD_GS = len(daemon.fds) - 1
	}
	if !shared_state.is_daemon {
		if tray_fd, has_tray := systray_init(); has_tray {
			append(&daemon.fds, linux.Poll_Fd{fd = tray_fd, events = {.IN}})
			daemon.features += {.Tray}
			FD_TRAY = len(daemon.fds) - 1
		}
	}
	daemon.n_sys_fds = len(daemon.fds)
}

daemon_proc :: proc() {
	should_exit := false
	for !should_exit {
		daemon.state_status = {}
		_, poll_err := linux.poll(daemon.fds[:], -1)
		if poll_err != nil && poll_err != .EINTR {
			log.errorf("daemon polling error: %v", poll_err)
		}

		if daemon.fds[FD_QUIT].revents >= {.IN} {
			fd_drain(shared_state.quit_eventfd)
			should_exit = true
			break
		}
		if daemon.fds[FD_STATE].revents >= {.IN} {
			fd_drain(shared_state.state_eventfd)
			daemon_process_messages()
		}
		if daemon.fds[FD_PW].revents >= {.IN} {
			pw.loop_iterate(pw_get_loop(), 0)
		}
		if daemon.fds[FD_IPC].revents >= {.IN} {
			ipc_server_tick()
		}
		if .Shortcuts in daemon.features && daemon.fds[FD_GS].revents >= {.IN} {
			global_shortcuts_tick()
		}
		if !shared_state.is_daemon &&
		   .Tray in daemon.features &&
		   daemon.fds[FD_TRAY].revents >= {.IN} {
			systray_tick()
		}

		if .Config in daemon.state_status {
			timerfd_arm(daemon.config_save_timer, 1000)
		}
		if .Volume in daemon.state_status {
			timerfd_arm(daemon.volume_save_timer, 1000)
		}
		if daemon.fds[FD_CFG].revents >= {.IN} {
			fd_drain(daemon.config_save_timer)
			config_write(
				{
					rules = daemon.state.rules,
					passthrough = daemon.state.passthrough,
					settings = daemon.state.settings,
				},
			)
		}
		if daemon.fds[FD_VOL].revents >= {.IN} {
			fd_drain(daemon.volume_save_timer)
			config_volume_write(daemon.state.volume)
		}

		free_all(context.temp_allocator)
	}
}

daemon_process_messages :: proc() {
	for msg in chan.try_recv(shared_state.gui_chan) {
		#partial switch msg.kind {
		case .Rule:
			daemon.state_status += {.Config}
			list := msg.list
			switch list.kind {
			case .Add:
				pw_add_rule(list.val)
			case .Remove:
				pw_remove_rule(list.val)
			case .Update:
				pw_remove_rule(list.mod.prev)
				pw_add_rule(list.mod.curr)
			}
			list_string_modify(&daemon.state.rules, msg.list, true)
		case .Volume:
			daemon.state_status += {.Volume}
			modify_volume(&daemon.state.volume, msg.volume)
			pw_set_volumes(compress_values(pw_sink_volumes(daemon.state.volume)))
		case .Settings:
			daemon.state_status += {.Config}
			daemon.state.settings = msg.settings
			pw_set_volumes(compress_values(pw_sink_volumes(daemon.state.volume)))
		case:
			log.errorf("unexpected %v", msg.kind)
		}
	}
}

daemon_fini :: proc() {
	state_destroy(daemon.state)
	linux.close(daemon.config_save_timer)
	linux.close(daemon.volume_save_timer)
	global_shortcuts_fini()
	if !shared_state.is_daemon {
		systray_fini()
	}
	ipc_fini()
	pw_fini()
}

daemon_update_gui_volume :: proc(volume: Volume) {
	daemon.state_status += {.Volume}
	modify_volume(&daemon.state.volume, volume)
	pw_set_volumes(compress_values(pw_sink_volumes(daemon.state.volume)))

	if shared_state.is_daemon do return
	if !sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) do return
	chan.send(shared_state.daemon_chan, Message{kind = .Volume, volume = volume})
	_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
}

daemon_update_gui_rule :: proc(rule: ListString) {
	daemon.state_status += {.Config}
	if !shared_state.is_daemon {
		if sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) {
			chan.send(
				shared_state.daemon_chan,
				Message{kind = .Rule, list = list_string_clone(rule)},
			)
			_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
		}
	}
	list_string_modify(&daemon.state.rules, rule, false)
}

daemon_update_gui_program :: proc(program: ListString) {
	if shared_state.is_daemon do return
	if !sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) do return
	chan.send(
		shared_state.daemon_chan,
		Message{kind = .Program, list = list_string_clone(program)},
	)
	_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
}

daemon_update_gui_settings :: proc(settings: Settings) {
	daemon.state_status += {.Config}
	daemon.state.settings = settings
	pw_set_volumes(compress_values(pw_sink_volumes(daemon.state.volume)))
	if shared_state.is_daemon do return
	if !sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) do return
	chan.send(shared_state.daemon_chan, Message{kind = .Settings, settings = settings})
	_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
}

daemon_wake_gui :: proc() {
	if shared_state.is_daemon do return
	if sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) {
		chan.send(shared_state.daemon_chan, Message{kind = .Wake})
		_ = sdl.PushEvent(&{type = shared_state.gui_pump_event})
	}
}
