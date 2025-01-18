package mixologist_daemon

import "../common"
import pw "../pipewire"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:text/match"
import "core:time"

EVENT_SIZE :: size_of(linux.Inotify_Event)
EVENT_BUF_LEN :: 1024 * (EVENT_SIZE + 16)

Context :: struct {
	// config state
	config_file:       string,
	cache_file:        string,
	inotify_fd:        linux.Fd,
	inotify_wd:        linux.Wd,
	// pipewire required state
	main_loop:         ^pw.thread_loop,
	loop:              ^pw.loop,
	core:              ^pw.core,
	pw_context:        ^pw.pw_context,
	registry:          ^pw.registry,
	registry_listener: pw.spa_hook,
	pw_odin_ctx:       runtime.Context,
	// sinks
	default_sink:      Sink,
	aux_sink:          Sink,
	aux_rules:         [dynamic]string,
	device_inputs:     map[string]Link,
	passthrough_nodes: map[u32]Node,
	passthrough_ports: [dynamic]u32,
	vol:               f32,
	// allocations
	arena:             virtual.Arena,
	allocator:         mem.Allocator,
	// control flow/ipc state
	should_exit:       bool,
	ipc_server:        IPC_Server_Context,
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				log.errorf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					log.errorf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				log.errorf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					log.errorf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	// initialize context
	ctx: Context
	if virtual.arena_init_growing(&ctx.arena) != nil {
		panic("Couldn't initialize arena")
	}
	ctx.allocator = virtual.arena_allocator(&ctx.arena)
	ctx.aux_rules = make([dynamic]string, 0, DEFAULT_ARR_CAPACITY, ctx.allocator)
	ctx.device_inputs = make(map[string]Link, DEFAULT_MAP_CAPACITY, ctx.allocator)
	ctx.passthrough_nodes = make(map[u32]Node, DEFAULT_MAP_CAPACITY, ctx.allocator)
	ctx.passthrough_ports = make([dynamic]u32, DEFAULT_ARR_CAPACITY, ctx.allocator)
	ctx.pw_odin_ctx = runtime.default_context()

	// set up logging
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(lowest = common.get_log_level())
		defer log.destroy_console_logger(context.logger)
		ctx.pw_odin_ctx.logger = log.create_console_logger(lowest = common.get_log_level())
		defer log.destroy_console_logger(ctx.pw_odin_ctx.logger)
	} else {
		cache_dir := os2.user_cache_dir(ctx.allocator) or_else panic("cache dir not found")
		log_path := strings.concatenate(
			{cache_dir, os2.Path_Separator_String, "mixd.log"},
			ctx.allocator,
		)
		rm_err := os2.remove(log_path)
		assert(rm_err != nil || rm_err != .Not_Exist)

		log_file, err := os2.create(log_path)
		assert(err == nil)

		context.logger = create_file_logger(log_file, lowest = common.get_log_level())
		defer destroy_file_logger(context.logger)
		ctx.pw_odin_ctx.logger = create_file_logger(log_file, lowest = common.get_log_level())
		defer destroy_file_logger(ctx.pw_odin_ctx.logger)
	}

	// set up ipc
	{
		retry_delay_seconds := time.Duration(1)
		max_retry_count := 5
		for retry_count in 0 ..< max(int) {
			bind_err := IPC_Server_init(&ctx.ipc_server)
			if bind_err != nil && retry_count == max_retry_count {
				log.panicf("could not bind socket %v", bind_err)
			} else if bind_err != nil {
				log.errorf(
					"could not bind socket %v, waiting %v seconds to try again. is mixd already running?",
					bind_err,
					retry_delay_seconds * time.Second,
				)
				time.sleep(retry_delay_seconds * time.Second)
				retry_delay_seconds *= 2
			} else {
				break
			}
		}
	}

	// initialize pipewire
	{
		pw.init(nil, nil)

		log.log(
			.Info,
			"Using Pipewire library version:",
			pw.get_library_version(),
			"with client name:",
			pw.get_client_name(),
		)

		ctx.main_loop = pw.thread_loop_new("main", nil)

		pw.thread_loop_lock(ctx.main_loop)
		ctx.loop = pw.thread_loop_get_loop(ctx.main_loop)
		ctx.pw_context = pw.context_new(ctx.loop, nil, 0)

		ctx.core = pw.context_connect(ctx.pw_context, nil, 0)

		ctx.registry = pw.core_get_registry(ctx.core, pw.VERSION_REGISTRY, 0)
		pw.registry_add_listener(ctx.registry, &ctx.registry_listener, &registry_events, &ctx)

		// load saved volume data from disk
		{
			cache_dir := os2.user_cache_dir(ctx.allocator) or_else panic("cache dir not found")
			ctx.cache_file = strings.concatenate(
				{cache_dir, os2.Path_Separator_String, "mixologist.volumes"},
				ctx.allocator,
			)
			file_bytes, cache_file_err := os2.read_entire_file(ctx.cache_file, ctx.allocator)

			if cache_file_err == nil {
				file_string := string(file_bytes)
				ctx.vol, _ = strconv.parse_f32(file_string)
				log.logf(.Info, "set volume to: %f", ctx.vol)
			} else {
				log.logf(.Info, "could not find saved volumes, using default")
			}
		}

		default_volume, aux_volume := sink_vols_from_ctx_vol(ctx.vol)
		sink_init(
			&ctx.default_sink,
			"mixologist-default",
			default_volume,
			ctx.pw_context,
			&ctx.arena,
		)
		sink_init(&ctx.aux_sink, "mixologist-aux", aux_volume, ctx.pw_context, &ctx.arena)
	}

	// load config rules from disk
	{
		config_dir := os2.user_config_dir(ctx.allocator) or_else panic("config dir not found")
		config_dir = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist"},
			ctx.allocator,
		)
		if !os2.exists(config_dir) {
			os2.mkdir(config_dir)
		}

		ctx.config_file = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist.conf"},
			ctx.allocator,
		)

		reload_config(&ctx)

		// set up config file watch
		{
			in_err: linux.Errno
			ctx.inotify_fd, in_err = linux.inotify_init1({.NONBLOCK})
			assert(in_err == nil)
			ctx.inotify_wd, in_err = linux.inotify_add_watch(
				ctx.inotify_fd,
				strings.clone_to_cstring(config_dir, ctx.allocator),
				{.CREATE, .DELETE, .MODIFY} + linux.IN_MOVE,
			)
			assert(in_err == nil)
		}
	}

	setup_exit_handlers(&ctx)
	pw.thread_loop_start(ctx.main_loop)

	event_loop: for !ctx.should_exit {
		free_all(context.temp_allocator)

		time: linux.Time_Spec
		pw.thread_loop_get_time(ctx.main_loop, &time, 1e7)
		pw.thread_loop_timed_wait_full(ctx.main_loop, &time)

		// rule reloading
		{
			inotify_buf: [EVENT_BUF_LEN]u8
			length, read_err := linux.read(ctx.inotify_fd, inotify_buf[:])
			assert(read_err == nil || read_err == .EAGAIN)

			config_modified := false
			for i := 0; i < length; {
				event := cast(^linux.Inotify_Event)&inotify_buf[i]

				if inotify_event_name(event) == "mixologist.conf" {
					config_modified = true
					break
				}

				i += EVENT_SIZE + int(event.len)
			}

			if config_modified {
				reload_config(&ctx)
			}
		}

		IPC_Server_poll(&ctx.ipc_server, &ctx)
	}

	free_all(context.allocator)

	pw.thread_loop_unlock(ctx.main_loop)
	pw.thread_loop_stop(ctx.main_loop)

	// pipewire cleanup
	{
		reset_links(&ctx)
		sink_destroy(&ctx.aux_sink)
		sink_destroy(&ctx.default_sink)
		pw.proxy_destroy(cast(^pw.proxy)ctx.registry)
		pw.core_disconnect(ctx.core)
		pw.context_destroy(ctx.pw_context)
		pw.thread_loop_destroy(ctx.main_loop)
		pw.deinit()
	}

	// inotify cleanup
	{
		err := linux.inotify_rm_watch(ctx.inotify_fd, ctx.inotify_wd)
		assert(err == nil)
	}

	// ipc cleanup
	IPC_Server_deinit(&ctx.ipc_server)

	// ctx cleanup
	for rule in ctx.aux_rules {
		delete(rule)
	}
	free_all(ctx.allocator)
}

