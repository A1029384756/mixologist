package mixologist

import "core:fmt"
import "core:strconv"
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

proxy_set_volume :: proc(proxy: ^pw.pw_proxy, volume: f32) {
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

			for i in 0 ..< 2 {
				pw.spa_pod_builder_float(&b, volume)
			}
		}
	}

	pod := pw.spa_pod_builder_deref(&b, 0)
	pw.node_set_param(proxy, .SPA_PARAM_Props, 0, pod)
}
