package pipewire

import "base:runtime"
import "core:mem"

SPA_JSON_ERROR_FLAG :: 0x100

SPA_POD_BUILDER_BITS :: enum {
	BODY  = 1 << 0,
	FIRST = 1 << 1,
}

SPA_POD_BUILDER_FLAGS :: bit_set[SPA_POD_BUILDER_BITS;u32]

spa_pod :: struct {
	size: u32,
	type: spa_type,
}

spa_pod_bool :: struct {
	pod:      spa_pod,
	value:    i32,
	_padding: i32,
}

spa_pod_id :: struct {
	pod:      spa_pod,
	value:    u32,
	_padding: i32,
}

spa_pod_int :: struct {
	pod:      spa_pod,
	value:    i32,
	_padding: i32,
}

spa_pod_long :: struct {
	pod:   spa_pod,
	value: i64,
}

spa_pod_float :: struct {
	pod:      spa_pod,
	value:    f32,
	_padding: i32,
}

spa_pod_double :: struct {
	pod:   spa_pod,
	value: f64,
}

spa_pod_string :: struct {
	pod: spa_pod,
	/* value here */
}

spa_pod_bytes :: struct {
	pod: spa_pod,
	/* value here */
}

spa_rectangle :: struct {
	w: u32,
	h: u32,
}

spa_pod_rectangle :: struct {
	pod:   spa_pod,
	value: spa_rectangle,
}

spa_fraction :: struct {
	num:   u32,
	denom: u32,
}

spa_pod_fraction :: struct {
	pod:   spa_pod,
	value: spa_fraction,
}

spa_pod_bitmap :: struct {
	pod: spa_pod,
	/* array of uint8_t follows with the bitmap */
}

spa_pod_object_body :: struct {
	type: spa_type,
	id:   spa_param_type,
}

spa_pod_object :: struct {
	pod:  spa_pod,
	body: spa_pod_object_body,
}

spa_pod_array_body :: struct {
	child: spa_pod,
}

spa_pod_array :: struct {
	pod:  spa_pod,
	body: spa_pod_array_body,
}

spa_choice_type :: enum u32 {
	SPA_CHOICE_None,
	SPA_CHOICE_Range,
	SPA_CHOICE_Step,
	SPA_CHOICE_Enum,
	SPA_CHOICE_Flags,
}

spa_pod_choice_body :: struct {
	type:  spa_choice_type,
	flags: SPA_POD_BUILDER_FLAGS,
	child: spa_pod,
}

spa_pod_choice :: struct {
	pod:  spa_pod,
	body: spa_pod_choice_body,
}

spa_pod_struct :: struct {
	pod: spa_pod,
}

spa_pod_pointer_body :: struct {
	type:     u32,
	_padding: u32,
	value:    rawptr,
}

spa_pod_pointer :: struct {
	pod:  spa_pod,
	body: spa_pod_pointer_body,
}

spa_pod_fd :: struct {
	pod:   spa_pod,
	value: i64,
}

spa_pod_prop :: struct {
	key:   u32,
	flags: u32,
	value: spa_pod,
}

spa_pod_control :: struct {
	offset: u32,
	type:   u32,
	value:  spa_pod,
}

spa_pod_sequence_body :: struct {
	unit: u32,
	pad:  u32,
}

spa_pod_sequence :: struct {
	pod:  spa_pod,
	body: spa_pod_sequence_body,
}

spa_pod_builder :: struct {
	data:      rawptr,
	size:      u32,
	_padding:  u32,
	state:     spa_pod_builder_state,
	callbacks: spa_callbacks,
}

spa_pod_builder_state :: struct {
	offset: u32,
	flags:  SPA_POD_BUILDER_FLAGS,
	frame:  ^spa_pod_frame,
}

spa_pod_builder_callbacks :: struct {
	version:  u32,
	overflow: proc(data: rawptr, size: u32) -> int,
}

spa_pod_frame :: struct {
	pod:    spa_pod,
	parent: ^spa_pod_frame,
	offset: u32,
	flags:  SPA_POD_BUILDER_FLAGS,
}