// this relies on terrible undefined behavior
// but allows us to avoid using sigqueue or globals
setup_exit_handlers :: proc(ctx: ^Context) {
	do_quit_with_data(.SIGUSR1, ctx)
	posix.signal(.SIGINT, transmute(proc "c" (_: posix.Signal))do_quit_with_data)
	posix.signal(.SIGTERM, transmute(proc "c" (_: posix.Signal))do_quit_with_data)
}

do_quit_with_data :: proc "c" (signum: posix.Signal, data: rawptr) {
	@(static) ctx: ^Context
	if ctx == nil {
		ctx = cast(^Context)data
		return
	}
	pw.thread_loop_signal(ctx.main_loop, false)
	ctx.should_exit = true
}

registry_events := pw.registry_events {
	version       = pw.VERSION_REGISTRY_EVENTS,
	global_add    = global_add,
	global_remove = global_destroy,
}

global_add :: proc "c" (
	data: rawptr,
	id: u32,
	permissions: u32,
	type: cstring,
	version: u32,
	props: ^pw.spa_dict,
) {
	ctx := cast(^Context)data
	context = ctx.pw_odin_ctx

	switch type {
	case "PipeWire:Interface:Node":
		node_handler(ctx, id, version, type, props)
	case "PipeWire:Interface:Port":
		port_handler(ctx, id, version, props)
	case "PipeWire:Interface:Link":
		link_handler(ctx, id, version, props)
	}

	rebuild_connections(ctx)
	free_all(context.temp_allocator)
}

