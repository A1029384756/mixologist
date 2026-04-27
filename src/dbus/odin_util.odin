package dbus

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"

@(deferred_in = message_iter_pop_container)
message_iter_push_container :: proc(
	base: ^MessageIter,
	type: Type,
	contained: cstring,
	sub: ^MessageIter,
) -> bool_t {
	return message_iter_open_container(base, type, contained, sub)
}

message_iter_pop_container :: proc(
	base: ^MessageIter,
	_type: Type,
	_contained: cstring,
	sub: ^MessageIter,
) {
	message_iter_close_container(base, sub)
}

Marshal_Error :: enum {
	None,
	Unsupported_Type,
	Signature_Mismatch,
	Truncated_Signature,
	Iter_Op_Failed,
	Missing_Tag,
	Allocation_Failed,
}

@(private = "file")
sig_count :: proc(signature: string) -> (count: int, ok: bool) {
	pos := 0
	for pos < len(signature) {
		_, next, seg_ok := sig_next(signature, pos)
		if !seg_ok do return 0, false
		count += 1
		pos = next
	}
	return count, true
}

marshal :: proc(
	it: ^MessageIter,
	signature: string,
	value: any,
	allocator := context.allocator,
) -> Marshal_Error {
	n_segs, ok := sig_count(signature)
	if !ok || n_segs == 0 do return .Truncated_Signature

	if n_segs == 1 {
		seg, _, _ := sig_next(signature, 0)
		return marshal_segment(it, seg, value, allocator)
	}

	base := reflect.type_info_base(type_info_of(value.id))
	val := any{value.data, base.id}
	s, is_struct := base.variant.(runtime.Type_Info_Struct)
	if !is_struct || int(s.field_count) != n_segs do return .Signature_Mismatch

	pos := 0
	for i in 0 ..< int(s.field_count) {
		seg, next, _ := sig_next(signature, pos)
		field := reflect.struct_field_at(val.id, i)
		field_val := reflect.struct_field_value(val, field)
		if err := marshal_segment(it, seg, field_val, allocator); err != .None do return err
		pos = next
	}
	return .None
}

unmarshal :: proc(
	it: ^MessageIter,
	signature: string,
	ptr: ^$T,
	allocator := context.allocator,
) -> Marshal_Error {
	n_segs, ok := sig_count(signature)
	if !ok || n_segs == 0 do return .Truncated_Signature
	dst := any{ptr, typeid_of(T)}

	if n_segs == 1 {
		seg, _, _ := sig_next(signature, 0)
		return unmarshal_segment(it, seg, dst, allocator)
	}

	base := reflect.type_info_base(type_info_of(T))
	val := any{ptr, base.id}
	s, is_struct := base.variant.(runtime.Type_Info_Struct)
	if !is_struct || int(s.field_count) != n_segs do return .Signature_Mismatch

	pos := 0
	for i in 0 ..< int(s.field_count) {
		seg, next, _ := sig_next(signature, pos)
		field := reflect.struct_field_at(val.id, i)
		field_val := reflect.struct_field_value(val, field)
		if err := unmarshal_segment(it, seg, field_val, allocator); err != .None do return err
		pos = next
		if i < int(s.field_count) - 1 do message_iter_next(it)
	}
	return .None
}

sig_next :: proc(sig: string, start: int) -> (segment: string, next: int, ok: bool) {
	if start >= len(sig) do return
	switch sig[start] {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v':
		return sig[start:start + 1], start + 1, true
	case 'a':
		_, after := sig_next(sig, start + 1) or_return
		return sig[start:after], after, true
	case '(', '{':
		close_char: byte = sig[start] == '(' ? ')' : '}'
		depth := 1
		i := start + 1
		for i < len(sig) {
			c := sig[i]
			if c == '(' || c == '{' {
				depth += 1
			} else if c == ')' || c == '}' {
				depth -= 1
				if depth == 0 && c == close_char {
					return sig[start:i + 1], i + 1, true
				}
			}
			i += 1
		}
	}
	return
}