spa_json :: struct {
	cur:    cstring,
	end:    cstring,
	parent: ^spa_json,
	state:  u32,
	depth:  u32,
}

spa_json_to_pod :: proc(
	b: ^spa_pod_builder,
	flags: u32,
	info: ^spa_type_info,
	value: cstring,
	len: int,
) -> bool {
	unimplemented()
}

spa_json_begin :: proc(iter: ^spa_json, data: cstring, size: uint, val: ^cstring) -> int {
	unimplemented()
}

spa_json_init :: proc(iter: ^spa_json, data: cstring, size: uint) {
	unimplemented()
}

spa_pod_builder_get_state :: proc(b: ^spa_pod_builder, state: ^spa_pod_builder_state) {
	state^ = b.state
}

spa_pod_builder_set_callbacks :: proc(
	b: ^spa_pod_builder,
	callbacks: ^spa_pod_builder_callbacks,
	data: rawptr,
) {
	b.callbacks = spa_callbacks{callbacks, data}
}

spa_pod_builder_reset :: proc(b: ^spa_pod_builder, state: ^spa_pod_builder_state) {
	size := b.state.offset - state.offset
	b.state = state^
	for f := b.state.frame; f != nil; f = f.parent {
		f.pod.size -= size
	}
}

spa_pod_builder_init :: proc(b: ^spa_pod_builder, data: rawptr, size: u32) {
	b^ = spa_pod_builder {
		data = data,
		size = size,
	}
}

spa_pod_builder_deref :: proc(b: ^spa_pod_builder, offset: u32) -> ^spa_pod {
	size := b.size
	if offset + 8 <= size {
		pod := spa_ptroff(b.data, offset, spa_pod)
		if offset + spa_pod_size(pod) <= size {
			return pod
		}
	}
	return nil
}

spa_pod_size :: #force_inline proc(pod: ^spa_pod) -> u32 {
	return size_of(spa_pod) + pod.size
}

spa_pod_builder_frame :: proc(b: ^spa_pod_builder, frame: ^spa_pod_frame) -> ^spa_pod {
	if frame.offset + spa_pod_size(&frame.pod) <= b.size {
		return spa_ptroff(b.data, frame.offset, spa_pod)
	}
	return nil
}

spa_pod_builder_push :: proc(
	b: ^spa_pod_builder,
	frame: ^spa_pod_frame,
	pod: ^spa_pod,
	offset: u32,
) {
	frame.pod = pod^
	frame.offset = offset
	frame.parent = b.state.frame
	frame.flags = b.state.flags
	b.state.frame = frame

	if frame.pod.type == .SPA_TYPE_Array || frame.pod.type == .SPA_TYPE_Choice {
		b.state.flags = {.BODY, .FIRST}
	}
}

spa_pod_builder_raw :: proc(b: ^spa_pod_builder, data: rawptr, size: u32) -> int {
	res: int
	offset := b.state.offset

	if offset + size > b.size {
		res = -28
		if offset <= b.size {
			_f := cast(^spa_pod_builder_callbacks)b.callbacks.funcs
			if _f != nil && _f.version >= 0 && _f.overflow != nil {
				res = _f.overflow((&b.callbacks).data, offset + size)
			} else {
				panic("could not set overflow")
			}
		}
	}
	if res == 0 && data != nil {
		mem.copy(spa_ptroff(b.data, offset, struct {}), data, int(size))
	}

	b.state.offset += size

	for f := b.state.frame; f != nil; f = f.parent {
		f.pod.size += size
	}

	return res
}

spa_pod_builder_pad :: proc(b: ^spa_pod_builder, size: u32) -> int {
	zeros: u64
	size := spa_round_up_n(size, 8) - size
	return size == 0 ? spa_pod_builder_raw(b, &zeros, size) : 0
}

spa_pod_builder_raw_padded :: proc(b: ^spa_pod_builder, data: rawptr, size: u32) -> int {
	res := spa_pod_builder_raw(b, data, size)
	r := spa_pod_builder_pad(b, size)
	if r < 0 {
		res = r
	}
	return res
}

