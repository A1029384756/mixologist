package pipewire

spa_json_to_pod_part :: proc(
	b: ^spa_pod_builder,
	flags: SPA_POD_BUILDER_FLAGS,
	id: spa_param_type,
	info: ^spa_type_info,
	iter: ^spa_json,
	value: cstring,
	len: int,
) -> int {
	ti: ^spa_type_info
	key: [256]u8
	f: spa_pod_frame
	it: spa_json
	l, res: int
	v: cstring
	type: u32
	unimplemented()
}

spa_json_next :: proc(iter: ^spa_json, value: ^cstring) -> int {
	unimplemented()
}

spa_json_enter_container :: #force_inline proc(iter: ^spa_json, sub: ^spa_json, type: u8) -> int {
	value: cstring
	unimplemented()
}

spa_json_is_object :: #force_inline proc(val: cstring, len: int) -> int {
	return len > 0 && (transmute([^]u8)val)[0] == '{'
}
