package mixologist

import "../common"
import "../dbus"
import "base:runtime"
import "core:encoding/cbor"
import "core:encoding/json"
import "core:flags"
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
	shortcuts:  GlobalShortcuts_Session,
	// config
	config_dir: string,
	config:     Config,
	volume:     f32,
}

Config :: struct {
	rules:           [dynamic]string,
	start_minimized: bool,
}

Shortcut :: enum {
	RAISE,
	LOWER,
	RESET,
	MAX,
	MIN,
}

Shortcut_Info := [Shortcut]GlobalShortcut {
	.RAISE = {id = "raise", description = "favor selected", trigger_description = "SHIFT+F12"},
	.LOWER = {id = "lower", description = "favor system", trigger_description = "SHIFT+F11"},
	.RESET = {id = "reset", description = "reset", trigger_description = "SHIFT+F10"},
	.MAX = {id = "max", description = "isolate selected", trigger_description = "ALT+SHIFT+F12"},
	.MIN = {id = "min", description = "isolate system", trigger_description = "ALT+SHIFT+F11"},
}

shortcut_from_str :: proc(input: string) -> Shortcut {
	switch input {
	case "raise":
		return .RAISE
	case "lower":
		return .LOWER
	case "reset":
		return .RESET
	case "max":
		return .MAX
	case "min":
		return .MIN
	case:
		log.panic("invalid shortcut id")
	}
}

CONFIG_FILENAME :: "mixologist.json"

Statuses :: bit_set[Status]
Status :: enum {
	GlobalShortcuts,
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
cli: CLI_State

main :: proc() {
	context.logger = log.create_console_logger(common.get_log_level())
	defer log.destroy_console_logger(context.logger)

	flags.register_flag_checker(flag_checker)
	flags.parse_or_exit(&cli.opts, os2.args, .Odin)
	if cli.opts.daemon {
		mixologist.statuses += {.Daemon}
	} else if !cli.option_sel {
		mixologist.statuses += {.Daemon, .Gui}
	} else {
		cli_messages(cli)
		return
	}

	// set up inotify
	{
		base_dir, _ := os2.user_config_dir(context.allocator)
		mixologist.config_dir, _ = os2.join_path({base_dir, "mixologist"}, context.allocator)
		if !os2.exists(mixologist.config_dir) do os2.make_directory(mixologist.config_dir)

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
		msg: common.Message = common.Wake{}
		send_message(msg)
		return
	}

	// configure global shortcuts
	gs_err := GlobalShortcuts_Init(
		&mixologist.shortcuts,
		"dev.cstring.Mixologist",
		"mixologist",
		{.ACTIVATED},
		mixologist_globalshortcuts_handler,
		nil,
		nil,
	)
	switch gs_err in gs_err {
	case nil:
		mixologist.statuses += {.GlobalShortcuts}
		GlobalShortcuts_CreateSession(&mixologist.shortcuts)
		listed_shortcuts, _ := GlobalShortcuts_ListShortcuts(&mixologist.shortcuts)
		all_shortcuts_bound := true
		for shortcut in Shortcut_Info {
			found := false
			for listed_shortcut in listed_shortcuts {
				if listed_shortcut.id == shortcut.id do found = true
			}
			if !found {
				fmt.println(shortcut)
				all_shortcuts_bound = false
				break
			}
		}
		GlobalShortcuts_SliceDelete(listed_shortcuts)
		if !all_shortcuts_bound {
			shortcuts: [len(Shortcut_Info)]GlobalShortcut
			for shortcut, idx in Shortcut_Info {
				shortcuts[idx] = shortcut
			}
			bound_shortcuts, _ := GlobalShortcuts_BindShortcuts(
				&mixologist.shortcuts,
				shortcuts[:],
			)
			GlobalShortcuts_SliceDelete(bound_shortcuts)
		}
	case cstring:
		log.errorf("could not initialize global shortcuts: %s", gs_err)
	}

	// config loading
	mixologist_config_load(&mixologist)

	// init app state
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

		if .GlobalShortcuts in mixologist.statuses {
			Portals_Tick(mixologist.shortcuts.conn)
		}

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

	if .GlobalShortcuts in mixologist.statuses {
		GlobalShortcuts_CloseSession(&mixologist.shortcuts)
		GlobalShortcuts_Deinit(&mixologist.shortcuts)
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

mixologist_globalshortcuts_handler :: proc "c" (
	connection: ^dbus.Connection,
	msg: ^dbus.Message,
	user_data: rawptr,
) -> dbus.HandlerResult {
	context = runtime.default_context()
	interface := cstring("org.freedesktop.portal.GlobalShortcuts")
	if dbus.message_is_signal(msg, interface, "Activated") {
		msg_iter: dbus.MessageIter
		dbus.message_iter_init(msg, &msg_iter)

		session_handle: cstring
		dbus.message_iter_get_basic(&msg_iter, &session_handle)
		dbus.message_iter_next(&msg_iter)

		shortcut_id_cstr: cstring
		dbus.message_iter_get_basic(&msg_iter, &shortcut_id_cstr)
		dbus.message_iter_next(&msg_iter)
		shortcut_id := shortcut_from_str(string(shortcut_id_cstr))
		switch shortcut_id {
		case .RAISE:
			vol := mixologist.volume + 0.1
			append(&mixologist.events, vol)
		case .LOWER:
			vol := mixologist.volume - 0.1
			append(&mixologist.events, vol)
		case .MAX:
			append(&mixologist.events, 1)
		case .MIN:
			append(&mixologist.events, -1)
		case .RESET:
			append(&mixologist.events, 0)
		}
	}
	return .HANDLED
}