spa_pod_builder_pop :: proc(b: ^spa_pod_builder, frame: ^spa_pod_frame) -> ^spa_pod {
	if .FIRST in b.state.flags {
		p := spa_pod{0, .SPA_TYPE_None}
		spa_pod_builder_raw(b, &p, size_of(p))
	}

	pod := spa_pod_builder_frame(b, frame)
	if pod != nil {
		pod^ = frame.pod
	}

	b.state.frame = frame.parent
	b.state.flags = frame.flags
	spa_pod_builder_pad(b, b.state.offset)
	return pod
}

spa_pod_builder_primitive :: proc(b: ^spa_pod_builder, p: ^spa_pod) -> int {
	data: rawptr
	size: u32
	r, res: int

	if b.state.flags == {.BODY} {
		data = spa_pod_body(p)
		size = p.size
	} else {
		data = p
		size = spa_pod_size(p)
		b.state.flags -= {.FIRST}
	}
	res = spa_pod_builder_raw(b, data, size)
	if b.state.flags != {.BODY} {
		r = spa_pod_builder_pad(b, size)
		if r < 0 {
			res = r
		}
	}
	return res
}

spa_pod_builder_none :: proc(b: ^spa_pod_builder) -> int {
	p := spa_pod{0, .SPA_TYPE_None}
	return spa_pod_builder_primitive(b, &p)
}

spa_pod_builder_child :: proc(b: ^spa_pod_builder, size: u32, type: spa_type) -> int {
	p := spa_pod{size, type}
	b.state.flags -= {.FIRST}
	return spa_pod_builder_raw(b, &p, size_of(p))
}

