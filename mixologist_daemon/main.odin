package mixologist

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:text/match"
import pw "pipewire"

Context :: struct {
	// pipewire required state
	main_loop:         ^pw.main_loop,
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

		ctx.main_loop = pw.main_loop_new(nil)

		ctx.loop = pw.main_loop_get_loop(ctx.main_loop)
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
	pw.main_loop_run(ctx.main_loop)

	// cleanup pipewire
	{
		virtualnode_destroy(&ctx.aux_sink)
		virtualnode_destroy(&ctx.default_sink)
		pw.proxy_destroy(cast(^pw.proxy)ctx.registry)
		pw.core_disconnect(ctx.core)
		pw.context_destroy(ctx.pw_context)
		pw.main_loop_destroy(ctx.main_loop)
		pw.deinit()
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
	pw.main_loop_quit(ctx.main_loop)
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

	object_type_hander: switch type {
	case "PipeWire:Interface:Node":
		node_name := pw.spa_dict_get(props, "node.name")
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
				break object_type_hander
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
	case "PipeWire:Interface:Port":
		path := pw.spa_dict_get(props, "object.path")
		if path == nil {break object_type_hander}
		cstr_channel := pw.spa_dict_get(props, "audio.channel")
		if cstr_channel == nil {break object_type_hander}
		channel := string(cstr_channel)

		switch path {
		case "input.mixologist-default:playback_0":
			node_update_link_id(&ctx.default_sink.device_node, id, channel, true)
		case "input.mixologist-default:playback_1":
			node_update_link_id(&ctx.default_sink.device_node, id, channel, true)
		case "input.mixologist-aux:playback_0":
			node_update_link_id(&ctx.aux_sink.device_node, id, channel, true)
		case "input.mixologist-aux:playback_1":
			node_update_link_id(&ctx.aux_sink.device_node, id, channel, true)
		case:
			node_id := pw.spa_dict_get(props, "node.id")
			if node_id == nil {
				break object_type_hander
			}

			node_id_uint, parse_ok := strconv.parse_uint(string(node_id))
			if !parse_ok {
				panic("could not parse uint from port")
			}
			node_id_u32 := u32(node_id_uint)

			associated_node_def, exists_def := &ctx.default_sink.associated_nodes[node_id_u32]
			associated_node_aux, exists_aux := &ctx.aux_sink.associated_nodes[node_id_u32]
			if exists_def {
				node_update_link_id(associated_node_def, id, channel, true)
				fmt.printfln("output port %d registered to default sink", id)
			} else if exists_aux {
				node_update_link_id(associated_node_aux, id, channel, true)
				fmt.printfln(
					"output port %d registered to aux sink on channel %s with path %s",
					id,
					channel,
					path,
				)
			}
		}

	case "PipeWire:Interface:Link":
		output_node, _ := get_spa_dict_u32(props, "link.output.node")
		output_port, _ := get_spa_dict_u32(props, "link.output.port")
		input_port, _ := get_spa_dict_u32(props, "link.input.port")

		associated_node_def, exists_def := ctx.default_sink.associated_nodes[output_node]
		associated_node_aux, exists_aux := ctx.aux_sink.associated_nodes[output_node]

		if exists_def {
			fmt.printfln("found source from def group from node %d with id %d", output_node, id)

			link_channel, _ := get_node_channel(associated_node_def, output_port)
			expected_input_port := ctx.default_sink.device_node.links[link_channel].port_id
			link_correct := expected_input_port == input_port

			if !link_correct {
				pw.registry_destroy(ctx.registry, id)
				link := &associated_node_def.links[link_channel]
				link_init(link, ctx.core, expected_input_port, output_port)
				virtualnode_set_volume(&ctx.default_sink, ctx.default_sink.volume)
			} else {
				fmt.printfln("expected link mapping %d -> %d", output_port, expected_input_port)
			}
		} else if exists_aux {
			fmt.printfln("found source from aux group from node %d with id %d", output_node, id)

			link_channel, _ := get_node_channel(associated_node_aux, output_port)
			expected_input_port := ctx.aux_sink.device_node.links[link_channel].port_id
			link_correct := expected_input_port == input_port

			if !link_correct {
				pw.registry_destroy(ctx.registry, id)
				link := &associated_node_aux.links[link_channel]
				link_init(link, ctx.core, expected_input_port, output_port)
				virtualnode_set_volume(&ctx.aux_sink, ctx.aux_sink.volume)
			} else {
				fmt.printfln("expected link mapping %d -> %d", output_port, expected_input_port)
			}
		} else {
			fmt.printfln("could not find link nodes with id %d for link id %d", output_node, id)
		}
	}
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
	output_port_str := fmt.aprintf("%d", output_port_id, allocator = temp_allocator)
	output_port := strings.clone_to_cstring(output_port_str, temp_allocator)

	input_port_str := fmt.aprintf("%d", input_port_id, allocator = temp_allocator)
	input_port := strings.clone_to_cstring(input_port_str, temp_allocator)

	link.props = pw.properties_new(nil, nil)
	pw.properties_set(link.props, "link.output.port", output_port)
	pw.properties_set(link.props, "link.input.port", input_port)

	link.proxy = pw.core_create_object(
		core,
		"link-factory",
		"PipeWire:Interface:Link",
		pw.VERSION_LINK,
		&link.props.dict,
		0,
	)
}

link_destroy :: proc(link: ^Link) {
	pw.proxy_destroy(link.proxy)
	pw.properties_free(link.props)
	link.port_id = 0
}

node_update_link_id :: proc(
	node: ^Node,
	id: u32,
	channel_name: string,
	copy: bool,
	allocator := context.allocator,
) {
	channel: string
	if copy {
		channel = strings.clone(channel_name)
	} else {
		channel = channel_name
	}

	link, link_exists := &node.links[channel]
	if link_exists {
		link.port_id = id
		fmt.printfln("Channel %s not created", channel)
		if copy {
			delete(channel)
		}
	} else {
		node.links[channel] = Link {
			port_id = id,
		}
		fmt.printfln("Channel %s created", channel)
	}
}
