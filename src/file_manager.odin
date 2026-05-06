package mixologist

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:prof/spall"
import "core:strconv"

Config :: struct {
	rules:    [dynamic]string,
	settings: Settings,
}

Settings :: struct {
	volume_falloff:  VolumeFalloff,
	start_minimized: bool,
	remember_volume: bool,
}

FileManager :: struct {
	subscription: Subscriber,
	// file contents
	config:       Config,
	volume:       f32,
	// files
	config_dir:   string,
	config_file:  string,
	volume_file:  string,
}

@(private = "file")
ctx: FileManager

file_manager_init :: proc() {
	subscriber_init(&ctx.subscription, .FileManager, {.Settings, .Rule, .Volume, .Quit})
	bus_subscribe(&bus, ctx.subscription)

	// config file
	user_config_dir, _ := os.user_config_dir(context.temp_allocator)
	ctx.config_dir, _ = os.join_path({user_config_dir, "mixologist"}, context.allocator)
	if !os.exists(ctx.config_dir) {
		config_dir_err := os.make_directory_all(ctx.config_dir)
		if config_dir_err != nil {
			log.panicf("could not create config dir: %v", config_dir_err)
		}
	}
	ctx.config_file, _ = os.join_path({ctx.config_dir, "mixologist.json"}, context.allocator)

	// volume file
	cache_dir, _ := os.user_cache_dir(context.temp_allocator)
	mixologist_cache_dir, _ := os.join_path({cache_dir, "mixologist"}, context.temp_allocator)
	if !os.exists(mixologist_cache_dir) {
		cache_dir_err := os.make_directory_all(mixologist_cache_dir)
		if cache_dir_err != nil {
			log.panicf("could not create cache dir: %v", cache_dir_err)
		}
	}
	ctx.volume_file, _ = os.join_path(
		{mixologist_cache_dir, "mixologist.volume"},
		context.allocator,
	)

	// config loading
	file_manager_config_read(&ctx)
	if ctx.config.settings.remember_volume {
		file_manager_volume_read(&ctx)
	}
}

file_manager_deinit :: proc() {
	subscriber_flush(&ctx.subscription)
	subscriber_destroy(&ctx.subscription)
	delete(ctx.volume_file)
	delete(ctx.config_file)
	delete(ctx.config_dir)
}

file_manager_seed_state :: proc() {
	for rule in ctx.config.rules {
		bus_publish(&bus, {sender = .FileManager, topic = .Rule, list = {kind = .Add, val = rule}})
	}
	bus_publish(&bus, {sender = .FileManager, topic = .Settings, settings = ctx.config.settings})
	bus_publish(
		&bus,
		{sender = .FileManager, topic = .Volume, volume = {kind = .Set, data = ctx.volume}},
	)
}

file_manager_proc :: proc() {
	when PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(os.get_current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
	}

	should_exit := false
	for !should_exit {
		modified_topics: Topics
		for msg in subscriber_poll(&ctx.subscription) {
			modified_topics += {msg.topic}
			#partial switch msg.topic {
			case .Settings:
				ctx.config.settings = msg.settings
			case .Rule:
				modify_string_list(&ctx.config.rules, msg.list)
			case .Volume:
				modify_volume(&ctx.volume, msg.volume)
			case .Quit:
				should_exit = true
			case:
				log.errorf("unexpected \"%v\" message", msg.topic)
			}
			message_unref(msg)
		}

		if modified_topics & {.Settings, .Rule} != {} {
			file_manager_config_write(&ctx)
		}
		if modified_topics & {.Volume} != {} {
			file_manager_volume_write(&ctx)
		}
	}
}

file_manager_config_read :: proc(ctx: ^FileManager) {
	config_data, read_err := os.read_entire_file(ctx.config_file, context.temp_allocator)
	if read_err != nil {
		log.errorf("could not read config file: %v, err: %v", ctx.config_file, read_err)
		return
	}

	json_err := json.unmarshal(config_data, &ctx.config)
	if json_err != nil {
		log.errorf("could not unmarshal config file: %v", json_err)
		return
	}
}

file_manager_config_write :: proc(ctx: ^FileManager) {
	config_json, json_err := json.marshal(
		ctx.config,
		{pretty = true},
		allocator = context.temp_allocator,
	)
	if json_err != nil {
		log.errorf("could not marshal json: %v", json_err)
		return
	}
	write_err := os.write_entire_file(ctx.config_file, config_json)
	if write_err != nil {
		log.errorf("could not write to file: %v, err: %v", ctx.config_file, write_err)
	}
}

file_manager_volume_read :: proc(ctx: ^FileManager) {
	if !os.exists(ctx.volume_file) do return
	volume_bytes, volume_err := os.read_entire_file(ctx.volume_file, context.temp_allocator)
	if volume_err != nil {
		log.errorf("could not read volume file: %s", volume_err)
		return
	}

	volume, volume_parse_ok := strconv.parse_f32(string(volume_bytes))
	if !volume_parse_ok {
		log.errorf("could not parse volume")
		return
	}

	ctx.volume = volume
}

file_manager_volume_write :: proc(ctx: ^FileManager) {
	volume_buf: [312]byte
	volume_string := fmt.bprintf(volume_buf[:], "%f", ctx.volume)
	err := os.write_entire_file(ctx.volume_file, transmute([]u8)volume_string)
	if err != nil {
		log.errorf("could not write volume file: %s", err)
	}
}
