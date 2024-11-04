package mixologist

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os/os2"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/unix"
import "core:text/match"
import "core:time"
import pw "pipewire"

Context :: struct {
	// pipewire required state
	main_loop:         ^pw.thread_loop,
	loop:              ^pw.loop,
	core:              ^pw.core,
	pw_context:        ^pw.pw_context,
	registry:          ^pw.registry,
	registry_listener: pw.spa_hook,
	// sinks
	default_sink:      VirtualNode,
	aux_sink:          VirtualNode,
	aux_rules:         [dynamic]string,
	// allocations
	arena:             virtual.Arena,
	allocator:         mem.Allocator,
	// control flow/ipc state
	should_exit:       bool,
	ipc:               net.TCP_Socket,
}

main :: proc() {
	ctx: Context
	// initialize context
	{
		if virtual.arena_init_growing(&ctx.arena) != nil {
			panic("Couldn't initialize arena")
		}
		ctx.allocator = virtual.arena_allocator(&ctx.arena)
		ctx.aux_rules = make([dynamic]string, ctx.allocator)
	}

	// set up ipc
	{
		net_err: net.Network_Error
		// [TODO] make port user-configurable
		ctx.ipc, net_err = net.listen_tcp({net.IP4_Any, 6720})
		if net_err != nil {
			fmt.panicf("could not listen on socket with error %v", net_err)
		}
		net.set_blocking(ctx.ipc, false)
	}

	// initialize pipewire
	{
		argc := len(os2.args)
		argv := make([dynamic]cstring, 0, argc, ctx.allocator)
		for arg in os2.args {
			append(&argv, strings.unsafe_string_to_cstring(arg))
		}
		pw.init(&argc, raw_data(argv[:]))

		fmt.println(
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
				fmt.printfln(
					"set default volume to: %f and aux volume to: %f",
					default_volume,
					aux_volume,
				)
			} else {
				fmt.println("could not find saved volumes, using default")
			}
		}

		virtualnode_init(
			&ctx.default_sink,
			"mixologist-default",
			default_volume,
			ctx.pw_context,
			&ctx.arena,
		)
		virtualnode_init(&ctx.aux_sink, "mixologist-aux", aux_volume, ctx.pw_context, &ctx.arena)
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
			fmt.println("could not find config file, using blank string")
		}

		for line in strings.split_lines_iterator(&file_string) {
			append(&ctx.aux_rules, line)
		}
		fmt.printfln("loading rules: %v", ctx.aux_rules)
	}

	setup_exit_handlers(&ctx)
	pw.thread_loop_start(ctx.main_loop)

	for !ctx.should_exit {
		time: unix.timespec
		pw.thread_loop_get_time(ctx.main_loop, &time, 1e7)
		pw.thread_loop_timed_wait_full(ctx.main_loop, &time)

		conn, _, accept_err := net.accept_tcp(ctx.ipc)
		if accept_err != nil && accept_err != net.Accept_Error.Would_Block {
			fmt.panicf("accept err %v", accept_err)
		}
		defer net.close(conn)

		buf: [1024]u8
		bytes_read, recv_err := net.recv(conn, buf[:])
		if bytes_read > 0 {
			fmt.printfln("read %d bytes with contents %s", bytes_read, string(buf[:bytes_read]))
		}
	}

	pw.thread_loop_unlock(ctx.main_loop)
	pw.thread_loop_stop(ctx.main_loop)

	// pipewire cleanup
	{
		reset_links(&ctx)
		virtualnode_destroy(&ctx.aux_sink)
		virtualnode_destroy(&ctx.default_sink)
		pw.proxy_destroy(cast(^pw.proxy)ctx.registry)
		pw.core_disconnect(ctx.core)
		pw.context_destroy(ctx.pw_context)
		pw.thread_loop_destroy(ctx.main_loop)
		pw.deinit()
	}

	// ipc cleanup
	{
		net.close(ctx.ipc)
	}

	free_all(ctx.allocator)
}

// this relies on terrible undefined behavior
// but allows us to avoid using sigqueue or globals
setup_exit_handlers :: proc(ctx: ^Context) {
	do_quit_with_data(i32(linux.Signal.SIGUSR1), ctx)
	libc.signal(i32(linux.Signal.SIGINT), transmute(proc "c" (_: i32))do_quit_with_data)
	libc.signal(i32(linux.Signal.SIGTERM), transmute(proc "c" (_: i32))do_quit_with_data)
}

