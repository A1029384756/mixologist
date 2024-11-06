package mixologist

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:sys/unix"
import "core:text/match"
import "core:time"
import pw "pipewire"

LOG_LEVEL_DEFAULT :: "debug" when ODIN_DEBUG else "info"
LOG_LEVEL :: #config(LOG_LEVEL, LOG_LEVEL_DEFAULT)

Context :: struct {
	// pipewire required state
	main_loop:         ^pw.thread_loop,
	loop:              ^pw.loop,
	core:              ^pw.core,
	pw_context:        ^pw.pw_context,
	registry:          ^pw.registry,
	registry_listener: pw.spa_hook,
	// sinks
	default_sink:      Sink,
	aux_sink:          Sink,
	aux_rules:         [dynamic]string,
	device_inputs:     map[string]Link,
	// allocations
	arena:             virtual.Arena,
	allocator:         mem.Allocator,
	// control flow/ipc state
	should_exit:       bool,
	ipc:               posix.FD,
	addr:              posix.sockaddr_un,
}

main :: proc() {
	ctx: Context
	context.logger = log.create_console_logger(lowest = get_log_level())
	defer log.destroy_console_logger(context.logger)

	// initialize context
	{
		if virtual.arena_init_growing(&ctx.arena) != nil {
			panic("Couldn't initialize arena")
		}
		ctx.allocator = virtual.arena_allocator(&ctx.arena)
		ctx.aux_rules = make([dynamic]string, 0, DEFAULT_ARR_CAPACITY, ctx.allocator)
		ctx.device_inputs = make(map[string]Link, DEFAULT_MAP_CAPACITY, ctx.allocator)
	}

	// set up ipc
	{
		ctx.ipc = posix.socket(.UNIX, .STREAM)
		if ctx.ipc == -1 {
			log.panic("could not create socket")
		}

		flags := transmute(posix.O_Flags)posix.fcntl(ctx.ipc, .GETFL) + {.NONBLOCK}
		posix.fcntl(ctx.ipc, .SETFL, flags)

		ctx.addr.sun_family = .UNIX
		copy(ctx.addr.sun_path[:], "/tmp/mixologist\x00")

		posix.unlink("/tmp/mixologist")
		if posix.bind(ctx.ipc, cast(^posix.sockaddr)(&ctx.addr), size_of(ctx.addr)) != .OK {
			log.panic("could not bind socket")
		}

		if posix.listen(ctx.ipc, 5) != .OK {
			log.panicf("could not listen on socket %v", posix.errno())
		}
	}

	// initialize pipewire
	{
		argc := len(os2.args)
		argv := make([dynamic]cstring, 0, argc, ctx.allocator)
		for arg in os2.args {
			append(&argv, strings.unsafe_string_to_cstring(arg))
		}
		pw.init(&argc, raw_data(argv[:]))

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
		default_volume, aux_volume: f32 = 1, 1
		{
			cache_dir := os2.user_cache_dir(ctx.allocator) or_else panic("cache dir not found")
			file_bytes, cache_file_err := os2.read_entire_file(
				strings.concatenate(
					{cache_dir, os2.Path_Separator_String, "mixologist.volumes"},
					ctx.allocator,
				),
				ctx.allocator,
			)

			if cache_file_err == nil {
				file_string := string(file_bytes)
				delim_pos := strings.index_rune(file_string, ',')
				default_volume_str, _ := strings.substring(file_string, 0, delim_pos)
				aux_volume_str, _ := strings.substring(
					file_string,
					delim_pos + 1,
					strings.rune_count(file_string),
				)

				default_volume, _ = strconv.parse_f32(default_volume_str)
				aux_volume, _ = strconv.parse_f32(aux_volume_str)
				log.logf(
					.Info,
					"set default volume to: %f and aux volume to: %f",
					default_volume,
					aux_volume,
				)
			} else {
				log.logf(.Info, "could not find saved volumes, using default")
			}
		}

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
		file_bytes, config_file_err := os2.read_entire_file(
			strings.concatenate(
				{config_dir, os2.Path_Separator_String, "mixologist.conf"},
				ctx.allocator,
			),
			ctx.allocator,
		)

		file_string: string
		if config_file_err == nil {
			file_string = string(file_bytes)
		} else {
			log.logf(.Info, "could not find config file, using blank string")
		}

		for line in strings.split_lines_iterator(&file_string) {
			append(&ctx.aux_rules, line)
		}
		log.logf(.Info, "loading rules: %v", ctx.aux_rules)
	}

	setup_exit_handlers(&ctx)
	pw.thread_loop_start(ctx.main_loop)

	events: for !ctx.should_exit {
		time: unix.timespec
		pw.thread_loop_get_time(ctx.main_loop, &time, 1e7)
		pw.thread_loop_timed_wait_full(ctx.main_loop, &time)

		size := cast(posix.socklen_t)size_of(ctx.addr)
		conn := posix.accept(ctx.ipc, nil, nil)
		if conn == -1 {
			if posix.errno() != .EWOULDBLOCK {
				log.panicf("could not accept connection with error %v", posix.errno())
			} else {
				log.log(.Debug, "no pending connnections")
				continue events
			}
		}
		defer posix.close(conn)

		buf: [1024]u8
		bytes_read := posix.recv(ctx.ipc, &buf, len(buf), {})
		if bytes_read > 0 {
			log.logf(
				.Debug,
				"read %d bytes with contents %s",
				bytes_read,
				string(buf[:bytes_read]),
			)
		}
	}

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

	// ipc cleanup
	{
		posix.close(ctx.ipc)
		posix.unlink("/tmp/mixologist")
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
	context = runtime.default_context()
	context.logger = log.create_console_logger(lowest = get_log_level())
	defer log.destroy_console_logger(context.logger)

	ctx := cast(^Context)data

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
	// [TODO] fix memory leak
	context = runtime.default_context()
	context.logger = log.create_console_logger(lowest = get_log_level())
	defer log.destroy_console_logger(context.logger)

	ctx := cast(^Context)data
	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}

	for sink in sinks {
		associated_node, node_exists := sink.associated_nodes[id]
		if node_exists {
			node_destroy(&associated_node)
			delete_key(&ctx.default_sink.associated_nodes, id)
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
		node_init(&node, proxy, props, ctx.allocator)
		ctx.default_sink.loopback_node = node
		log.logf(.Info, "registered default node with id %d", id)
	} else if node_name == "output.mixologist-aux" {
		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node: Node
		node_init(&node, proxy, props, ctx.allocator)
		ctx.aux_sink.loopback_node = node
		log.logf(.Info, "registered aux node with id %d", id)
	} else {
		application_name := pw.spa_dict_get(props, "application.name")
		if application_name == nil {
			log.logf(.Info, "could not find application name for node with id %d", id)
			return
		}

		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node: Node
		node_init(&node, proxy, props, ctx.allocator)
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
		prev, curr, found := map_upsert(&ctx.default_sink.loopback_node.ports, channel, id)
		log.logf(.Info, "def port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else if strings.starts_with(string(path), "input.mixologist-aux:playback") {
		channel := strings.clone_from_cstring(cstr_channel)
		prev, curr, found := map_upsert(&ctx.aux_sink.loopback_node.ports, channel, id)
		log.logf(.Info, "aux port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else if strings.starts_with(string(path), "output.mixologist-default:output") ||
	   strings.starts_with(string(path), "output.mixologist-aux:output") {
		channel := strings.clone_from_cstring(cstr_channel)
		prev, curr, found := map_upsert(&ctx.device_inputs, channel, Link{src = id})
		log.logf(.Info, "output port %d registered on channel %s", id, channel)
		if found {
			delete(channel)
		}
	} else {
		node_id := pw.spa_dict_get(props, "node.id")
		if node_id == nil {return}

		node_id_uint, parse_ok := strconv.parse_uint(string(node_id))
		assert(parse_ok)
		node_id_u32 := u32(node_id_uint)

		sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}
		for sink, idx in sinks {
			associated_node, node_exists := &sink.associated_nodes[node_id_u32]
			if !node_exists {continue}

			port_name := pw.spa_dict_get(associated_node.props, "port.name")
			if strings.starts_with(string(port_name), "monitor_") {return}

			channel := strings.clone_from_cstring(cstr_channel)
			prev, curr, found := map_upsert(&associated_node.ports, channel, id)
			if found {
				delete(channel)
			}
			log.logf(.Info, "output port %d registered to sink %d", id, idx)
		}
	}
}

link_handler :: proc(ctx: ^Context, id, version: u32, props: ^pw.spa_dict) {
	src_node, _ := spa_dict_get_u32(props, "link.output.node")
	src_port, _ := spa_dict_get_u32(props, "link.output.port")
	dest_port, _ := spa_dict_get_u32(props, "link.input.port")

	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}
	for sink, idx in sinks {
		associated_node, node_exists := sink.associated_nodes[src_node]
		if !node_exists {
			for channel, &mapping in ctx.device_inputs {
				if mapping.src == src_port {
					mapping.dest = dest_port
					break
				}
			}
			continue
		}

		log.logf(.Debug, "found source from %d group from node %d with id %d", idx, src_node, id)

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

		for id, node in sink.associated_nodes {
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

get_log_level :: #force_inline proc() -> runtime.Logger_Level {
	when LOG_LEVEL == "debug" {
		return .Debug
	} else when LOG_LEVEL == "info" {
		return .Info
	} else when LOG_LEVEL == "warning" {
		return .Warning
	} else when LOG_LEVEL == "error" {
		return .Error
	} else when LOG_LEVEL == "fatal" {
		return .Fatal
	} else {
		#panic(
			"Unknown `ODIN_TEST_LOG_LEVEL`: \"" +
			LOG_LEVEL +
			"\", possible levels are: \"debug\", \"info\", \"warning\", \"error\", or \"fatal\".",
		)
	}
}
