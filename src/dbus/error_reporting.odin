package dbus

import "core:c"

Error :: struct {
	name:     cstring,
	message:  cstring,
	dummy:    bit_field u8 {
		dummy1: c.uint | 1,
		dummy2: c.uint | 1,
		dummy3: c.uint | 1,
		dummy4: c.uint | 1,
		dummy5: c.uint | 1,
	},
	padding1: rawptr,
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	error_init :: proc(error: ^Error) ---
	error_free :: proc(error: ^Error) ---
	set_error_const :: proc(error: ^Error, name, message: cstring) ---
	move_error :: proc(src, dest: ^Error) ---
	error_has_name :: proc(error: ^Error, name: cstring) -> bool_t ---
	error_is_set :: proc(error: ^Error) -> bool_t ---
	set_err :: proc(error: ^Error, name: cstring, format: ..cstring) ---
}
