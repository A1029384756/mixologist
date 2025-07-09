package mixologist

import pw "../pipewire"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:text/match"

Daemon_Context :: struct {
	// config state
	config_file:       string,
	cache_file:        string,
	// pipewire required state
	main_loop:         ^pw.thread_loop,
	loop:              ^pw.loop,
	core:              ^pw.core,
	pw_context:        ^pw.pw_context,
	pw_context_props:  ^pw.properties,
	registry:          ^pw.registry,
	registry_listener: pw.spa_hook,
	pw_odin_ctx:       runtime.Context,
	// sinks
	default_sink:      Sink,
	aux_sink:          Sink,
	device_inputs:     map[string]Link,
	passthrough_nodes: map[u32]Node,
	passthrough_ports: [dynamic]u32,
	// allocations
	arena:             virtual.Arena,
	allocator:         mem.Allocator,
	// control flow/ipc state
	should_exit:       bool,
}

daemon_proc :: proc(ctx: ^Daemon_Context) {
	daemon_init(&mixologist.daemon)
	for !daemon_should_exit(&mixologist.daemon) {
		daemon_tick(&mixologist.daemon)
		free_all(context.temp_allocator)
	}
	daemon_deinit(&mixologist.daemon)
	mixologist_event_send(Exit{})
}

daemon_init :: proc(ctx: ^Daemon_Context) {
	if virtual.arena_init_growing(&ctx.arena) != nil {
		panic("Couldn't initialize arena")
	}
	ctx.allocator = virtual.arena_allocator(&ctx.arena)
	ctx.device_inputs = make(map[string]Link, DEFAULT_MAP_CAPACITY, ctx.allocator)
	ctx.passthrough_nodes = make(map[u32]Node, DEFAULT_MAP_CAPACITY, ctx.allocator)
	ctx.passthrough_ports = make([dynamic]u32, DEFAULT_ARR_CAPACITY, ctx.allocator)
	ctx.pw_odin_ctx = context

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

		// required for flatpak volume control
		ctx.pw_context_props = pw.properties_new(nil, nil)
		pw.properties_set(ctx.pw_context_props, pw.KEY_MEDIA_CATEGORY, "Manager")

		ctx.pw_context = pw.context_new(ctx.loop, ctx.pw_context_props, 0)
		ctx.core = pw.context_connect(ctx.pw_context, nil, 0)

		ctx.registry = pw.core_get_registry(ctx.core, pw.VERSION_REGISTRY, 0)
		pw.registry_add_listener(ctx.registry, &ctx.registry_listener, &registry_events, ctx)

		default_volume, aux_volume := daemon_sink_volumes(mixologist.volume)
		sink_init(
			&ctx.default_sink,
			"mixologist-default",
			default_volume,
			ctx.pw_context,
			&ctx.arena,
		)
		sink_init(&ctx.aux_sink, "mixologist-aux", aux_volume, ctx.pw_context, &ctx.arena)
	}

	setup_exit_handlers(ctx)
	pw.thread_loop_start(ctx.main_loop)
}


daemon_tick :: proc(ctx: ^Daemon_Context) {
	// this is a no-op but here for the future
	time: linux.Time_Spec
	pw.thread_loop_get_time(ctx.main_loop, &time, 1e6)
	pw.thread_loop_timed_wait_full(ctx.main_loop, &time)
}

daemon_deinit :: proc(ctx: ^Daemon_Context) {
	pw.thread_loop_unlock(ctx.main_loop)
	pw.thread_loop_stop(ctx.main_loop)

	// pipewire cleanup
	{
		reset_links(ctx)
		sink_destroy(&ctx.aux_sink)
		sink_destroy(&ctx.default_sink)
		pw.proxy_destroy(cast(^pw.proxy)ctx.registry)
		pw.core_disconnect(ctx.core)
		pw.context_destroy(ctx.pw_context)
		pw.thread_loop_destroy(ctx.main_loop)
		pw.deinit()
	}

	free_all(ctx.allocator)
}

daemon_should_exit :: proc(ctx: ^Daemon_Context) -> bool {
	return ctx.should_exit
}

// this relies on terrible undefined behavior
// but allows us to avoid using sigqueue or globals
setup_exit_handlers :: proc(ctx: ^Daemon_Context) {
	do_quit_with_data(.SIGUSR1, ctx)
	posix.signal(.SIGINT, transmute(proc "c" (_: posix.Signal))do_quit_with_data)
	posix.signal(.SIGTERM, transmute(proc "c" (_: posix.Signal))do_quit_with_data)
}

do_quit_with_data :: proc "c" (signum: posix.Signal, data: rawptr) {
	@(static) ctx: ^Daemon_Context
	if ctx == nil {
		ctx = cast(^Daemon_Context)data
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
	ctx := cast(^Daemon_Context)data
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
	ctx := cast(^Daemon_Context)data
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

node_handler :: proc(ctx: ^Daemon_Context, id, version: u32, type: cstring, props: ^pw.spa_dict) {
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
		if daemon_rule_matches(ctx, string(application_name)) {
			ctx.aux_sink.associated_nodes[id] = node
		} else {
			ctx.default_sink.associated_nodes[id] = node
		}
		log.logf(.Info, "Registered application node of id %d and name %s", id, application_name)
	}
}

daemon_rule_matches :: proc(ctx: ^Daemon_Context, rule: string) -> bool {
	for check in mixologist.config.rules {
		matcher := match.matcher_init(rule, check)
		match_result, match_ok := match.matcher_match(&matcher)
		if match_ok && len(match_result) == len(rule) {
			return true
		}
	}
	return false
}

port_handler :: proc(ctx: ^Daemon_Context, id, version: u32, props: ^pw.spa_dict) {
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

link_handler :: proc(ctx: ^Daemon_Context, id, version: u32, props: ^pw.spa_dict) {
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

rebuild_connections :: proc(ctx: ^Daemon_Context) {
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

daemon_sink_volumes :: proc(vol: f32) -> (def, aux: f32) {
	return vol < 0 ? 1 : 1 - vol, vol > 0 ? 1 : vol + 1
}

daemon_add_program :: proc(ctx: ^Daemon_Context, program: string) {
	log.logf(.Info, "adding program %s", program)
	for id, node in ctx.default_sink.associated_nodes {
		if !check_name(node.name, {program}) do continue
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

daemon_remove_program :: proc(ctx: ^Daemon_Context, program: string) {
	log.logf(.Info, "removing program %s", program)
	for id, node in ctx.aux_sink.associated_nodes {
		if !check_name(node.name, {program}) do continue
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
}
