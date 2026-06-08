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

MarshalError :: enum {
	None,
	Unsupported_Type,
	Signature_Mismatch,
	Iter_Op_Failed,
	Allocation_Failed,
}

ObjectPath :: distinct string
SignatureString :: distinct string
Fd :: distinct i32

marshal :: proc(
	msg: ^Message,
	value: any,
	temp_allocator := context.temp_allocator,
) -> MarshalError {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	it: MessageIter
	message_iter_init_append(msg, &it)

	base := reflect.type_info_base(type_info_of(value.id))
	val := any{value.data, base.id}
	if s, is_struct := base.variant.(runtime.Type_Info_Struct); is_struct {
		for i in 0 ..< int(s.field_count) {
			field := reflect.struct_field_at(val.id, i)
			marshal_field(&it, field, val, temp_allocator) or_return
		}
		return .None
	}
	return marshal_any(&it, value, temp_allocator)
}

unmarshal :: proc(msg: ^Message, ptr: ^$T, allocator := context.allocator) -> MarshalError {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	it: MessageIter
	message_iter_init(msg, &it)

	base := reflect.type_info_base(type_info_of(T))
	val := any{ptr, base.id}
	if s, is_struct := base.variant.(runtime.Type_Info_Struct); is_struct {
		for i in 0 ..< int(s.field_count) {
			field := reflect.struct_field_at(val.id, i)
			unmarshal_field(&it, field, val, allocator) or_return
			if i < int(s.field_count) - 1 do message_iter_next(&it)
		}
		return .None
	}
	dst := any{ptr, typeid_of(T)}
	return unmarshal_any(&it, dst, allocator)
}

@(private = "file")
sig_for_type :: proc(
	t: typeid,
	temp_allocator: runtime.Allocator,
) -> (
	sig: string,
	err: MarshalError,
) {
	if t == typeid_of(ObjectPath) do return "o", .None
	if t == typeid_of(SignatureString) do return "g", .None
	if t == typeid_of(Fd) do return "h", .None

	ti := reflect.type_info_base(type_info_of(t))
	#partial switch info in ti.variant {
	case runtime.Type_Info_Boolean:
		return "b", .None
	case runtime.Type_Info_Integer:
		switch ti.size {
		case 1:
			return "y", .None
		case 2:
			return info.signed ? "n" : "q", .None
		case 4:
			return info.signed ? "i" : "u", .None
		case 8:
			return info.signed ? "x" : "t", .None
		}
		return "", .Unsupported_Type
	case runtime.Type_Info_Float:
		if ti.size == 8 do return "d", .None
		return "", .Unsupported_Type
	case runtime.Type_Info_String:
		return "s", .None
	case runtime.Type_Info_Slice:
		inner := sig_for_type(info.elem.id, temp_allocator) or_return
		return strings.concatenate({"a", inner}, temp_allocator), .None
	case runtime.Type_Info_Array:
		inner := sig_for_type(info.elem.id, temp_allocator) or_return
		return strings.concatenate({"a", inner}, temp_allocator), .None
	case runtime.Type_Info_Dynamic_Array:
		inner := sig_for_type(info.elem.id, temp_allocator) or_return
		return strings.concatenate({"a", inner}, temp_allocator), .None
	case runtime.Type_Info_Struct:
		b := strings.builder_make(temp_allocator)
		strings.write_byte(&b, '(')
		for i in 0 ..< int(info.field_count) {
			f := reflect.struct_field_at(t, i)
			seg := sig_for_field(f, temp_allocator) or_return
			strings.write_string(&b, seg)
		}
		strings.write_byte(&b, ')')
		return strings.to_string(b), .None
	}
	return "", .Unsupported_Type
}

@(private = "file")
sig_for_field :: proc(
	field: reflect.Struct_Field,
	temp_allocator: runtime.Allocator,
) -> (
	string,
	MarshalError,
) {
	if t := reflect.struct_tag_get(field.tag, "dbus"); len(t) > 0 do return string(t), .None
	return sig_for_type(field.type.id, temp_allocator)
}

