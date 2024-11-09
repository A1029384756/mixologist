package mixologist_daemon

import "../common"
import pw "../pipewire"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

spa_dict_get_u32 :: proc(d: ^pw.spa_dict, id: cstring) -> (val: u32, ok: bool) {
	item := pw.spa_dict_get(d, id)
	val_uint := strconv.parse_uint(string(item)) or_return
	val = u32(val_uint)
	return
}

proxy_set_volume :: proc(proxy: ^pw.proxy, volume: f32, num_channels: int) {
	assert(proxy != nil)

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

			for _ in 0 ..< num_channels {
				pw.spa_pod_builder_float(&b, volume)
			}
		}
	}

	pod := pw.spa_pod_builder_deref(&b, 0)
	pw.node_set_param(proxy, .SPA_PARAM_Props, 0, pod)
}

pw_link_create :: proc(
	core: ^pw.core,
	src, dest: u32,
	additional_items := []pw.spa_dict_item{},
	temp_allocator := context.temp_allocator,
) -> (
	proxy: ^pw.proxy,
	props: ^pw.properties,
) {
	src_str := fmt.aprintf("%d", src, allocator = temp_allocator)
	src_port := strings.clone_to_cstring(src_str, temp_allocator)

	dest_str := fmt.aprintf("%d", dest, allocator = temp_allocator)
	dest_port := strings.clone_to_cstring(dest_str, temp_allocator)

	props = pw.properties_new(nil, nil)
	pw.properties_set(props, "link.output.port", src_port)
	pw.properties_set(props, "link.input.port", dest_port)

	for item in additional_items {
		pw.properties_set(props, item.key, item.value)
	}

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

core_events := pw.core_events {
	version = pw.VERSION_CORE_EVENTS,
	done    = on_done,
	error   = on_error,
}

on_done :: proc "c" (data: rawptr, id: u32, seq: c.int) {
	context = runtime.default_context()
	context.logger = log.create_console_logger(lowest = common.get_log_level())
	defer log.destroy_console_logger(context.logger)

	log.logf(.Info, "core finished")

	ctx := cast(^Cleanup_Loop)data
	if ctx.sync == seq {
		pw.main_loop_quit(ctx.main_loop)
	}
}

on_error :: proc "c" (data: rawptr, id: u32, seq: c.int, res: c.int, message: cstring) {
	context = runtime.default_context()
	context.logger = log.create_console_logger(lowest = common.get_log_level())
	defer log.destroy_console_logger(context.logger)

	ctx := cast(^Cleanup_Loop)data

	log.logf(.Error, "error id:%d seq:%d res:%d (%v): %s", id, seq, res, res, message)

	if (id == 0 && res == -cast(c.int)posix.Errno.EPIPE) {
		pw.main_loop_quit(ctx.main_loop)
	}
}

Cleanup_Loop :: struct {
	main_loop:     ^pw.main_loop,
	loop:          ^pw.loop,
	ctx:           ^pw.pw_context,
	core:          ^pw.core,
	core_listener: pw.spa_hook,
	sync:          c.int,
}

reset_links :: proc(ctx: ^Context) {
	sinks := [?]^Sink{&ctx.default_sink, &ctx.aux_sink}

	cleanup_loop: Cleanup_Loop
	cleanup_loop.main_loop = pw.main_loop_new(nil)
	cleanup_loop.loop = pw.main_loop_get_loop(cleanup_loop.main_loop)
	cleanup_loop.ctx = pw.context_new(cleanup_loop.loop, nil, 0)
	cleanup_loop.core = pw.context_connect(cleanup_loop.ctx, nil, 0)
	pw.core_add_listener(
		cleanup_loop.core,
		&cleanup_loop.core_listener,
		&core_events,
		&cleanup_loop,
	)

	for channel, link in ctx.device_inputs {
		for sink in sinks {
			for id, node in sink.associated_nodes {
				src := node.ports[channel]
				log.logf(.Info, "making final link %d -> %d from node %d", src, link.dest, id)

				proxy, props := pw_link_create(
					cleanup_loop.core,
					src,
					link.dest,
					{{"object.linger", "true"}},
				)
				cleanup_loop.sync = pw.core_sync(cleanup_loop.core, cleanup_loop.sync)
				pw.main_loop_run(cleanup_loop.main_loop)
				pw.proxy_destroy(proxy)
				pw.properties_free(props)

				log.logf(.Info, "link created")
			}
		}
	}

	pw.core_disconnect(cleanup_loop.core)
	pw.context_destroy(cleanup_loop.ctx)
	pw.main_loop_destroy(cleanup_loop.main_loop)
}