marshal_segment :: proc(
	it: ^MessageIter,
	sig: string,
	value: any,
	allocator := context.allocator,
) -> Marshal_Error {
	if len(sig) == 0 {
		return .Truncated_Signature
	}

	base := reflect.type_info_base(type_info_of(value.id))
	val := any{value.data, base.id}

	switch sig[0] {
	case 'y':
		bv: BasicValue
		bv.byt = (^byte)(val.data)^
		if !message_iter_append_basic(it, .BYTE, &bv.byt) do return .Iter_Op_Failed
	case 'b':
		bv: BasicValue
		bv.bool_val = bool_t((^bool)(val.data)^)
		if !message_iter_append_basic(it, .BOOLEAN, &bv.bool_val) do return .Iter_Op_Failed
	case 'n':
		bv: BasicValue
		bv.int16 = (^i16)(val.data)^
		if !message_iter_append_basic(it, .INT16, &bv.int16) do return .Iter_Op_Failed
	case 'q':
		bv: BasicValue
		bv.uint16 = (^u16)(val.data)^
		if !message_iter_append_basic(it, .UINT16, &bv.uint16) do return .Iter_Op_Failed
	case 'i':
		bv: BasicValue
		bv.int32 = (^i32)(val.data)^
		if !message_iter_append_basic(it, .INT32, &bv.int32) do return .Iter_Op_Failed
	case 'u':
		bv: BasicValue
		bv.uint32 = (^u32)(val.data)^
		if !message_iter_append_basic(it, .UINT32, &bv.uint32) do return .Iter_Op_Failed
	case 'x':
		bv: BasicValue
		bv.int64 = (^i64)(val.data)^
		if !message_iter_append_basic(it, .INT64, &bv.int64) do return .Iter_Op_Failed
	case 't':
		bv: BasicValue
		bv.uint64 = (^u64)(val.data)^
		if !message_iter_append_basic(it, .UINT64, &bv.uint64) do return .Iter_Op_Failed
	case 'd':
		bv: BasicValue
		bv.dbl = (^f64)(val.data)^
		if !message_iter_append_basic(it, .DOUBLE, &bv.dbl) do return .Iter_Op_Failed
	case 'h':
		bv: BasicValue
		bv.fd = (^i32)(val.data)^
		if !message_iter_append_basic(it, .UNIX_FD, &bv.fd) do return .Iter_Op_Failed
	case 's', 'o', 'g':
		cs := value_to_cstring(val, allocator) or_return
		if !message_iter_append_basic(it, Type(sig[0]), &cs) do return .Iter_Op_Failed
	case 'a':
		return marshal_array(it, sig, val, allocator)
	case '(':
		return marshal_struct(it, sig, val)
	case 'v':
		return .Signature_Mismatch
	case:
		return .Unsupported_Type
	}
	return nil
}

@(private = "file")
value_to_cstring :: proc(val: any, allocator: runtime.Allocator) -> (cstring, Marshal_Error) {
	base := reflect.type_info_base(type_info_of(val.id))
	if s, ok := base.variant.(runtime.Type_Info_String); ok {
		if s.is_cstring do return (^cstring)(val.data)^, nil
		str := (^string)(val.data)^
		return strings.clone_to_cstring(str, allocator), nil
	}
	return "", .Signature_Mismatch
}

@(private = "file")
marshal_array :: proc(
	it: ^MessageIter,
	sig: string,
	val: any,
	allocator: runtime.Allocator,
) -> (
	err: Marshal_Error,
) {
	inner := sig[1:]
	if len(inner) == 0 {
		return .Truncated_Signature
	}
	inner_cstr := strings.clone_to_cstring(inner, allocator)
	sub: MessageIter
	if !message_iter_open_container(it, .ARRAY, inner_cstr, &sub) {
		return .Iter_Op_Failed
	}

	if inner[0] == '{' {
		base := reflect.type_info_base(type_info_of(val.id))
		#partial switch _ in base.variant {
		case runtime.Type_Info_Struct:
			err = marshal_a_sv_struct(&sub, inner, val, allocator)
		case:
			err = .Unsupported_Type
		}
	} else {
		n := reflect.length(val)
		for i in 0 ..< n {
			elem := reflect.index(val, i)
			err = marshal_segment(&sub, inner, elem)
			if err != nil do break
		}
	}

	if err != nil {
		message_iter_abandon_container(it, &sub)
		return
	}
	if !message_iter_close_container(it, &sub) do return .Iter_Op_Failed
	return
}

