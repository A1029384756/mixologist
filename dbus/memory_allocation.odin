package dbus

import "core:c"

new :: proc "c" ($T: typeid, count: c.size_t) {
	return malloc(size_of(T) * count)
}

new0 :: proc "c" ($T: typeid, count: c.size_t) {
	return malloc0(size_of(T) * count)
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	malloc :: proc(bytes: c.size_t) -> rawptr ---
	malloc0 :: proc(bytes: c.size_t) -> rawptr ---
	realloc :: proc(memory: rawptr, bytes: c.size_t) -> rawptr ---
	free :: proc(memory: rawptr) ---
	free_string_array :: proc(str_array: [^]cstring) ---
	shutdown :: proc() ---
}
