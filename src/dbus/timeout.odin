package dbus

import "core:c"

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	timeout_get_interval :: proc(timeout: ^Timeout) -> c.int ---
	timeout_get_data :: proc(timeout: ^Timeout) -> rawptr ---
	timeout_set_data :: proc(timeout: ^Timeout, data: rawptr, free_data_function: FreeProc) ---
	timeout_handle :: proc(timeout: ^Timeout) -> bool_t ---
	timeout_get_enabled :: proc(timeout: ^Timeout) -> bool_t ---
}