@(private = "file")
marshal_a_sv_struct :: proc(
	arr_it: ^MessageIter,
	dict_sig: string,
	val: any,
	allocator: runtime.Allocator,
) -> (
	err: Marshal_Error,
) {
	if dict_sig != "{sv}" {
		return .Unsupported_Type
	}
	base := reflect.type_info_base(type_info_of(val.id))
	s := base.variant.(runtime.Type_Info_Struct)

	for i in 0 ..< int(s.field_count) {
		field := reflect.struct_field_at(val.id, i)
		dbus_tag := reflect.struct_tag_get(field.tag, "dbus")
		name_tag := reflect.struct_tag_get(field.tag, "dbus_name")
		if len(dbus_tag) == 0 || len(name_tag) == 0 {
			return .Missing_Tag
		}

		entry: MessageIter
		if !message_iter_open_container(arr_it, .DICT_ENTRY, nil, &entry) {
			return .Iter_Op_Failed
		}

		key_cstr := strings.clone_to_cstring(string(name_tag), allocator)
		if !message_iter_append_basic(&entry, .STRING, &key_cstr) {
			message_iter_abandon_container(arr_it, &entry)
			return .Iter_Op_Failed
		}

		var_sig := strings.clone_to_cstring(string(dbus_tag), allocator)
		var_it: MessageIter
		if !message_iter_open_container(&entry, .VARIANT, var_sig, &var_it) {
			message_iter_abandon_container(arr_it, &entry)
			return .Iter_Op_Failed
		}

		field_val := reflect.struct_field_value(val, field)
		err = marshal_segment(&var_it, string(dbus_tag), field_val)
		if err != nil {
			message_iter_abandon_container(&entry, &var_it)
			message_iter_abandon_container(arr_it, &entry)
			return
		}

		if !message_iter_close_container(&entry, &var_it) {
			return .Iter_Op_Failed
		}
		if !message_iter_close_container(arr_it, &entry) {
			return .Iter_Op_Failed
		}
	}
	return
}

@(private = "file")
marshal_struct :: proc(it: ^MessageIter, sig: string, val: any) -> (err: Marshal_Error) {
	inner := sig[1:len(sig) - 1]
	base := reflect.type_info_base(type_info_of(val.id))
	s, ok := base.variant.(runtime.Type_Info_Struct)
	if !ok {
		return .Signature_Mismatch
	}

	sub: MessageIter
	if !message_iter_open_container(it, .STRUCT, nil, &sub) {
		return .Iter_Op_Failed
	}

	pos := 0
	for i in 0 ..< int(s.field_count) {
		seg, next, seg_ok := sig_next(inner, pos)
		if !seg_ok {
			return .Signature_Mismatch
		}
		field := reflect.struct_field_at(val.id, i)
		field_val := reflect.struct_field_value(val, field)
		err = marshal_segment(&sub, seg, field_val)
		if err != nil do break
		pos = next
	}
	if err == nil && pos != len(inner) do err = .Signature_Mismatch

	if err != nil {
		message_iter_abandon_container(it, &sub)
		return
	}
	if !message_iter_close_container(it, &sub) do return .Iter_Op_Failed
	return
}

unmarshal_segment :: proc(
	it: ^MessageIter,
	sig: string,
	dst: any,
	allocator: runtime.Allocator,
) -> Marshal_Error {
	if len(sig) == 0 {
		return .Truncated_Signature
	}

	base := reflect.type_info_base(type_info_of(dst.id))
	val := any{dst.data, base.id}

	switch sig[0] {
	case 'y':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^byte)(val.data)^ = bv.byt
	case 'b':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^bool)(val.data)^ = bool(bv.bool_val)
	case 'n':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^i16)(val.data)^ = bv.int16
	case 'q':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^u16)(val.data)^ = bv.uint16
	case 'i':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^i32)(val.data)^ = bv.int32
	case 'u':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^u32)(val.data)^ = bv.uint32
	case 'x':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^i64)(val.data)^ = bv.int64
	case 't':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^u64)(val.data)^ = bv.uint64
	case 'd':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^f64)(val.data)^ = bv.dbl
	case 'h':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^i32)(val.data)^ = bv.fd
	case 's', 'o', 'g':
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		s, ok := base.variant.(runtime.Type_Info_String)
		if !ok {
			return .Signature_Mismatch
		}
		if s.is_cstring {
			(^cstring)(val.data)^ = strings.clone_to_cstring(string(bv.str), allocator)
		} else {
			(^string)(val.data)^ = strings.clone(string(bv.str), allocator)
		}
	case 'a':
		return unmarshal_array(it, sig, val, allocator)
	case '(':
		return unmarshal_struct(it, sig, val, allocator)
	case 'v':
		return unmarshal_variant(it, val, allocator)
	case:
		return .Unsupported_Type
	}
	return nil
}

