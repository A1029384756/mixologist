package dbus

import "core:c"

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	try_get_local_machine_id :: proc(error: ^Error) -> cstring ---
	get_local_machine_id :: proc() -> cstring ---
	get_version :: proc(major, minor, micro: ^c.int) ---
  setenv :: proc(variable, value: cstring) -> bool_t ---
}
