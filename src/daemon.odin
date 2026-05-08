package mixologist

import "core:sync/chan"
import "core:sys/linux"

daemon: Daemon
Daemon :: struct {
	state:             State,
	pw_fd:             linux.Fd,
	gs_fd:             linux.Fd,
	ipc_fd:            linux.Fd,
	config_save_timer: linux.Fd,
	volume_save_timer: linux.Fd,
	fds:               [dynamic]linux.Poll_Fd,
	n_sys_fds:         int,
}

FD_QUIT :: 0
FD_STATE :: 1
FD_PW :: 2
FD_IPC :: 3
FD_CFG :: 4
FD_VOL :: 5
FD_DBUS :: 6

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
	}
	daemon.n_sys_fds = len(daemon.fds)
}

daemon_proc :: proc() {
	for {
		free_all(context.temp_allocator)
	}
}

daemon_fini :: proc() {
	state_destroy(daemon.state)
	linux.close(daemon.config_save_timer)
	linux.close(daemon.volume_save_timer)
	global_shortcuts_fini()
	pw_fini()
}

daemon_update_gui_volume :: proc(volume: f32) {
	daemon.state.volume = volume
	chan.send(shared_state.daemon_chan, Message{kind = .Volume, volume = {.Set, volume}})
}

daemon_update_gui_rule :: proc(rule: ListString) {
	modify_string_list(&daemon.state.rules, rule)
	chan.send(shared_state.daemon_chan, Message{kind = .Rule, list = rule})
}

daemon_update_gui_program :: proc(rule: ListString) {
	modify_string_list(&daemon.state.programs, rule)
	chan.send(shared_state.daemon_chan, Message{kind = .Program, list = rule})
}

daemon_update_gui_settings :: proc(settings: Settings) {
	daemon.state.settings = settings
	chan.send(shared_state.daemon_chan, Message{kind = .Settings, settings = settings})
}
