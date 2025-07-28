package mixologist

import "../dbus"
import "base:runtime"
import "core:encoding/cbor"
import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:thread"
import "core:time"

Mixologist :: struct {
	// state
	features:     Features,
	events:       chan.Chan(Event),
	config_mutex: sync.Mutex,
	// ipc
	ipc:          IPC_Server_Context,
	shortcuts:    GlobalShortcuts_Session,
	// config
	config_dir:   string,
	cache_dir:    string,
	volume_file:  string,
	config:       Config,
	volume:       f32,
	// atomic
	exit:         bool,
}

Config :: struct {
	rules:    [dynamic]string,
	settings: Settings,
}

Settings :: struct {
	volume_falloff:  Volume_Falloff,
	start_minimized: bool,
	remember_volume: bool,
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

Features :: bit_set[Feature]
Feature :: enum {
	GlobalShortcuts,
	Daemon,
	Gui,
}

Event :: union {
	Rule_Add,
	Rule_Remove,
	Rule_Update,
	Program_Add,
	Program_Remove,
	Volume_Event,
	Settings,
	Open,
}
Rule_Add :: distinct string
Rule_Remove :: distinct string
Program_Add :: distinct string
Program_Remove :: distinct string
Rule_Update :: struct {
	prev: string,
	cur:  string,
}
Volume_Event :: f32
Open :: distinct rawptr

mixologist: Mixologist
cli: CLI_State

when ODIN_DEBUG {
	track: mem.Tracking_Allocator
}

main :: proc() {
	// set up data file locations
	{
		user_config_dir :=
			os2.user_config_dir(context.allocator) or_else log.panic(
				"could not get user config dir",
			)
		mixologist.config_dir =
			os2.join_path({user_config_dir, "mixologist"}, context.allocator) or_else log.panic(
				"could not create config path",
			)
		mixologist.cache_dir =
			os2.user_cache_dir(context.allocator) or_else log.panic("could not get user cache dir")
		mixologist.volume_file =
			os2.join_path(
				{mixologist.cache_dir, "mixologist.volume"},
				context.allocator,
			) or_else log.panic("could not create volume path")
	}

	when ODIN_DEBUG {
		context.logger = log.create_console_logger(
			get_log_level(),
			log.Default_Console_Logger_Opts + {.Thread_Id},
		)
		defer log.destroy_console_logger(context.logger)

		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			for _, leak in track.allocation_map {
				if strings.contains(leak.location.file_path, "mixologist") {
					log.warnf("%v leaked %m\n", leak.location, leak.size)
				}
			}
		}
	} else {
		log_path :=
			os2.join_path(
				{mixologist.cache_dir, "mixologist.log"},
				context.allocator,
			) or_else log.panic("could not create log path")

		open_flags := os2.File_Flags{.Write, .Create}
		TRUNC_THRESHOLD :: 1024 * 1024 // 1MB

		if os2.exists(log_path) {
			log_info, stat_err := os2.stat(log_path, context.allocator)
			defer os2.file_info_delete(log_info, context.allocator)

			if stat_err != nil && log_info.size > TRUNC_THRESHOLD {
				open_flags += {.Trunc}
			} else if log_info.size <= TRUNC_THRESHOLD {
				open_flags += {.Append}
			}
		}

		log_file := os2.open(log_path, open_flags) or_else log.panic("could not access log file")
		context.logger = create_file_logger(
			log_file,
			get_log_level(),
			log.Default_File_Logger_Opts + {.Thread_Id},
		)
		defer destroy_file_logger(context.logger)
	}

	flags.register_flag_checker(flag_checker)
	flags.parse_or_exit(&cli.opts, os2.args, .Odin)
	if cli.opts.daemon {
		mixologist.features += {.Daemon}
	} else if !cli.option_sel {
		mixologist.features += {.Daemon, .Gui}
	} else {
		cli_messages(cli)
		return
	}

	ipc_start_err := IPC_Server_init(&mixologist.ipc)
	if ipc_start_err != nil {
		fmt.println("detected active mixologist instance, sending wake command")
		msg: Message = Wake{}
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
		mixologist.features += {.GlobalShortcuts}
		GlobalShortcuts_CreateSession(&mixologist.shortcuts)
		listed_shortcuts, _ := GlobalShortcuts_ListShortcuts(&mixologist.shortcuts)
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
	mixologist_config_read(&mixologist)

	if mixologist.config.settings.remember_volume {
		mixologist_read_volume_file(&mixologist)
	}
	mixologist.events, _ = chan.create(chan.Chan(Event), 128, context.allocator)

	// init app state
	if .Daemon in mixologist.features {
		daemon_thread = thread.create_and_start_with_poly_data(&daemon, daemon_proc, context)
	}

	if .Gui in mixologist.features {
		gui_thread = thread.create_and_start_with_poly_data(&gui, gui_proc, context)
	}

	for !mixologist_should_exit() {
		// ipc
		IPC_Server_poll(&mixologist.ipc)
		mixologist_ipc_messages(&mixologist)

		if .GlobalShortcuts in mixologist.features {
			Portals_Tick(mixologist.shortcuts.conn)
		}
		mixologist_event_process(&mixologist)
		time.sleep(16 * time.Millisecond)
		free_all(context.temp_allocator)
	}

	log.infof("main event loop exiting")
	if .Daemon in mixologist.features {
		daemon_signal_stop(&daemon)
		thread.join(daemon_thread)
	}

	if .Gui in mixologist.features {
		thread.join(gui_thread)
	}

	if .GlobalShortcuts in mixologist.features {
		GlobalShortcuts_CloseSession(&mixologist.shortcuts)
		GlobalShortcuts_Deinit(&mixologist.shortcuts)
	}

	IPC_Server_deinit(&mixologist.ipc)

	// clean up allocated memory
	{
		for event in chan.try_recv(mixologist.events) {
			#partial switch event in event {
			// delete the results of `node_destroy` events
			// called during pipewire cleanup
			case Program_Remove:
				delete(string(event))
			}
		}
		chan.destroy(mixologist.events)
		for rule in mixologist.config.rules {
			delete(rule)
		}
		delete(mixologist.config.rules)
	}
}