global_destroy :: proc "c" (data: rawptr, id: u32) {
	ctx := cast(^Context)data
	context = ctx.pw_odin_ctx

	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}

	for sink in sinks {
		associated_node, node_exists := &sink.associated_nodes[id]
		if node_exists {
			node_destroy(associated_node)
			delete_key(&sink.associated_nodes, id)
		} else {
			#reverse for &link, idx in sink.links {
				if link.id == id {
					link_destroy(&link)
					unordered_remove(&sink.links, idx)
				}
			}
		}
	}
}

check_name :: proc(name: string, checks: []string) -> bool {
	for check in checks {
		matcher := match.matcher_init(name, check)
		match_result, match_ok := match.matcher_match(&matcher)
		if match_ok && len(match_result) == len(name) {
			return true
		}
	}
	return false
}

node_handler :: proc(ctx: ^Context, id, version: u32, type: cstring, props: ^pw.spa_dict) {
	node_name := pw.spa_dict_get(props, "node.name")
	log.logf(.Debug, "Attempting to add node name %s", node_name)
	if node_name == "output.mixologist-default" {
		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node: Node
		name_str := strings.clone_from_cstring(node_name)
		node_init(&node, proxy, props, name_str, ctx.allocator)
		ctx.default_sink.loopback_node = node
		log.logf(.Info, "registered default node with id %d", id)
	} else if node_name == "output.mixologist-aux" {
		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node: Node
		name_str := strings.clone_from_cstring(node_name)
		node_init(&node, proxy, props, name_str, ctx.allocator)
		ctx.aux_sink.loopback_node = node
		log.logf(.Info, "registered aux node with id %d", id)
	} else {
		application_name := pw.spa_dict_get(props, "application.name")
		media_class := pw.spa_dict_get(props, "media.class")
		if application_name == nil && media_class == nil {
			log.logf(.Info, "could not find application name for node with id %d", id)
			return
		}
		if media_class == "Audio/Source/Virtual" {
			proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
			node: Node
			name_str := strings.clone_from_cstring(node_name)
			node_init(&node, proxy, props, name_str, ctx.allocator)
			ctx.passthrough_nodes[id] = node
			return
		} else if media_class != "Stream/Output/Audio" {
			return
		}

		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node: Node
		name_str := strings.clone_from_cstring(node_name)
		node_init(&node, proxy, props, name_str, ctx.allocator)
		if check_name(string(application_name), ctx.aux_rules[:]) {
			ctx.aux_sink.associated_nodes[id] = node
		} else {
			ctx.default_sink.associated_nodes[id] = node
		}
		log.logf(.Info, "Registered application node of id %d and name %s", id, application_name)
	}
}

