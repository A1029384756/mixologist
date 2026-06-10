package mixologist

import "core:log"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
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
	loop:              Loop(EventWatch),
}

EventWatch :: enum {
	Quit,
	State,
	Pipewire,
	Ipc,
	Config,
	Volume,
	GlobalShortcuts,
	Systray,
}
EventLoopRegistration :: LoopRegistration(EventWatch)

daemon_init :: proc() {
	state_populate(&daemon.state)
	loop_init(&daemon.loop)

	pw_fd := pw_init()
	daemon.config_save_timer, _ = linux.timerfd_create(.MONOTONIC, {})
	daemon.volume_save_timer, _ = linux.timerfd_create(.MONOTONIC, {})
	
	// odinfmt: disable
	loop_register(&daemon.loop, EventLoopRegistration{id = .Quit, ops = {.Read}, handle = shared_state.quit_eventfd})
	loop_register(&daemon.loop, EventLoopRegistration{id = .State, ops = {.Read}, handle = shared_state.state_eventfd})
	loop_register(&daemon.loop, EventLoopRegistration{id = .Pipewire, ops = {.Read}, handle = pw_fd})
	loop_register(&daemon.loop, EventLoopRegistration{id = .Ipc, ops = {.Read}, handle = ipc_server_fd()})
	loop_register(&daemon.loop, EventLoopRegistration{id = .Config, ops = {.Read}, handle = daemon.config_save_timer})
	loop_register(&daemon.loop, EventLoopRegistration{id = .Volume, ops = {.Read}, handle = daemon.volume_save_timer})
	if gs_fd, has_gs := portals_init(daemon.state.settings.autostart); has_gs {
		loop_register(&daemon.loop, EventLoopRegistration{id = .GlobalShortcuts, ops = {.Read}, handle = gs_fd})
		daemon.features += {.Shortcuts}
	}
	if !shared_state.is_daemon {
		if tray_fd, has_tray := systray_init(); has_tray {
			loop_register(&daemon.loop, EventLoopRegistration{id = .Systray, ops = {.Read}, handle = tray_fd})
			daemon.features += {.Tray}
		}
	}
	// odinfmt: enable
}

daemon_proc :: proc() {
	mainloop: for event in loop_poll(&daemon.loop, -1) {
		daemon.state_status = {}

		switch event {
		case .Quit:
			fd_drain(shared_state.quit_eventfd)
			break mainloop
		case .State:
			fd_drain(shared_state.state_eventfd)
			daemon_process_messages()
		case .Pipewire:
			pw_tick()
		case .Ipc:
			ipc_server_tick()
		case .Config:
			fd_drain(daemon.config_save_timer)
			config_write(
				{
					rules = daemon.state.rules,
					passthrough = daemon.state.passthrough,
					settings = daemon.state.settings,
				},
			)
		case .Volume:
			fd_drain(daemon.volume_save_timer)
			config_volume_write(daemon.state.volume)
		case .GlobalShortcuts:
			global_shortcuts_tick()
		case .Systray:
			systray_tick()
		}
		if .Config in daemon.state_status {
			timerfd_arm(daemon.config_save_timer, 1000)
		}
		if .Volume in daemon.state_status {
			timerfd_arm(daemon.volume_save_timer, 1000)
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
			portals_set_autostart(daemon.state.settings.autostart)
		case:
			log.errorf("unexpected %v", msg.kind)
		}
	}
}

daemon_fini :: proc() {
	config_write(
		{
			rules = daemon.state.rules,
			passthrough = daemon.state.passthrough,
			settings = daemon.state.settings,
		},
	)
	config_volume_write(daemon.state.volume)
	state_destroy(daemon.state)
	linux.close(daemon.config_save_timer)
	linux.close(daemon.volume_save_timer)
	portals_fini()
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
