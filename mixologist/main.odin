package mixologist

import "../common"
import "core:encoding/cbor"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os/os2"
import "core:strings"
import "core:sys/linux"
import "core:time"

Mixologist :: struct {
	// state
	statuses:   Statuses,
	events:     [dynamic]Event,
	// inotify
	fd:         linux.Fd,
	wd:         linux.Wd,
	buf:        [EVENT_BUF_LEN]u8,
	// ipc
	ipc:        IPC_Server_Context,
	// subapp states
	daemon:     Daemon_Context,
	gui:        GUI_Context,
	// config
	config_dir: string,
	config:     Config,
	volume:     f32,
}

Config :: struct {
	rules:           [dynamic]string,
	start_minimized: bool,
}

CONFIG_FILENAME :: "mixologist.json"

Statuses :: bit_set[Status]
Status :: enum {
	Daemon,
	Gui,
	Exit,
}

Event :: union {
	Rule_Add,
	Rule_Remove,
	Rule_Update,
	Volume,
}
Rule_Add :: distinct string
Rule_Remove :: distinct string
Rule_Update :: struct {
	prev: string,
	cur:  string,
}
Volume :: f32

EVENT_SIZE :: size_of(linux.Inotify_Event)
EVENT_BUF_LEN :: 1024 * (EVENT_SIZE + 16)

mixologist: Mixologist

main :: proc() {
	context.logger = log.create_console_logger(common.get_log_level())

	// set up inotify
	{
		base_dir, _ := os2.user_config_dir(context.allocator)
		mixologist.config_dir, _ = os2.join_path({base_dir, "mixologist"}, context.allocator)

		in_err: linux.Errno
		mixologist.fd, in_err = linux.inotify_init1({.NONBLOCK})
		assert(in_err == nil)
		mixologist.wd, in_err = linux.inotify_add_watch(
			mixologist.fd,
			strings.clone_to_cstring(mixologist.config_dir),
			{.CREATE, .DELETE, .MODIFY} + linux.IN_MOVE,
		)
		assert(in_err == nil)
	}
	ipc_start_err := IPC_Server_init(&mixologist.ipc)
	if ipc_start_err != nil {
		fmt.println("detected active mixologist instance, sending wake command")
		// send wake command
		msg: common.Message = common.Wake{}
		message, encoding_err := cbor.marshal(msg)
		assert(encoding_err == nil)

		client_fd, socket_err := linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT)
		if socket_err != nil do log.panicf("could not create socket with error %v", socket_err)

		client_addr: linux.Sock_Addr_Un
		client_addr.sun_family = .UNIX
		copy(client_addr.sun_path[:], SERVER_SOCKET)

		connect_err := linux.connect(client_fd, &client_addr)
		if connect_err != nil do log.panicf("could not connect to socket with error %v", connect_err)

		_, send_err := linux.send(client_fd, message, {})
		if send_err != nil {
			log.infof("could not send wake command: %v", send_err)
		}
		os2.exit(1)
	}

	if len(os2.args) == 2 && os2.args[1] == "-daemon" {
		mixologist.statuses += {.Daemon}
	} else if len(os2.args) > 1 {
		fmt.println("the only flag supported is `-daemon`")
	} else {
		mixologist.statuses += {.Daemon, .Gui}
	}

	mixologist_config_load(&mixologist)

	if .Daemon in mixologist.statuses {
		daemon_init(&mixologist.daemon)
	}

	if .Gui in mixologist.statuses {
		gui_init(&mixologist.gui, mixologist.config.start_minimized)
	}

	for (.Exit not_in mixologist.statuses) {
		// hot-reload
		{
			length, read_err := linux.read(mixologist.fd, mixologist.buf[:])
			assert(read_err == nil || read_err == .EAGAIN)

			config_modified := false
			for i := 0; i < length; {
				event := cast(^linux.Inotify_Event)&mixologist.buf[i]

				if inotify_event_name(event) == CONFIG_FILENAME {
					config_modified = true
					break
				}

				i += EVENT_SIZE + int(event.len)
			}

			if config_modified {
				mixologist_config_reload(&mixologist)
				mixologist.gui.ui_ctx.statuses += {.DIRTY}
			}
		}

		// ipc
		IPC_Server_poll(&mixologist.ipc)
		mixologist_ipc_messages(&mixologist)

		if .Daemon in mixologist.statuses {
			daemon_tick(&mixologist.daemon)
			if daemon_should_exit(&mixologist.daemon) {
				mixologist.statuses += {.Exit}
			}
		}

		if .Gui in mixologist.statuses {
			gui_tick(&mixologist.gui)
			if UI_should_exit(&mixologist.gui.ui_ctx) {
				mixologist.statuses += {.Exit}
			}
		} else {
			time.sleep(time.Millisecond / 2)
		}

		for event in mixologist.events {
			switch event in event {
			case Rule_Add:
				log.debugf("adding rule: %v", event)
				daemon_add_program(&mixologist.daemon, string(event))
				append(&mixologist.config.rules, string(event))
				mixologist_config_write(&mixologist)
			case Rule_Remove:
				log.debugf("removing rule: %v", event)
				daemon_remove_program(&mixologist.daemon, string(event))
				#reverse for rule, idx in mixologist.config.rules {
					if rule == string(event) {
						delete(rule)
						ordered_remove(&mixologist.config.rules, idx)
						break
					}
				}
				mixologist_config_write(&mixologist)
			case Rule_Update:
				if len(event.cur) == 0 {
					log.debugf("updating to zero-length rule: %v", event.prev)
					daemon_remove_program(&mixologist.daemon, event.prev)
					for rule, idx in mixologist.config.rules {
						if rule == event.prev {
							delete(rule)
							delete(event.cur)
							ordered_remove(&mixologist.config.rules, idx)
							break
						}
					}
				} else {
					log.debugf("updating rule: %v -> %v", event.prev, event.cur)
					daemon_remove_program(&mixologist.daemon, event.prev)
					daemon_add_program(&mixologist.daemon, event.cur)
					for &rule in mixologist.config.rules {
						if rule == event.prev {
							delete(rule)
							rule = event.cur
							break
						}
					}
				}
				mixologist_config_write(&mixologist)
			case Volume:
				log.debugf("setting volume: %v", event)
				mixologist.volume = event
				def_vol, aux_vol := daemon_sink_volumes(mixologist.volume)
				sink_set_volume(&mixologist.daemon.default_sink, def_vol)
				sink_set_volume(&mixologist.daemon.aux_sink, aux_vol)
			}
			mixologist.gui.ui_ctx.statuses += {.DIRTY}
		}
		clear(&mixologist.events)

		free_all(context.temp_allocator)
	}

	if .Daemon in mixologist.statuses {
		daemon_deinit(&mixologist.daemon)
	}

	if .Gui in mixologist.statuses {
		gui_deinit(&mixologist.gui)
	}

	// clean up inotify
	{
		err := linux.inotify_rm_watch(mixologist.fd, mixologist.wd)
		assert(err == nil)
	}
}