do_quit_with_data :: proc "c" (signum: i32, data: rawptr) {
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
	ctx := cast(^Context)data

	associated_node_def, exists_def := ctx.default_sink.associated_nodes[id]
	associated_node_aux, exists_aux := ctx.aux_sink.associated_nodes[id]
	if exists_def {
		node_destroy(&associated_node_def)
	} else if exists_aux {
		node_destroy(&associated_node_aux)
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

link_init :: proc(
	link: ^Link,
	core: ^pw.core,
	input_port_id, output_port_id: u32,
	temp_allocator := context.temp_allocator,
) {
	link.proxy, link.props = pw_link_create(core, input_port_id, output_port_id)
}

node_update_link_port_id :: proc(
	node: ^Node,
	id: u32,
	channel_name: string,
	copy: bool,
	allocator := context.allocator,
) {
	link, link_exists := &node.links[channel_name]
	if link_exists {
		link.port_id = id
		fmt.printfln("Channel %s not created", channel_name)
	} else {
		channel := copy ? strings.clone(channel_name) : channel_name
		node.links[channel] = Link {
			port_id = id,
		}
		fmt.printfln("Channel %s created", channel)
	}
}

node_handler :: proc(ctx: ^Context, id, version: u32, type: cstring, props: ^pw.spa_dict) {
	node_name := pw.spa_dict_get(props, "node.name")
	fmt.printfln("Attempting to add node name %s", node_name)
	if node_name == "output.mixologist-default" {
		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node := Node {
			proxy = proxy,
			props = props,
			links = make(map[string]Link, ctx.allocator),
		}
		ctx.default_sink.device_node = node
		fmt.printfln("registered default node with id %d", id)
	} else if node_name == "output.mixologist-aux" {
		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node := Node {
			proxy = proxy,
			props = props,
			links = make(map[string]Link, ctx.allocator),
		}
		ctx.aux_sink.device_node = node
		fmt.printfln("registered aux node with id %d", id)
	} else {
		application_name := pw.spa_dict_get(props, "application.name")
		if application_name == nil {
			fmt.printfln("could not find application name for node with id %d", id)
			return
		}

		proxy := pw.registry_bind(ctx.registry, id, type, version, 0)
		node := Node {
			proxy = proxy,
			props = props,
			links = make(map[string]Link, ctx.allocator),
		}
		if check_name(string(application_name), ctx.aux_rules[:]) {
			ctx.aux_sink.associated_nodes[id] = node
		} else {
			ctx.default_sink.associated_nodes[id] = node
		}
		fmt.printfln("Registered application node of id %d and name %s", id, application_name)
	}
}

port_handler :: proc(ctx: ^Context, id, version: u32, props: ^pw.spa_dict) {
	path := pw.spa_dict_get(props, "object.path")
	if path == nil {return}
	cstr_channel := pw.spa_dict_get(props, "audio.channel")
	if cstr_channel == nil {return}
	channel := string(cstr_channel)

	switch path {
	// [TODO] make work for > 2 channels
	case "input.mixologist-default:playback_0", "input.mixologist-default:playback_1":
		node_update_link_port_id(&ctx.default_sink.device_node, id, channel, true)
	case "input.mixologist-aux:playback_0", "input.mixologist-aux:playback_1":
		node_update_link_port_id(&ctx.aux_sink.device_node, id, channel, true)
	case:
		node_id := pw.spa_dict_get(props, "node.id")
		if node_id == nil {return}

		node_id_uint, parse_ok := strconv.parse_uint(string(node_id))
		assert(parse_ok)
		node_id_u32 := u32(node_id_uint)

		sinks := [?]^VirtualNode{&ctx.default_sink, &ctx.aux_sink}
		for sink, idx in sinks {
			associated_node, node_exists := &sink.associated_nodes[node_id_u32]
			if node_exists {
				port_name := pw.spa_dict_get(associated_node.props, "port.name")
				if strings.starts_with(string(port_name), "monitor_") {return}
				node_update_link_port_id(associated_node, id, channel, true)
				fmt.printfln("output port %d registered to sink %d", id, idx)
			}
		}
	}
}

link_handler :: proc(ctx: ^Context, id, version: u32, props: ^pw.spa_dict) {
	output_node, _ := get_spa_dict_u32(props, "link.output.node")
	output_port, _ := get_spa_dict_u32(props, "link.output.port")
	input_port, _ := get_spa_dict_u32(props, "link.input.port")

	sinks := [?]^VirtualNode{&ctx.default_sink, &ctx.aux_sink}
	for sink, idx in sinks {
		associated_node, node_exists := sink.associated_nodes[output_node]
		if node_exists {
			fmt.printfln(
				"found source from %d group from node %d with id %d",
				idx,
				output_node,
				id,
			)

			link_channel, _ := get_node_channel(associated_node, output_port)
			expected_input_port := sink.device_node.links[link_channel].port_id
			link_correct := expected_input_port == input_port

			link := &associated_node.links[link_channel]
			fmt.println(link)
			if !link_correct {
				link.link_id = id
				link.og_dest = input_port
				link.port_id = output_port
				fmt.printfln(
					"setting up link mapping %d -> %d for link id %d",
					output_port,
					input_port,
					id,
				)
			} else {
				fmt.printfln("expected link mapping %d -> %d", output_port, input_port)
			}
		} else {
			fmt.printfln(
				"could not find link nodes in group %d with id %d for link id %d",
				idx,
				output_node,
				id,
			)
		}
	}
}

rebuild_connections :: proc(ctx: ^Context) {
	sinks := [?]^VirtualNode{&ctx.default_sink, &ctx.aux_sink}
	for sink in sinks {
		if sink.device_node.proxy != nil {
			for node_id, associated_node in sink.associated_nodes {
				for channel, &link in associated_node.links {
					if link.proxy != nil || sink.device_node.links[channel].port_id == 0 {
						continue
					}
					pw.registry_destroy(ctx.registry, link.link_id)
					fmt.printfln(
						"Making link from port id %d to port id %d",
						link.port_id,
						sink.device_node.links[channel].port_id,
					)
					link_init(
						&link,
						ctx.core,
						sink.device_node.links[channel].port_id,
						link.port_id,
					)
					virtualnode_set_volume(sink, sink.volume)
				}
			}
		}
	}
}
