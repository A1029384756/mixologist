package mixologist

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"

@(private = "file")
ctx: ConfigCtx
ConfigCtx :: struct {
	config_file: string,
	volume_file: string,
}

State :: struct {
	rules:       [dynamic]string,
	programs:    [dynamic]string,
	passthrough: [dynamic]string,
	volume:      f32,
	settings:    Settings,
}

StateDirty :: enum {
	Config,
	Volume,
}
StateDirtyFlags :: bit_set[StateDirty]

state_destroy :: proc(state: State) {
	str_arr_delete(state.rules)
	str_arr_delete(state.programs)
}

Config :: struct {
	rules:       [dynamic]string,
	passthrough: [dynamic]string,
	settings:    Settings,
}

Settings :: struct {
	volume_falloff:  VolumeFalloff,
	start_minimized: bool,
	remember_volume: bool,
	autostart:       bool,
}

config_init :: proc() {
	ctx.config_file, _ = os.join_path({directories.config, "mixologist.json"}, context.allocator)
	ctx.volume_file, _ = os.join_path({directories.cache, "mixologist.volume"}, context.allocator)
}

config_fini :: proc() {
	delete(ctx.volume_file)
	delete(ctx.config_file)
}

config_read :: proc() -> (config: Config, ok: bool) {
	config_data, read_err := os.read_entire_file(ctx.config_file, context.temp_allocator)
	if read_err != nil {
		log.errorf("could not read config file: %v, err: %v", ctx.config_file, read_err)
		return
	}

	json_err := json.unmarshal(config_data, &config)
	if json_err != nil {
		log.errorf("could not unmarshal config file: %v", json_err)
		return
	}
	return config, true
}

config_clean :: proc(config: ^Config) {
	for rule, idx in config.rules {
		if len(rule) != 0 do continue
		ordered_remove(&config.rules, idx)
		delete(rule)
	}
}

config_write :: proc(config: Config) {
	log.debug("writing out config")
	config_json, json_err := json.marshal(
		config,
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

config_volume_read :: proc() -> (volume: f32, ok: bool) {
	if !os.exists(ctx.volume_file) do return
	volume_bytes, volume_err := os.read_entire_file(ctx.volume_file, context.temp_allocator)
	if volume_err != nil {
		log.errorf("could not read volume file: %s", volume_err)
		return
	}

	volume, ok = strconv.parse_f32(string(volume_bytes))
	if !ok {
		log.errorf("could not parse volume")
		return
	}
	return
}

config_volume_write :: proc(volume: f32) {
	log.debug("writing out volume")
	volume_buf: [312]byte
	volume_string := fmt.bprintf(volume_buf[:], "%f", volume)
	err := os.write_entire_file(ctx.volume_file, transmute([]u8)volume_string)
	if err != nil {
		log.errorf("could not write volume file: %s", err)
	}
}