mixologist_ipc_messages :: proc(mixologist: ^Mixologist) {
	for ipc_msg in mixologist.ipc.messages {
		sender := ipc_msg.sender
		msg: common.Message
		cbor.unmarshal(string(ipc_msg.msg_bytes), &msg) or_continue

		switch msg in msg {
		case common.Volume:
			switch msg.act {
			case .Get:
				log.debugf("getting volume %v: socket %v", msg.val, sender)
				vol := common.Volume {
					act = .Get,
					val = mixologist.volume,
				}
				IPC_Server_send(&mixologist.ipc, sender, vol)
			case .Set:
				log.debugf("setting volume %v: socket %v", msg.val, sender)
				vol := clamp(msg.val, -1, 1)
				append(&mixologist.events, vol)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			case .Shift:
				log.debugf("shifting volume %v: socket %v", msg.val, sender)
				vol := mixologist.volume + msg.val
				vol = clamp(vol, -1, 1)
				append(&mixologist.events, vol)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			case .Subscribe:
				log.debugf("subscribing volume: socket %v", sender)
				IPC_Server_add_volume_subscriber(&mixologist.ipc, sender)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			}

			default, aux := daemon_sink_volumes(mixologist.volume)
			sink_set_volume(&mixologist.daemon.default_sink, default)
			sink_set_volume(&mixologist.daemon.aux_sink, aux)
		case common.Program:
			switch msg.act {
			case .Add:
				log.infof("adding program %s", msg.val)
				append(&mixologist.events, Rule_Add(msg.val))
			// [TODO] implement program subscriptions
			case .Remove:
				log.infof("removing program %s", msg.val)
				append(&mixologist.events, Rule_Remove(msg.val))
			// [TODO] implement program subscriptions
			case .Subscribe:
				IPC_Server_add_program_subscriber(&mixologist.ipc, sender)
				unimplemented("program subscriptions")
			// [TODO] implement program subscriptions
			}
		case common.Wake:
			if .Gui in mixologist.statuses {
				UI_open_window(&mixologist.gui.ui_ctx)
			}
		}
	}
}

mixologist_config_load :: proc(mixologist: ^Mixologist) {
	config_path, _ := os2.join_path(
		{mixologist.config_dir, CONFIG_FILENAME},
		context.temp_allocator,
	)
	config_data, read_err := os2.read_entire_file(config_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("could not read config file: %v, err: %v", config_path, read_err)
		return
	}

	json_err := json.unmarshal(config_data, &mixologist.config)
	if json_err != nil {
		log.errorf("could not unmarshal config file: %v", json_err)
		return
	}

	#reverse for rule, idx in mixologist.config.rules {
		if len(rule) == 0 {
			delete(rule)
			ordered_remove(&mixologist.config.rules, idx)
		} else {
			daemon_add_program(&mixologist.daemon, rule)
		}
	}
}

mixologist_config_clear :: proc(mixologist: ^Mixologist) {
	for rule in mixologist.config.rules {
		daemon_remove_program(&mixologist.daemon, rule)
		delete(rule)
	}
	delete(mixologist.config.rules)
	mixologist.config.rules = [dynamic]string{}
}

mixologist_config_write :: proc(mixologist: ^Mixologist) {
	config_path, _ := os2.join_path(
		{mixologist.config_dir, CONFIG_FILENAME},
		context.temp_allocator,
	)

	config_json, json_err := json.marshal(
		mixologist.config,
		{pretty = true},
		allocator = context.temp_allocator,
	)
	if json_err != nil {
		log.errorf("could not marshal json: %v", json_err)
		return
	}
	write_err := os2.write_entire_file(config_path, config_json)
	if write_err != nil {
		log.errorf("could not write to file: %v, err: %v", config_path, write_err)
	}
}

mixologist_config_reload :: proc(mixologist: ^Mixologist) {
	mixologist_config_clear(mixologist)
	mixologist_config_load(mixologist)
}