port_handler :: proc(ctx: ^Context, id, version: u32, props: ^pw.spa_dict) {
	path := pw.spa_dict_get(props, "object.path")
	assert(path != nil)
	cstr_channel := pw.spa_dict_get(props, "audio.channel")
	if cstr_channel == nil {return}

	if strings.starts_with(string(path), "input.mixologist-default:playback") {
		channel := strings.clone_from_cstring(cstr_channel)
		_, _, found := map_upsert(&ctx.default_sink.loopback_node.ports, channel, id)
		log.logf(.Info, "def port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else if strings.starts_with(string(path), "input.mixologist-aux:playback") {
		channel := strings.clone_from_cstring(cstr_channel)
		_, _, found := map_upsert(&ctx.aux_sink.loopback_node.ports, channel, id)
		log.logf(.Info, "aux port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else if strings.starts_with(string(path), "output.mixologist-default:output") ||
	   strings.starts_with(string(path), "output.mixologist-aux:output") {
		channel := strings.clone_from_cstring(cstr_channel)
		_, _, found := map_upsert(&ctx.device_inputs, channel, Link{src = id})
		log.logf(.Info, "output port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else {
		sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}
		node_id := pw.spa_dict_get(props, "node.id")
		if node_id == nil {return}

		node_id_uint, parse_ok := strconv.parse_uint(string(node_id))
		assert(parse_ok)
		node_id_u32 := u32(node_id_uint)

		passthrough, is_passthrough := &ctx.passthrough_nodes[node_id_u32]
		if is_passthrough {
			append(&ctx.passthrough_ports, id)
			log.logf(.Info, "passthrough port %d registered for node %s", id, passthrough.name)
			return
		}

		port_direction := pw.spa_dict_get(props, "port.direction")
		if port_direction == nil || port_direction == "in" {
			for sink in sinks {
				if associated_node, node_exists := &sink.associated_nodes[node_id_u32];
				   node_exists {
					node_destroy(associated_node)
					delete_key(&sink.associated_nodes, node_id_u32)
				}
			}
			return
		}

		for sink, idx in sinks {
			associated_node, node_exists := &sink.associated_nodes[node_id_u32]
			if !node_exists {continue}

			port_name := pw.spa_dict_get(associated_node.props, "port.name")
			if !strings.starts_with(string(port_name), "output_") {
				log.logf(.Info, "skipping port name %s", port_name)
				return
			}

			channel := strings.clone_from_cstring(cstr_channel)
			_, _, found := map_upsert(&associated_node.ports, channel, id)
			if found do delete(channel)
			log.logf(.Info, "output port %d registered to sink %d", id, idx)
		}
	}
}

link_handler :: proc(ctx: ^Context, id, version: u32, props: ^pw.spa_dict) {
	src_node, _ := spa_dict_get_u32(props, "link.output.node")
	src_port, _ := spa_dict_get_u32(props, "link.output.port")
	dest_port, _ := spa_dict_get_u32(props, "link.input.port")

	// skip passthrough nodes
	for port_id in ctx.passthrough_ports {
		if port_id == dest_port {
			log.debugf(
				"Skipping passthrough link with src id: %d, routing %d -> %d",
				src_node,
				src_port,
				dest_port,
			)
			return
		}
	}

	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}
	for sink, idx in sinks {
		associated_node, node_exists := sink.associated_nodes[src_node]
		if !node_exists {
			for _, &link in ctx.device_inputs {
				if link.src == src_port {
					link.dest = dest_port
					break
				}
			}
			continue
		}

		log.logf(
			.Debug,
			"found source from %d group from node %d with id %d, prospective ports: %d -> %d",
			idx,
			src_node,
			id,
			src_port,
			dest_port,
		)

		link_channel: string
		for channel, port_id in associated_node.ports {
			if port_id == src_port {
				link_channel = channel
			}
		}

		expected_dest_port := sink.loopback_node.ports[link_channel]
		link_correct := expected_dest_port == dest_port
		if !link_correct {
			pw.registry_destroy(ctx.registry, id)
			log.logf(.Info, "added mapping for %d -> %d", src_port, expected_dest_port)
			append(&sink.links, Link{src = src_port})
		} else {
			for &link in sink.links {
				if link.src == src_port && link.dest == dest_port {
					log.logf(.Info, "setting link id %d", id)
					link.id = id
				}
			}
		}
	}
}

rebuild_connections :: proc(ctx: ^Context) {
	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}
	for sink in sinks {
		if sink.loopback_node.proxy == nil {continue}

		for _, node in sink.associated_nodes {
			for channel, n_port in node.ports {
				lb_port := sink.loopback_node.ports[channel]
				if lb_port == 0 {continue}

				for &link in sink.links {
					if link.src == n_port && link.dest == 0 {
						log.logf(.Info, "connecting link %d -> %d", n_port, lb_port)
						link.dest = lb_port
						link_connect(&link, ctx.core)
					}
				}
			}
		}

		sink_set_volume(sink, sink.volume)
	}
}

sink_vols_from_ctx_vol :: proc(vol: f32) -> (def, aux: f32) {
	return vol < 0 ? 1 : 1 - vol, vol > 0 ? 1 : vol + 1
}

add_program :: proc(ctx: ^Context, program: string) {
	log.logf(.Info, "adding program %s", program)
	append(&ctx.aux_rules, program)

	for id, node in ctx.default_sink.associated_nodes {
		if !check_name(node.name, {program}) {continue}
		k, v := delete_key(&ctx.default_sink.associated_nodes, id)
		ctx.aux_sink.associated_nodes[k] = v

		#reverse for &link, idx in ctx.default_sink.links {
			for _, src_id in v.ports {
				if src_id == link.src {
					pw.registry_destroy(ctx.registry, link.id)

					link_clone := link
					link_connect(&link_clone, ctx.core)

					append(&ctx.aux_sink.links, link_clone)
					unordered_remove(&ctx.default_sink.links, idx)
				}
			}
		}
	}
}

