package mixologist

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os/os2"
import "core:strings"
import pw "pipewire"

DEFAULT_RATE :: 48000
DEFAULT_CHANNELS :: 2
DEFAULT_CHANNEL_MAP :: "[ FL, FR ]"

module_events := pw.impl_module_events {
	version = 0,
	destroy = module_destroy,
}

Link :: struct {
	proxy:         ^pw.proxy,
	props:         ^pw.properties,
	port_id:       u32,
	link_id:       u32,
}

Node :: struct {
	proxy: ^pw.proxy,
	props: ^pw.spa_dict,
	links: map[string]Link,
}

LoopbackDevice :: struct {
	capture_props:   ^pw.properties,
	playback_props:  ^pw.properties,
	module:          ^pw.impl_module,
	module_listener: pw.spa_hook,
}

VirtualNode :: struct {
	device:           LoopbackDevice,
	device_node:      Node,
	associated_nodes: map[u32]Node,
	volume:           f32,
}

node_destroy :: proc(node: ^Node) {
	for channel, link in node.links {
		delete(channel)
		if link.proxy == nil {continue}
		pw.proxy_destroy(link.proxy)
		pw.properties_free(link.props)
	}
	pw.proxy_destroy(node.proxy)
}

virtualnode_init :: proc(
	sink: ^VirtualNode,
	node_name: string,
	node_volume: f32,
	ctx: ^pw.pw_context,
	arena: ^virtual.Arena,
) {
	ally := virtual.arena_allocator(arena)
	sink.associated_nodes = make(map[u32]Node, ally)
	sink.volume = node_volume

	tmp := virtual.arena_temp_begin(arena)
	defer virtual.arena_temp_end(tmp)

	group_name := fmt.aprintf(
		"%s-%d-default",
		pw.get_client_name(),
		os2.get_pid(),
		allocator = ally,
	)

	channels := DEFAULT_CHANNELS
	opt_channel_map := DEFAULT_CHANNEL_MAP
	opt_group_name := strings.unsafe_string_to_cstring(group_name)
	opt_node_name := strings.unsafe_string_to_cstring(node_name)

	sink.device.capture_props = pw.properties_new(nil, nil)
	sink.device.playback_props = pw.properties_new(nil, nil)
	pw.properties_update_cstring(sink.device.capture_props, "media.class=Audio/Sink")

	// set up loopback module
	{
		sb: strings.Builder
		strings.builder_init(&sb, ally)

		fmt.sbprintf(&sb, "{{")
		fmt.sbprintf(&sb, " audio.channels = %d", channels)
		fmt.sbprintf(&sb, " audio.position = %s", opt_channel_map)
		fmt.sbprintf(&sb, " node.name = %s", opt_node_name)

		pw.properties_set(sink.device.capture_props, pw.KEY_NODE_GROUP, opt_group_name)
		pw.properties_set(sink.device.playback_props, pw.KEY_NODE_GROUP, opt_group_name)

		fmt.sbprintf(&sb, " capture.props = {{ ")
		pw.properties_serialize_dict(&sb, &sink.device.capture_props.dict)
		fmt.sbprintf(&sb, " }} playback.props = {{ ")
		pw.properties_serialize_dict(&sb, &sink.device.playback_props.dict)
		fmt.sbprintf(&sb, " }} }}")

		args := strings.to_cstring(&sb)
		fmt.printfln("loading module with value %s", args)

		sink.device.module = pw.context_load_module(ctx, "libpipewire-module-loopback", args, nil)
	}
	pw.impl_module_add_listener(
		sink.device.module,
		&sink.device.module_listener,
		&module_events,
		sink,
	)
}

virtualnode_destroy :: proc(sink: ^VirtualNode) {
	pw.properties_free(sink.device.capture_props)
	pw.properties_free(sink.device.playback_props)
}

virtualnode_set_volume :: proc(sink: ^VirtualNode, volume: f32) {
	sink.volume = volume
	// [TODO] make dynamic for more than two channels
	proxy_set_volume(sink.device_node.proxy, volume, 2)
}

module_destroy :: proc "c" (data: rawptr) {
	context = runtime.default_context()
	sink := transmute(^VirtualNode)data
	pw.spa_hook_remove(&sink.device.module_listener)
	for id, &node in sink.associated_nodes {
		node_destroy(&node)
	}

	for channel, link in sink.device_node.links {
		delete(channel)
	}
	pw.proxy_destroy(sink.device_node.proxy)
	sink.device.module = nil
}