@(private = "file")
unmarshal_array :: proc(
	it: ^MessageIter,
	sig: string,
	val: any,
	allocator: runtime.Allocator,
) -> (
	err: Marshal_Error,
) {
	inner := sig[1:]
	if len(inner) == 0 {
		return .Truncated_Signature
	}
	count := int(message_iter_get_element_count(it))
	sub: MessageIter
	message_iter_recurse(it, &sub)

	if inner[0] == '{' {
		base := reflect.type_info_base(type_info_of(val.id))
		#partial switch _ in base.variant {
		case runtime.Type_Info_Struct:
			err = unmarshal_a_sv_struct(&sub, val, allocator)
		case:
			err = .Unsupported_Type
		}
		return
	}

	base := reflect.type_info_base(type_info_of(val.id))
	sl, is_slice := base.variant.(runtime.Type_Info_Slice)
	if !is_slice {
		return .Signature_Mismatch
	}

	bytes, alloc_err := mem.alloc_bytes(count * sl.elem.size, sl.elem.align, allocator)
	if alloc_err != nil {
		return .Allocation_Failed
	}
	raw := (^runtime.Raw_Slice)(val.data)
	raw.data = raw_data(bytes)
	raw.len = count

	for i in 0 ..< count {
		elem_data := rawptr(uintptr(raw.data) + uintptr(sl.elem.size * i))
		elem := any{elem_data, sl.elem.id}
		unmarshal_segment(&sub, inner, elem, allocator) or_return
		if i < count - 1 do message_iter_next(&sub)
	}
	return nil
}

@(private = "file")
unmarshal_a_sv_struct :: proc(
	dict_arr_it: ^MessageIter,
	val: any,
	allocator: runtime.Allocator,
) -> (
	err: Marshal_Error,
) {
	base := reflect.type_info_base(type_info_of(val.id))
	s := base.variant.(runtime.Type_Info_Struct)

	for message_iter_get_arg_type(dict_arr_it) != .INVALID {
		entry: MessageIter
		message_iter_recurse(dict_arr_it, &entry)

		bv: BasicValue
		message_iter_get_basic(&entry, &bv)
		key := string(bv.str)
		message_iter_next(&entry)

		field_idx := -1
		for i in 0 ..< int(s.field_count) {
			f := reflect.struct_field_at(val.id, i)
			if reflect.struct_tag_get(f.tag, "dbus_name") == key {
				field_idx = i
				break
			}
		}

		if field_idx >= 0 {
			field := reflect.struct_field_at(val.id, field_idx)
			field_val := reflect.struct_field_value(val, field)
			var_it: MessageIter
			message_iter_recurse(&entry, &var_it)
			actual_sig := string(message_iter_get_signature(&var_it))
			unmarshal_segment(&var_it, actual_sig, field_val, allocator) or_return
		}

		message_iter_next(dict_arr_it)
	}
	return nil
}

@(private = "file")
unmarshal_struct :: proc(
	it: ^MessageIter,
	sig: string,
	val: any,
	allocator: runtime.Allocator,
) -> (
	err: Marshal_Error,
) {
	inner := sig[1:len(sig) - 1]
	base := reflect.type_info_base(type_info_of(val.id))
	s, ok := base.variant.(runtime.Type_Info_Struct)
	if !ok {
		return .Signature_Mismatch
	}

	sub: MessageIter
	message_iter_recurse(it, &sub)

	pos := 0
	for i in 0 ..< int(s.field_count) {
		seg, next, seg_ok := sig_next(inner, pos)
		if !seg_ok {
			return .Signature_Mismatch
		}
		field := reflect.struct_field_at(val.id, i)
		field_val := reflect.struct_field_value(val, field)
		unmarshal_segment(&sub, seg, field_val, allocator) or_return
		pos = next
		if i < int(s.field_count) - 1 do message_iter_next(&sub)
	}
	return nil
}

@(private = "file")
unmarshal_variant :: proc(
	it: ^MessageIter,
	val: any,
	allocator: runtime.Allocator,
) -> Marshal_Error {
	sub: MessageIter
	message_iter_recurse(it, &sub)
	actual := string(message_iter_get_signature(&sub))
	return unmarshal_segment(&sub, actual, val, allocator)
}
