package mixologist

import "core:fmt"
import "core:strconv"
import "core:strings"
import pw "pipewire"

get_spa_dict_u32 :: proc(d: ^pw.spa_dict, id: cstring) -> (val: u32, ok: bool) {
	item := pw.spa_dict_get(d, id)
	val_uint := strconv.parse_uint(string(item)) or_return
	val = u32(val_uint)
	return
}

get_node_channel :: proc(node: Node, output_port: u32) -> (channel: string, found: bool) {
	for channel, link in node.links {
		if link.port_id == output_port {
			return channel, true
		}
	}

	return channel, false
}

proxy_set_volume :: proc(proxy: ^pw.proxy, volume: f32, num_channels: int) {
	assert(proxy != nil)
	fmt.printfln("setting volume to %f", volume)

	buf: [256]u8
	b: pw.spa_pod_builder
	pw.spa_pod_builder_init(&b, &buf, u32(len(buf)))
	{
		obj_frame: pw.spa_pod_frame
		defer pw.spa_pod_builder_pop(&b, &obj_frame)
		pw.spa_pod_builder_push_object(&b, &obj_frame, .SPA_TYPE_OBJECT_Props, .SPA_PARAM_Props)
		pw.spa_pod_builder_prop(&b, .SPA_PROP_channelVolumes, {})

		{
			arr_frame: pw.spa_pod_frame
			defer pw.spa_pod_builder_pop(&b, &arr_frame)
			pw.spa_pod_builder_push_array(&b, &arr_frame)

			for i in 0 ..< num_channels {
				pw.spa_pod_builder_float(&b, volume)
			}
		}
	}

	pod := pw.spa_pod_builder_deref(&b, 0)
	pw.node_set_param(proxy, .SPA_PARAM_Props, 0, pod)
}

pw_link_create :: proc(
	core: ^pw.core,
	input_port_id, output_port_id: u32,
	temp_allocator := context.temp_allocator,
) -> (
	proxy: ^pw.proxy,
	props: ^pw.properties,
) {
	output_port_str := fmt.aprintf("%d", output_port_id, allocator = temp_allocator)
	output_port := strings.clone_to_cstring(output_port_str, temp_allocator)

	input_port_str := fmt.aprintf("%d", input_port_id, allocator = temp_allocator)
	input_port := strings.clone_to_cstring(input_port_str, temp_allocator)

	props = pw.properties_new(nil, nil)
	pw.properties_set(props, "link.output.port", output_port)
	pw.properties_set(props, "link.input.port", input_port)

	proxy = pw.core_create_object(
		core,
		"link-factory",
		"PipeWire:Interface:Link",
		pw.VERSION_LINK,
		&props.dict,
		0,
	)

	return
}

reset_links :: proc(ctx: ^Context) {
	sinks := [?]^VirtualNode{&ctx.default_sink, &ctx.aux_sink}
	for sink in sinks {
		for id, node in sink.associated_nodes {
			for channel, link in node.links {
				pw.registry_destroy(ctx.registry, link.link_id)
				fmt.printfln("making final link %d -> %d", link.port_id, link.og_dest)
				proxy, props := pw_link_create(ctx.core, link.og_dest, link.port_id)
				pw.proxy_destroy(proxy)
				pw.properties_free(props)
			}
		}
	}
}