@(private = "file")
marshal_field :: proc(
	it: ^MessageIter,
	field: reflect.Struct_Field,
	parent: any,
	temp_allocator: runtime.Allocator,
) -> MarshalError {
	field_val := reflect.struct_field_value(parent, field)
	tag := string(reflect.struct_tag_get(field.tag, "dbus"))

	if len(tag) >= 2 && tag[0] == 'a' && tag[1] == '{' {
		return marshal_property_dict(it, field_val, tag, temp_allocator)
	}
	if tag == "o" do return marshal_basic_string(it, field_val, .OBJECT_PATH, temp_allocator)
	if tag == "g" do return marshal_basic_string(it, field_val, .SIGNATURE, temp_allocator)
	return marshal_any(it, field_val, temp_allocator)
}

@(private = "file")
marshal_any :: proc(
	it: ^MessageIter,
	value: any,
	temp_allocator: runtime.Allocator,
) -> MarshalError {
	if value.id == typeid_of(ObjectPath) {
		return marshal_basic_string(it, value, .OBJECT_PATH, temp_allocator)
	}
	if value.id == typeid_of(SignatureString) {
		return marshal_basic_string(it, value, .SIGNATURE, temp_allocator)
	}
	if value.id == typeid_of(Fd) {
		bv: BasicValue
		bv.fd = (^i32)(value.data)^
		if !message_iter_append_basic(it, .UNIX_FD, &bv.fd) do return .Iter_Op_Failed
		return .None
	}

	base := reflect.type_info_base(type_info_of(value.id))
	val := any{value.data, base.id}

	#partial switch info in base.variant {
	case runtime.Type_Info_Integer:
		bv: BasicValue
		switch base.size {
		case 1:
			bv.byt = (^byte)(val.data)^
			if !message_iter_append_basic(it, .BYTE, &bv.byt) do return .Iter_Op_Failed
		case 2:
			if info.signed {
				bv.int16 = (^i16)(val.data)^
				if !message_iter_append_basic(it, .INT16, &bv.int16) do return .Iter_Op_Failed
			} else {
				bv.uint16 = (^u16)(val.data)^
				if !message_iter_append_basic(it, .UINT16, &bv.uint16) do return .Iter_Op_Failed
			}
		case 4:
			if info.signed {
				bv.int32 = (^i32)(val.data)^
				if !message_iter_append_basic(it, .INT32, &bv.int32) do return .Iter_Op_Failed
			} else {
				bv.uint32 = (^u32)(val.data)^
				if !message_iter_append_basic(it, .UINT32, &bv.uint32) do return .Iter_Op_Failed
			}
		case 8:
			if info.signed {
				bv.int64 = (^i64)(val.data)^
				if !message_iter_append_basic(it, .INT64, &bv.int64) do return .Iter_Op_Failed
			} else {
				bv.uint64 = (^u64)(val.data)^
				if !message_iter_append_basic(it, .UINT64, &bv.uint64) do return .Iter_Op_Failed
			}
		case:
			return .Unsupported_Type
		}
	case runtime.Type_Info_Enum:
		t: Type
		if base.size == 1 {
			t = .BYTE
		} else if base.size == 2 {
			t = .INT16
		} else if base.size == 4 {
			t = .INT32
		} else if base.size == 8 {
			t = .INT64
		} else {
			return .Unsupported_Type
		}
		if !message_iter_append_basic(it, t, val.data) do return .Iter_Op_Failed
	case runtime.Type_Info_Boolean:
		bv: BasicValue
		bv.bool_val = bool_t((^bool)(val.data)^)
		if !message_iter_append_basic(it, .BOOLEAN, &bv.bool_val) do return .Iter_Op_Failed
	case runtime.Type_Info_Float:
		bv: BasicValue
		if base.size == 8 {
			bv.dbl = (^f64)(val.data)^
		} else if base.size == 4 {
			val := (^f32)(val.data)^
			bv.dbl = f64(val)
		} else if base.size == 2 {
			val := (^f16)(val.data)^
			bv.dbl = f64(val)
		} else {
			return .Unsupported_Type
		}
		if !message_iter_append_basic(it, .DOUBLE, &bv.dbl) do return .Iter_Op_Failed
	case runtime.Type_Info_String:
		return marshal_basic_string(it, val, .STRING, temp_allocator)
	case runtime.Type_Info_Slice, runtime.Type_Info_Array, runtime.Type_Info_Dynamic_Array:
		return marshal_array(it, val, temp_allocator)
	case runtime.Type_Info_Struct:
		return marshal_struct(it, val, temp_allocator)
	case:
		return .Unsupported_Type
	}
	return .None
}