remove_program :: proc(ctx: ^Context, program: string) {
	log.logf(.Info, "removing program %s", program)
	#reverse for rule, idx in ctx.aux_rules {
		if rule == program {
			delete(ctx.aux_rules[idx])
			unordered_remove(&ctx.aux_rules, idx)

			for id, node in ctx.aux_sink.associated_nodes {
				if !check_name(node.name, {program}) {continue}
				k, v := delete_key(&ctx.aux_sink.associated_nodes, id)
				ctx.default_sink.associated_nodes[k] = v

				#reverse for &link, idx in ctx.aux_sink.links {
					for _, src_id in v.ports {
						if src_id == link.src {
							pw.registry_destroy(ctx.registry, link.id)

							link_clone := link
							link_connect(&link_clone, ctx.core)

							append(&ctx.default_sink.links, link_clone)
							unordered_remove(&ctx.aux_sink.links, idx)
						}
					}
				}
			}
			break
		}
	}
}

reload_config :: proc(ctx: ^Context) {
	assert(len(ctx.config_file) > 0, "must load config before running")
	#reverse for program in ctx.aux_rules {
		remove_program(ctx, program)
	}

	file_bytes, config_file_err := os2.read_entire_file(ctx.config_file, context.allocator)
	defer delete(file_bytes)

	file_string: string
	if config_file_err == nil {
		file_string = string(file_bytes)
	} else {
		log.logf(.Info, "could not find config file, using blank string")
	}

	for line in strings.split_lines_iterator(&file_string) {
		add_program(ctx, strings.clone(line))
	}
	log.logf(.Info, "loading rules: %v", ctx.aux_rules)
}