mixologist_event_process :: proc(mixologist: ^Mixologist) {
	for event in chan.try_recv(mixologist.events) {
		#partial switch event in event {
		case Rule_Add:
			log.debugf("adding rule: %v", event)
			daemon_add_program(&daemon, string(event))
			if sync.mutex_guard(&mixologist.config_mutex) {
				append(&mixologist.config.rules, string(event))
			}
			mixologist_config_write(mixologist)
		case Rule_Remove:
			log.debugf("removing rule: %v", event)
			daemon_remove_program(&daemon, string(event))
			if sync.mutex_guard(&mixologist.config_mutex) {
				#reverse for rule, idx in mixologist.config.rules {
					if rule == string(event) {
						delete(rule)
						ordered_remove(&mixologist.config.rules, idx)
						break
					}
				}
			}
			mixologist_config_write(mixologist)
		case Rule_Update:
			if len(event.cur) == 0 {
				log.debugf("updating to zero-length rule: %v", event.prev)
				daemon_remove_program(&daemon, event.prev)
				if sync.mutex_guard(&mixologist.config_mutex) {
					for rule, idx in mixologist.config.rules {
						if rule == event.prev {
							delete(rule)
							delete(event.cur)
							ordered_remove(&mixologist.config.rules, idx)
							break
						}
					}
				}
			} else {
				log.debugf("updating rule: %v -> %v", event.prev, event.cur)
				daemon_remove_program(&daemon, event.prev)
				daemon_add_program(&daemon, event.cur)
				if sync.mutex_guard(&mixologist.config_mutex) {
					for &rule in mixologist.config.rules {
						if rule == event.prev {
							delete(rule)
							rule = event.cur
							break
						}
					}
				}
			}
			mixologist_config_write(mixologist)
		case Volume_Event:
			log.debugf("setting volume: %v", event)
			mixologist.volume = event
			mixologist.volume = clamp(mixologist.volume, -1, 1)
			def_vol, aux_vol := daemon_sink_volumes(mixologist.volume)
			volumes := [2]f32{def_vol, aux_vol}
			daemon_set_volumes(&daemon, volumes)
			if .Gui in mixologist.features {
				gui_event_send(Volume_Event{})
			}
			mixologist_write_volume_file(mixologist)
		case Settings:
			log.debugf("settings changed: %v", event)
			if sync.mutex_guard(&mixologist.config_mutex) {
				mixologist.config.settings = event
			}
			mixologist_config_write(mixologist)
		}
	}
}