@(private = "file")
marshal_basic_string :: proc(
	it: ^MessageIter,
	val: any,
	t: Type,
	temp_allocator: runtime.Allocator,
) -> MarshalError {
	cs := value_to_cstring(val, temp_allocator) or_return
	if !message_iter_append_basic(it, t, &cs) do return .Iter_Op_Failed
	return .None
}

@(private = "file")
value_to_cstring :: proc(val: any, temp_allocator: runtime.Allocator) -> (cstring, MarshalError) {
	base := reflect.type_info_base(type_info_of(val.id))
	if s, ok := base.variant.(runtime.Type_Info_String); ok {
		if s.is_cstring do return (^cstring)(val.data)^, .None
		str := (^string)(val.data)^
		return strings.clone_to_cstring(str, temp_allocator), .None
	}
	return "", .Signature_Mismatch
}

@(private = "file")
marshal_array :: proc(
	it: ^MessageIter,
	val: any,
	temp_allocator: runtime.Allocator,
) -> (
	err: MarshalError,
) {
	base := reflect.type_info_base(type_info_of(val.id))
	elem_id: typeid
	#partial switch info in base.variant {
	case runtime.Type_Info_Slice:
		elem_id = info.elem.id
	case runtime.Type_Info_Array:
		elem_id = info.elem.id
	case runtime.Type_Info_Dynamic_Array:
		elem_id = info.elem.id
	case:
		return .Signature_Mismatch
	}

	inner := sig_for_type(elem_id, temp_allocator) or_return
	inner_cstr := strings.clone_to_cstring(inner, temp_allocator)

	sub: MessageIter
	if !message_iter_open_container(it, .ARRAY, inner_cstr, &sub) do return .Iter_Op_Failed

	n := reflect.length(val)
	for i in 0 ..< n {
		elem := reflect.index(val, i)
		err = marshal_any(&sub, elem, temp_allocator)
		if err != .None do break
	}

	if err != .None {
		message_iter_abandon_container(it, &sub)
		return
	}
	if !message_iter_close_container(it, &sub) do return .Iter_Op_Failed
	return
}

@(private = "file")
marshal_struct :: proc(
	it: ^MessageIter,
	val: any,
	temp_allocator: runtime.Allocator,
) -> (
	err: MarshalError,
) {
	base := reflect.type_info_base(type_info_of(val.id))
	s, ok := base.variant.(runtime.Type_Info_Struct)
	if !ok do return .Signature_Mismatch

	sub: MessageIter
	if !message_iter_open_container(it, .STRUCT, nil, &sub) do return .Iter_Op_Failed

	parent := any{val.data, base.id}
	for i in 0 ..< int(s.field_count) {
		field := reflect.struct_field_at(parent.id, i)
		err = marshal_field(&sub, field, parent, temp_allocator)
		if err != .None do break
	}

	if err != .None {
		message_iter_abandon_container(it, &sub)
		return
	}
	if !message_iter_close_container(it, &sub) do return .Iter_Op_Failed
	return
}

