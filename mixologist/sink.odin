package mixologist

import pw "../pipewire"
import "base:runtime"
import "core:fmt"
import "core:log"
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
	output_ports:     map[string]u32,
	loopback_node:    Node,
	device:           Loopback,
	volume:           f32,
}

link_init :: proc(
	link: ^Link,
	core: ^pw.core,
	src, dest: u32,
	temp_allocator := context.temp_allocator,
) {
	link.proxy, link.props = pw_link_create(core, dest, src, temp_allocator = temp_allocator)
	link.src, link.dest = src, dest
}

link_connect :: proc(link: ^Link, core: ^pw.core, temp_allocator := context.temp_allocator) {
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
	node.proxy = proxy
	node.props = props
	node.ports = make(map[string]u32, DEFAULT_MAP_CAPACITY, allocator)
	node.name = name
}

node_destroy :: proc(node: ^Node) {
	for channel in node.ports {
		delete(channel)
	}
	pw.proxy_destroy(node.proxy)
	delete(node.name)
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
	pw.properties_free(sink.device.capture_props)
	pw.properties_free(sink.device.playback_props)
}

sink_set_volume :: proc(sink: ^Sink, volume: f32) {
	sink.volume = volume
	// [TODO] make dynamic for more than two channels
	proxy_set_volume(sink.loopback_node.proxy, volume, 2)
}

module_destroy :: proc "c" (data: rawptr) {
	context = runtime.default_context()
	sink := transmute(^Sink)data
	pw.spa_hook_remove(&sink.device.module_listener)
	for _, &node in sink.associated_nodes {
		node_destroy(&node)
	}
	sink.device.module = nil
}