spa_pod_builder_bool :: proc(b: ^spa_pod_builder, val: bool) -> int {
	p := spa_pod_bool{{size_of(u32), .SPA_TYPE_Bool}, val ? 1 : 0, 0}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_id :: proc(b: ^spa_pod_builder, val: u32) -> int {
	p := spa_pod_id{{size_of(u32), .SPA_TYPE_Id}, val, 0}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_int :: proc(b: ^spa_pod_builder, val: i32) -> int {
	p := spa_pod_int{{size_of(i32), .SPA_TYPE_Int}, val, 0}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_long :: proc(b: ^spa_pod_builder, val: i64) -> int {
	p := spa_pod_long{{size_of(i64), .SPA_TYPE_Long}, val}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_float :: proc(b: ^spa_pod_builder, val: f32) -> int {
	p := spa_pod_float{{size_of(f32), .SPA_TYPE_Float}, val, 0}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_double :: proc(b: ^spa_pod_builder, val: f64) -> int {
	p := spa_pod_double{{size_of(f64), .SPA_TYPE_Double}, val}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_write_string :: proc(b: ^spa_pod_builder, str: cstring, len: u32) -> int {
	res := spa_pod_builder_raw(b, rawptr(str), len)
	blank := ""
	r := spa_pod_builder_raw(b, &blank, 1)
	if r < 0 {
		res = r
	}

	r = spa_pod_builder_pad(b, b.state.offset)
	if r < 0 {
		res = r
	}

	return res
}

spa_pod_builder_string_len :: proc(b: ^spa_pod_builder, str: cstring, len: u32) -> int {
	p := spa_pod_string{{len + 1, .SPA_TYPE_String}}
	res := spa_pod_builder_raw(b, &p, size_of(p))
	r := spa_pod_builder_write_string(b, str, len)
	if r < 0 {
		res = r
	}
	return res
}

spa_pod_builder_string :: proc(b: ^spa_pod_builder, str: cstring) -> int {
	return spa_pod_builder_string_len(b, str != nil ? str : "", str != nil ? u32(len(str)) : 0)
}

spa_pod_builder_bytes :: proc(b: ^spa_pod_builder, bytes: rawptr, len: u32) -> int {
	p := spa_pod_bytes{{len, .SPA_TYPE_Bytes}}
	res := spa_pod_builder_raw(b, &p, size_of(p))
	r := spa_pod_builder_raw_padded(b, bytes, len)
	if r < 0 {
		res = r
	}
	return res
}

spa_pod_builder_reserve_bytes :: proc(b: ^spa_pod_builder, len: u32) -> rawptr {
	offset := b.state.offset
	if spa_pod_builder_bytes(b, nil, len) < 0 {
		return nil
	}
	return spa_pod_body(spa_pod_builder_deref(b, offset))
}

spa_pod_builder_pointer :: proc(b: ^spa_pod_builder, type: u32, val: rawptr) -> int {
	p := spa_pod_pointer{{size_of(spa_pod_pointer_body), .SPA_TYPE_Pointer}, {type, 0, val}}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_fd :: proc(b: ^spa_pod_builder, fd: i64) -> int {
	p := spa_pod_fd{{size_of(i64), .SPA_TYPE_Fd}, fd}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_rectangle :: proc(b: ^spa_pod_builder, w: u32, h: u32) -> int {
	p := spa_pod_rectangle{{size_of(spa_rectangle), .SPA_TYPE_Rectangle}, spa_rectangle{w, h}}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_fraction :: proc(b: ^spa_pod_builder, num: u32, denom: u32) -> int {
	p := spa_pod_fraction{{size_of(spa_fraction), .SPA_TYPE_Fraction}, spa_fraction{num, denom}}
	return spa_pod_builder_primitive(b, &p.pod)
}

spa_pod_builder_push_array :: proc(b: ^spa_pod_builder, frame: ^spa_pod_frame) -> int {
	p := spa_pod_array {
		{size_of(spa_pod_array_body) - size_of(spa_pod), .SPA_TYPE_Array},
		{{0, .SPA_TYPE_START}},
	}
	offset := b.state.offset
	res := spa_pod_builder_raw(b, &p, size_of(p) - size_of(spa_pod))
	spa_pod_builder_push(b, frame, &p.pod, offset)
	return res
}

spa_pod_builder_array :: proc(
	b: ^spa_pod_builder,
	child_size: u32,
	child_type: spa_type,
	n_elems: u32,
	elems: rawptr,
) -> int {
	p := spa_pod_array {
		{(size_of(spa_pod_array_body) + n_elems * child_size), .SPA_TYPE_Array},
		{{child_size, child_type}},
	}
	res := spa_pod_builder_raw(b, &p, size_of(p) - size_of(spa_pod))
	r := spa_pod_builder_raw_padded(b, elems, child_size * n_elems)
	if r < 0 {
		res = r
	}
	return res
}

spa_pod_builder_push_choice :: proc(
	b: ^spa_pod_builder,
	frame: ^spa_pod_frame,
	type: spa_choice_type,
	flags: SPA_POD_BUILDER_FLAGS,
) -> int {
	p := spa_pod_choice {
		{size_of(spa_pod_choice_body) - size_of(spa_pod), .SPA_TYPE_Choice},
		{type, flags, {0, .SPA_TYPE_START}},
	}
	offset := b.state.offset
	res := spa_pod_builder_raw(b, &p, size_of(p) - size_of(spa_pod))
	spa_pod_builder_push(b, frame, &p.pod, offset)
	return res
}

spa_pod_builder_push_struct :: proc(b: ^spa_pod_builder, frame: ^spa_pod_frame) -> int {
	p := spa_pod_struct{{0, .SPA_TYPE_Struct}}
	offset := b.state.offset
	res := spa_pod_builder_raw(b, &p, size_of(p))
	spa_pod_builder_push(b, frame, &p.pod, offset)
	return res
}

spa_pod_builder_push_object :: proc(
	b: ^spa_pod_builder,
	frame: ^spa_pod_frame,
	type: spa_type,
	id: spa_param_type,
) -> int {
	p := spa_pod_object{{size_of(spa_pod_object_body), .SPA_TYPE_Object}, {type, id}}
	offset := b.state.offset
	res := spa_pod_builder_raw(b, &p, size_of(p))
	spa_pod_builder_push(b, frame, &p.pod, offset)
	return res
}

spa_pod_builder_prop :: proc(
	b: ^spa_pod_builder,
	key: spa_prop,
	flags: SPA_POD_BUILDER_FLAGS,
) -> int {
	p: struct {
		key:   spa_prop,
		flags: SPA_POD_BUILDER_FLAGS,
	} = {key, flags}
	return spa_pod_builder_raw(b, &p, size_of(p))
}

spa_pod_builder_push_sequence :: proc(
	b: ^spa_pod_builder,
	frame: ^spa_pod_frame,
	unit: u32,
) -> int {
	p := spa_pod_sequence{{size_of(spa_pod_sequence_body), .SPA_TYPE_Sequence}, {unit, 0}}
	offset := b.state.offset
	res := spa_pod_builder_raw(b, &p, size_of(p))
	spa_pod_builder_push(b, frame, &p.pod, offset)
	return res
}

spa_pod_builder_control :: proc(b: ^spa_pod_builder, offset: u32, type: spa_type) -> int {
	p: struct {
		offset: u32,
		type:   spa_type,
	} = {offset, type}
	return spa_pod_builder_raw(b, &p, size_of(p))
}

spa_choice_from_id :: proc(id: u8) -> spa_choice_type {
	switch id {
	case 'r':
		return .SPA_CHOICE_Range
	case 's':
		return .SPA_CHOICE_Step
	case 'e':
		return .SPA_CHOICE_Enum
	case 'f':
		return .SPA_CHOICE_Flags
	case 'n':
		fallthrough
	case:
		return .SPA_CHOICE_None
	}
}

spa_pod_builder_collect :: proc(b: ^spa_pod_builder, type: u8, args: ^[]any) {
	switch type {
	case 'b':
		arg, _ := get_vararg_checked(args, bool)
		spa_pod_builder_bool(b, arg)
	case 'I':
		arg, _ := get_vararg_checked(args, u32)
		spa_pod_builder_id(b, arg)
	case 'i':
		arg, _ := get_vararg_checked(args, i32)
		spa_pod_builder_int(b, arg)
	case 'l':
		arg, _ := get_vararg_checked(args, i64)
		spa_pod_builder_long(b, arg)
	case 'f':
		arg, _ := get_vararg_checked(args, f64)
		spa_pod_builder_float(b, f32(arg))
	case 'd':
		arg, _ := get_vararg_checked(args, f64)
		spa_pod_builder_double(b, arg)
	case 's':
		strval, strval_err := get_vararg_checked(args, cstring)
		if !strval_err {
			len := len(strval)
			spa_pod_builder_string_len(b, strval, u32(len))
		} else {
			spa_pod_builder_none(b)
		}
	case 'S':
		strval, _ := get_vararg_checked(args, cstring)
		len, _ := get_vararg_checked(args, u32)
		spa_pod_builder_string_len(b, strval, len)
	case 'y':
		ptr, _ := get_vararg_checked(args, rawptr)
		len, _ := get_vararg_checked(args, u32)
		spa_pod_builder_bytes(b, ptr, len)
	case 'R':
		rectval, _ := get_vararg_checked(args, ^spa_rectangle)
		spa_pod_builder_rectangle(b, rectval.w, rectval.h)
	case 'F':
		fractval, _ := get_vararg_checked(args, ^spa_fraction)
		spa_pod_builder_rectangle(b, fractval.num, fractval.denom)
	case 'a':
		child_size, _ := get_vararg_checked(args, u32)
		child_type, _ := get_vararg_checked(args, spa_type)
		n_elems, _ := get_vararg_checked(args, u32)
		elems, _ := get_vararg_checked(args, rawptr)
		spa_pod_builder_array(b, child_size, child_type, n_elems, elems)
	case 'p':
		t, _ := get_vararg_checked(args, u32)
		ptr, _ := get_vararg_checked(args, rawptr)
		spa_pod_builder_pointer(b, t, ptr)
	case 'h':
		fd, _ := get_vararg_checked(args, i64)
		spa_pod_builder_fd(b, fd)
	case 'P', 'O', 'T', 'V':
		pod, pod_err := get_vararg_checked(args, ^spa_pod)
		if pod_err {
			spa_pod_builder_none(b)
		} else {
			spa_pod_builder_primitive(b, pod)
		}
	}
}

spa_pod_builder_addv :: proc(b: ^spa_pod_builder, args: ..any) -> int {
	res: int
	frame := b.state.frame
	ftype: spa_type = frame != nil ? frame.pod.type : .SPA_TYPE_None

	args := args[:]
	arg_parse: for {
		n_values := 1
		f: spa_pod_frame

		#partial switch ftype {
		case .SPA_TYPE_Object:
			key, key_err := get_vararg_checked(&args, spa_prop)
			if key_err || key == .SPA_PROP_START {
				break arg_parse
			}
			spa_pod_builder_prop(b, key, {})
		case .SPA_TYPE_Sequence:
			offset, offset_err := get_vararg_checked(&args, u32)
			type, type_err := get_vararg_checked(&args, spa_type)
			if offset_err || type_err || type == .SPA_TYPE_START {
				break arg_parse
			}
			spa_pod_builder_control(b, offset, type)
		}

		format, _ := get_vararg_checked(&args, [^]u8)
		choice := format[0] == '?'
		if choice {
			format = format[1:]
			type := spa_choice_from_id(format[0])
			if format[0] != 0 {
				format = format[1:]
			}

			spa_pod_builder_push_choice(b, &f, type, {})

			n_values, _ = get_vararg_checked(&args, int)
		}
		for ; n_values > 0; n_values -= 1 {
			spa_pod_builder_collect(b, format[0], &args)
		}

		if choice {
			spa_pod_builder_pop(b, &f)
		}
	}

	return res
}

spa_pod_builder_add :: proc(b: ^spa_pod_builder, args: ..any) -> int {
	return spa_pod_builder_addv(b, args)
}

spa_pod_builder_add_object :: proc(
	b: ^spa_pod_builder,
	type: spa_type,
	id: spa_param_type,
	args: ..any,
) {
	f: spa_pod_frame
	spa_pod_builder_push_object(b, &f, type, id)
	spa_pod_builder_add(b, args)
	spa_pod_builder_pop(b, &f)
}

spa_pod_builder_add_struct :: proc(b: ^spa_pod_builder, args: ..any) {
	f: spa_pod_frame
	spa_pod_builder_push_struct(b, &f)
	spa_pod_builder_add(b, args)
	spa_pod_builder_pop(b, &f)
}

spa_pod_builder_add_sequence :: proc(b: ^spa_pod_builder, unit: u32, args: ..any) {
	f: spa_pod_frame
	spa_pod_builder_push_sequence(b, &f, unit)
	spa_pod_builder_add(b, args)
	spa_pod_builder_pop(b, &f)
}

spa_pod_copy :: proc(pod: ^spa_pod, allocator := context.allocator) -> ^spa_pod {
	size := spa_pod_size(pod)
	c, _ := mem.alloc(int(size), allocator = allocator)
	mem.copy(c, pod, int(size))
	return cast(^spa_pod)c
}

spa_ptroff :: #force_inline proc(ptr: rawptr, offset: u32, $T: typeid) -> ^T {
	return cast(^T)(uintptr(ptr) + uintptr(offset))
}

spa_round_up_n :: #force_inline proc(num: $T, align: T) -> T {
	return ((num - 1) | cast(type_of(num))(align - 1)) + 1
}

spa_pod_body :: #force_inline proc(pod: ^spa_pod) -> rawptr {
	return spa_ptroff(pod, size_of(spa_pod), struct {})
}

get_vararg_checked :: proc(args: ^[]any, $T: typeid) -> (T, bool) {
	if len(args) == 0 {
		return T{}, true
	}

	arg := args[0]
	args^ = args[1:]

	return get_any_checked(arg, T)
}

get_any_checked :: proc(v: any, $T: typeid) -> (T, bool) {
	v := v
	v.id = runtime.typeid_base(v.id)
	switch var in v {
	case T:
		return var, false
	case:
		res: T
		return res, false
	}
}
