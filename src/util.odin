package mixologist

import pw "../pipewire"
import "core:bufio"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os/os2"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

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
	ctx := cast(^Cleanup_Loop)data
	if ctx.sync == seq {
		pw.main_loop_quit(ctx.main_loop)
	}
}

on_error :: proc "c" (data: rawptr, id: u32, seq: c.int, res: c.int, message: cstring) {
	ctx := cast(^Cleanup_Loop)data
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

reset_links :: proc(ctx: ^Daemon_Context) {
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

inotify_event_name :: proc "contextless" (event: ^linux.Inotify_Event) -> cstring {
	return transmute(cstring)uintptr(&event.name)
}

File_Console_Logger_Data :: struct {
	file_handle: ^os2.File,
	ident:       string,
}

create_file_logger :: proc(
	h: ^os2.File,
	lowest := log.Level.Debug,
	opt := log.Default_File_Logger_Opts,
	ident := "",
) -> log.Logger {
	data := new(File_Console_Logger_Data)
	data.file_handle = h
	data.ident = ident
	return log.Logger{file_console_logger_proc, data, lowest, opt}
}

destroy_file_logger :: proc(log: log.Logger) {
	data := cast(^File_Console_Logger_Data)log.data
	if data.file_handle != nil {
		os2.close(data.file_handle)
	}
	free(data)
}

file_console_logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	data := cast(^File_Console_Logger_Data)logger_data
	h := os2.stdout if level <= log.Level.Error else os2.stderr
	if data.file_handle != nil {
		h = data.file_handle
	}
	backing: [1024]byte //NOTE(Hoej): 1024 might be too much for a header backing, unless somebody has really long paths.
	buf := strings.builder_from_bytes(backing[:])

	log.do_level_header(options, &buf, level)

	when time.IS_SUPPORTED {
		log.do_time_header(options, &buf, time.now())
	}

	log.do_location_header(options, &buf, location)

	if .Thread_Id in options {
		// NOTE(Oskar): not using context.thread_id here since that could be
		// incorrect when replacing context for a thread.
		fmt.sbprintf(&buf, "[{}] ", linux.gettid())
	}

	if data.ident != "" {
		fmt.sbprintf(&buf, "[%s] ", data.ident)
	}

	//TODO(Hoej): When we have better atomics and such, make this thread-safe
	fprintf(h, "%s%s\n", strings.to_string(buf), text)
}

fprintf :: proc(
	fd: ^os2.File,
	format: string,
	args: ..any,
	flush := true,
	newline := false,
) -> int {
	buf: [1024]byte
	b: bufio.Writer
	defer bufio.writer_flush(&b)

	bufio.writer_init_with_buf(&b, os2.to_stream(fd), buf[:])

	w := bufio.writer_to_writer(&b)
	return fmt.wprintf(w, format, ..args, flush = flush, newline = newline)
}

string_subst_bytes :: proc(input: string, og, replacement: byte) {
	input_bytes := transmute([]u8)input
	for &input_byte in input_bytes {
		if input_byte == og do input_byte = replacement
	}
}
