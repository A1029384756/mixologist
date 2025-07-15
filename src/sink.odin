package mixologist

import pw "../pipewire"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os/os2"
import "core:strings"

DEFAULT_MAP_CAPACITY :: #config(DEFAULT_MAP_CAPACITY, 128)
DEFAULT_ARR_CAPACITY :: #config(DEFAULT_ARR_CAPACITY, 128)

DEFAULT_RATE :: 48000
DEFAULT_CHANNELS :: 2
DEFAULT_CHANNEL_MAP :: "[ FL, FR ]"

module_events := pw.impl_module_events {
	version = 0,
	destroy = module_destroy,
}

Link :: struct {
	id:    u32,
	src:   u32,
	dest:  u32,
	proxy: ^pw.proxy,
	props: ^pw.properties,
}

Node :: struct {
	proxy: ^pw.proxy,
	props: ^pw.spa_dict,
	ports: map[string]u32,
	name:  string,
}

Loopback :: struct {
	capture_props:   ^pw.properties,
	playback_props:  ^pw.properties,
	module:          ^pw.impl_module,
	module_listener: pw.spa_hook,
}

Sink :: struct {
	associated_nodes: map[u32]Node,
	links:            [dynamic]Link,
	loopback_node:    Node,
	device:           Loopback,
	volume:           f32,
}

link_connect :: proc(link: ^Link, core: ^pw.core, temp_allocator := context.temp_allocator) {
	log.debugf("connecting link %d -> %d", link.src, link.dest)
	link.proxy, link.props = pw_link_create(
		core,
		link.src,
		link.dest,
		temp_allocator = temp_allocator,
	)
}

link_destroy :: proc(link: ^Link) {
	pw.proxy_destroy(link.proxy)
	pw.properties_free(link.props)
}

node_init :: proc(
	node: ^Node,
	proxy: ^pw.proxy,
	props: ^pw.spa_dict,
	name: string,
	allocator := context.allocator,
) {
	log.infof("initializing node: %v", name)
	node.proxy = proxy
	node.props = props
	node.ports = make(map[string]u32, DEFAULT_MAP_CAPACITY, allocator)
	node.name = name

	if name != "output.mixologist-default" && name != "output.mixologist-aux" {
		gui_event_send(Program_Add(node.name))
	}
}

node_destroy :: proc(node: ^Node, allocator := context.allocator) {
	for channel in node.ports {
		delete(channel)
	}
	delete(node.ports)
	if node.proxy == nil do return

	log.infof("destroying node: %v", node.name)
	if node.name != "output.mixologist-default" && node.name != "output.mixologist-aux" {
		gui_event_send(Program_Remove(node.name))
	}

	pw.proxy_destroy(node.proxy)
	delete(node.name, allocator)
}

sink_init :: proc(
	sink: ^Sink,
	node_name: string,
	node_volume: f32,
	ctx: ^pw.pw_context,
	arena: ^virtual.Arena,
) {
	ally := virtual.arena_allocator(arena)
	sink.associated_nodes = make(map[u32]Node, DEFAULT_MAP_CAPACITY, ally)
	sink.links = make([dynamic]Link, 0, DEFAULT_ARR_CAPACITY, ally)
	sink.volume = node_volume

	tmp := virtual.arena_temp_begin(arena)
	defer virtual.arena_temp_end(tmp)

	group_name := fmt.aprintf(
		"%s-%d-default",
		pw.get_client_name(),
		os2.get_pid(),
		allocator = ally,
	)

	opt_group_name := strings.clone_to_cstring(group_name, ally)
	opt_node_name := strings.clone_to_cstring(node_name, ally)

	sink.device.capture_props = pw.properties_new(nil, nil)
	sink.device.playback_props = pw.properties_new(nil, nil)
	pw.properties_update_cstring(sink.device.capture_props, "media.class=Audio/Sink")

	// set up loopback module
	{
		sb: strings.Builder
		strings.builder_init(&sb, ally)

		fmt.sbprintf(&sb, "{{")
		fmt.sbprintf(&sb, " audio.channels = %d", DEFAULT_CHANNELS)
		fmt.sbprintf(&sb, " audio.position = %s", DEFAULT_CHANNEL_MAP)
		fmt.sbprintf(&sb, " node.name = %s", opt_node_name)

		pw.properties_set(sink.device.capture_props, pw.KEY_NODE_GROUP, opt_group_name)
		pw.properties_set(sink.device.playback_props, pw.KEY_NODE_GROUP, opt_group_name)

		fmt.sbprintf(&sb, " capture.props = {{ ")
		pw.properties_serialize_dict(&sb, &sink.device.capture_props.dict)
		fmt.sbprintf(&sb, " }} playback.props = {{ ")
		pw.properties_serialize_dict(&sb, &sink.device.playback_props.dict)
		fmt.sbprintf(&sb, " }} }}")

		args, _ := strings.to_cstring(&sb)
		log.logf(.Info, "loading module with value %s", args)

		sink.device.module = pw.context_load_module(ctx, "libpipewire-module-loopback", args, nil)
	}
	pw.impl_module_add_listener(
		sink.device.module,
		&sink.device.module_listener,
		&module_events,
		sink,
	)
}

sink_destroy :: proc(sink: ^Sink) {
	for &link in sink.links {
		link_destroy(&link)
	}
	node_destroy(&sink.loopback_node)
	pw.properties_free(sink.device.capture_props)
	pw.properties_free(sink.device.playback_props)
}

sink_set_volume :: proc(sink: ^Sink, volume: f32) {
	sink.volume = volume
	proxy_volume := volume_falloff(volume, mixologist.config.settings.volume_falloff)
	proxy_set_volume(sink.loopback_node.proxy, proxy_volume, len(sink.loopback_node.ports))
}

Volume_Falloff :: enum {
	Linear    = 0,
	Quadratic = 1,
	Power     = 2,
	Cubic     = 3,
}

volume_falloff :: proc(volume: f32, falloff: Volume_Falloff) -> f32 {
	switch falloff {
	case .Linear:
		return volume
	case .Quadratic:
		return volume * volume
	case .Power:
		return 1 - math.pow(1 - volume, 0.5)
	case .Cubic:
		return volume * volume * volume
	}
	unreachable()
}

module_destroy :: proc "c" (data: rawptr) {
	context = mixologist.daemon.pw_odin_ctx
	sink := transmute(^Sink)data
	pw.spa_hook_remove(&sink.device.module_listener)
	for _, &node in sink.associated_nodes {
		node_destroy(&node)
	}
	sink.device.module = nil
}