@(private = "file")
marshal_property_dict :: proc(
	it: ^MessageIter,
	val: any,
	array_sig: string,
	temp_allocator: runtime.Allocator,
) -> MarshalError {
	if len(array_sig) < 2 || array_sig[0] != 'a' do return .Signature_Mismatch
	inner := array_sig[1:]
	inner_cstr := strings.clone_to_cstring(inner, temp_allocator)

	sub: MessageIter
	if !message_iter_open_container(it, .ARRAY, inner_cstr, &sub) do return .Iter_Op_Failed

	base := reflect.type_info_base(type_info_of(val.id))
	s, is_struct := base.variant.(runtime.Type_Info_Struct)
	if !is_struct {
		message_iter_abandon_container(it, &sub)
		return .Signature_Mismatch
	}

	parent := any{val.data, base.id}
	for i in 0 ..< int(s.field_count) {
		field := reflect.struct_field_at(parent.id, i)

		name_tag := string(reflect.struct_tag_get(field.tag, "dbus_name"))
		key := len(name_tag) > 0 ? name_tag : field.name

		var_sig := sig_for_field(field, temp_allocator) or_return

		field_val := reflect.struct_field_value(parent, field)
		base := reflect.type_info_base(type_info_of(field_val.id))
		is_empty := true
		for idx: uintptr = uintptr(field_val.data);
		    idx < uintptr(field_val.data) + uintptr(base.size);
		    idx += 1 {
			if (cast(^u8)idx)^ != 0 {
				is_empty = false
				break
			}
		}
		omit_tag := string(reflect.struct_tag_get(field.tag, "dbus"))
		if omit_tag == "omitempty" && is_empty {
			continue
		}

		entry: MessageIter
		if !message_iter_open_container(&sub, .DICT_ENTRY, nil, &entry) {
			message_iter_abandon_container(it, &sub)
			return .Iter_Op_Failed
		}

		key_cstr := strings.clone_to_cstring(key, temp_allocator)
		if !message_iter_append_basic(&entry, .STRING, &key_cstr) {
			message_iter_abandon_container(&sub, &entry)
			message_iter_abandon_container(it, &sub)
			return .Iter_Op_Failed
		}

		var_sig_cstr := strings.clone_to_cstring(var_sig, temp_allocator)
		var_it: MessageIter
		if !message_iter_open_container(&entry, .VARIANT, var_sig_cstr, &var_it) {
			message_iter_abandon_container(&sub, &entry)
			message_iter_abandon_container(it, &sub)
			return .Iter_Op_Failed
		}

		ferr: MarshalError
		if len(var_sig) >= 2 && var_sig[0] == 'a' && var_sig[1] == '{' {
			ferr = marshal_property_dict(&var_it, field_val, var_sig, temp_allocator)
		} else if var_sig == "o" {
			ferr = marshal_basic_string(&var_it, field_val, .OBJECT_PATH, temp_allocator)
		} else if var_sig == "g" {
			ferr = marshal_basic_string(&var_it, field_val, .SIGNATURE, temp_allocator)
		} else {
			ferr = marshal_any(&var_it, field_val, temp_allocator)
		}
		if ferr != .None {
			message_iter_abandon_container(&entry, &var_it)
			message_iter_abandon_container(&sub, &entry)
			message_iter_abandon_container(it, &sub)
			return ferr
		}

		if !message_iter_close_container(&entry, &var_it) do return .Iter_Op_Failed
		if !message_iter_close_container(&sub, &entry) do return .Iter_Op_Failed
	}

	if !message_iter_close_container(it, &sub) do return .Iter_Op_Failed
	return .None
}

@(private = "file")
unmarshal_field :: proc(
	it: ^MessageIter,
	field: reflect.Struct_Field,
	parent: any,
	allocator: runtime.Allocator,
) -> MarshalError {
	field_dst := reflect.struct_field_value(parent, field)
	tag := string(reflect.struct_tag_get(field.tag, "dbus"))

	if len(tag) >= 2 && tag[0] == 'a' && tag[1] == '{' {
		return unmarshal_property_dict(it, field_dst, allocator)
	}
	return unmarshal_any(it, field_dst, allocator)
}

@(private = "file")
unmarshal_any :: proc(it: ^MessageIter, dst: any, allocator: runtime.Allocator) -> MarshalError {
	base := reflect.type_info_base(type_info_of(dst.id))
	val := any{dst.data, base.id}

	#partial switch info in base.variant {
	case runtime.Type_Info_Integer:
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		switch base.size {
		case 1:
			(^byte)(val.data)^ = bv.byt
		case 2:
			if info.signed {
				(^i16)(val.data)^ = bv.int16
			} else {
				(^u16)(val.data)^ = bv.uint16
			}
		case 4:
			if info.signed {
				(^i32)(val.data)^ = bv.int32
			} else {
				(^u32)(val.data)^ = bv.uint32
			}
		case 8:
			if info.signed {
				(^i64)(val.data)^ = bv.int64
			} else {
				(^u64)(val.data)^ = bv.uint64
			}
		case:
			return .Unsupported_Type
		}
	case runtime.Type_Info_Enum:
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		if base.size == 1 {
			(^byte)(val.data)^ = bv.byt
		} else if base.size == 2 {
			(^i16)(val.data)^ = bv.int16
		} else if base.size == 4 {
			(^i32)(val.data)^ = bv.int32
		} else if base.size == 8 {
			(^i64)(val.data)^ = bv.int64
		} else {
			return .Unsupported_Type
		}
	case runtime.Type_Info_Boolean:
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		(^bool)(val.data)^ = bool(bv.bool_val)
	case runtime.Type_Info_Float:
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		if base.size == 8 {
			(^f64)(val.data)^ = bv.dbl
		} else if base.size == 4 {
			(^f32)(val.data)^ = f32(bv.dbl)
		} else if base.size == 2 {
			(^f16)(val.data)^ = f16(bv.dbl)
		} else {
			return .Unsupported_Type
		}
	case runtime.Type_Info_String:
		bv: BasicValue
		message_iter_get_basic(it, &bv)
		if info.is_cstring {
			cloned_cstr := strings.clone_to_cstring(string(bv.str), allocator)
			(^cstring)(val.data)^ = cloned_cstr
		} else {
			cloned_str := strings.clone(string(bv.str), allocator)
			(^string)(val.data)^ = cloned_str
		}
	case runtime.Type_Info_Slice, runtime.Type_Info_Array, runtime.Type_Info_Dynamic_Array:
		return unmarshal_array(it, val, allocator)
	case runtime.Type_Info_Struct:
		return unmarshal_struct(it, val, allocator)
	case:
		return .Unsupported_Type
	}
	return .None
}