mixologist_event_send :: proc(event: Event) {
	log.debugf("mixologist sending event: %v", event)
	chan.send(mixologist.events, event)
}

mixologist_ipc_messages :: proc(mixologist: ^Mixologist) {
	for ipc_msg in mixologist.ipc.messages {
		sender := ipc_msg.sender
		msg: Message
		cbor.unmarshal(string(ipc_msg.msg_bytes), &msg) or_continue

		switch msg in msg {
		case Volume:
			switch msg.act {
			case .Get:
				log.debugf("getting volume %v: socket %v", msg.val, sender)
				vol := Volume {
					act = .Get,
					val = mixologist.volume,
				}
				IPC_Server_send(&mixologist.ipc, sender, vol)
			case .Set:
				log.debugf("setting volume %v: socket %v", msg.val, sender)
				mixologist_event_send(msg.val)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			case .Shift:
				log.debugf("shifting volume %v: socket %v", msg.val, sender)
				vol := mixologist.volume + msg.val
				mixologist_event_send(vol)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			case .Subscribe:
				log.debugf("subscribing volume: socket %v", sender)
				IPC_Server_add_volume_subscriber(&mixologist.ipc, sender)
				IPC_Server_notify_volume_subscription(&mixologist.ipc, mixologist.volume)
			}

			default, aux := daemon_sink_volumes(mixologist.volume)
			volumes := [2]f32{default, aux}
			daemon_set_volumes(&daemon, volumes)
		case Program:
			switch msg.act {
			case .Add:
				log.infof("adding program %s", msg.val)
				mixologist_event_send(Rule_Add(msg.val))
			// [TODO] implement program subscriptions
			case .Remove:
				log.infof("removing program %s", msg.val)
				mixologist_event_send(Rule_Remove(msg.val))
			// [TODO] implement program subscriptions
			case .Subscribe:
				IPC_Server_add_program_subscriber(&mixologist.ipc, sender)
				unimplemented("program subscriptions")
			// [TODO] implement program subscriptions
			}
		case Wake:
			if .Gui in mixologist.features {
				gui_event_send(Open{})
			}
		}
	}
}

mixologist_config_read :: proc(mixologist: ^Mixologist) {
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
			mixologist_event_send(vol)
		case .LOWER:
			vol := mixologist.volume - 0.1
			mixologist_event_send(vol)
		case .MAX:
			mixologist_event_send(1)
		case .MIN:
			mixologist_event_send(-1)
		case .RESET:
			mixologist_event_send(0)
		}
		return .HANDLED
	}
	return .NOT_YET_HANDLED
}

mixologist_read_volume_file :: proc(mixologist: ^Mixologist) {
	if os2.exists(mixologist.volume_file) {
		volume_bytes, volume_err := os2.read_entire_file(mixologist.volume_file, context.allocator)
		if volume_err != nil {
			log.errorf("could not read volume file: %s", volume_err)
		} else {
			volume, volume_parse_ok := strconv.parse_f32(string(volume_bytes))
			if !volume_parse_ok {
				log.errorf("could not parse volume")
			} else {
				mixologist.volume = volume
			}
		}
	}
}

mixologist_write_volume_file :: proc(mixologist: ^Mixologist) {
	volume_buf: [312]byte
	volume_string := fmt.bprintf(volume_buf[:], "%f", mixologist.volume)
	err := os2.write_entire_file(mixologist.volume_file, transmute([]u8)volume_string)
	if err != nil {
		log.errorf("could not write volume file: %s", err)
	}
}

mixologist_should_exit :: proc() -> bool {
	return sync.atomic_load(&mixologist.exit)
}

mixologist_signal_exit :: proc(caller_loc := #caller_location) {
	log.infof("mixologist signaling exit by %v", caller_loc)
	sync.atomic_store(&mixologist.exit, true)
}