@(private = "file")
unmarshal_array :: proc(it: ^MessageIter, val: any, allocator: runtime.Allocator) -> MarshalError {
	base := reflect.type_info_base(type_info_of(val.id))
	sl, is_slice := base.variant.(runtime.Type_Info_Slice)
	if !is_slice do return .Signature_Mismatch

	count := int(message_iter_get_element_count(it))
	sub: MessageIter
	message_iter_recurse(it, &sub)

	bytes, alloc_err := mem.alloc_bytes(count * sl.elem.size, sl.elem.align, allocator)
	if alloc_err != nil do return .Allocation_Failed

	raw := (^runtime.Raw_Slice)(val.data)
	raw.data = raw_data(bytes)
	raw.len = count

	for i in 0 ..< count {
		elem_data := rawptr(uintptr(raw.data) + uintptr(sl.elem.size * i))
		elem := any{elem_data, sl.elem.id}
		unmarshal_any(&sub, elem, allocator) or_return
		if i < count - 1 do message_iter_next(&sub)
	}
	return .None
}

@(private = "file")
unmarshal_struct :: proc(
	it: ^MessageIter,
	val: any,
	allocator: runtime.Allocator,
) -> MarshalError {
	base := reflect.type_info_base(type_info_of(val.id))
	s, ok := base.variant.(runtime.Type_Info_Struct)
	if !ok do return .Signature_Mismatch

	sub: MessageIter
	message_iter_recurse(it, &sub)

	parent := any{val.data, base.id}
	for i in 0 ..< int(s.field_count) {
		field := reflect.struct_field_at(parent.id, i)
		unmarshal_field(&sub, field, parent, allocator) or_return
		if i < int(s.field_count) - 1 do message_iter_next(&sub)
	}
	return .None
}

@(private = "file")
unmarshal_property_dict :: proc(
	it: ^MessageIter,
	val: any,
	allocator: runtime.Allocator,
) -> MarshalError {
	base := reflect.type_info_base(type_info_of(val.id))
	s, is_struct := base.variant.(runtime.Type_Info_Struct)
	if !is_struct do return .Signature_Mismatch

	sub: MessageIter
	message_iter_recurse(it, &sub)

	parent := any{val.data, base.id}
	for message_iter_get_arg_type(&sub) != .INVALID {
		entry: MessageIter
		message_iter_recurse(&sub, &entry)

		bv: BasicValue
		message_iter_get_basic(&entry, &bv)
		key := string(bv.str)
		message_iter_next(&entry)

		field_idx := -1
		for i in 0 ..< int(s.field_count) {
			f := reflect.struct_field_at(parent.id, i)
			name_tag := string(reflect.struct_tag_get(f.tag, "dbus_name"))
			if name_tag == key {
				field_idx = i
				break
			} else if len(name_tag) == 0 && f.name == key {
				field_idx = i
				break
			}
		}

		if field_idx >= 0 {
			field := reflect.struct_field_at(parent.id, field_idx)
			field_dst := reflect.struct_field_value(parent, field)
			tag := string(reflect.struct_tag_get(field.tag, "dbus"))

			var_it: MessageIter
			message_iter_recurse(&entry, &var_it)

			if len(tag) >= 2 && tag[0] == 'a' && tag[1] == '{' {
				unmarshal_property_dict(&var_it, field_dst, allocator) or_return
			} else {
				unmarshal_any(&var_it, field_dst, allocator) or_return
			}
		}

		message_iter_next(&sub)
	}
	return .None
}
