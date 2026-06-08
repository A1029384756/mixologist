package dbus

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	validate_path :: proc(path: cstring, error: ^Error) -> bool_t ---
	validate_interface :: proc(name: cstring, error: ^Error) -> bool_t ---
	validate_member :: proc(name: cstring, error: ^Error) -> bool_t ---
	validate_error_name :: proc(name: cstring, error: ^Error) -> bool_t ---
	validate_bus_name :: proc(name: cstring, error: ^Error) -> bool_t ---
	validate_utf8 :: proc(alleged_utf8: cstring, error: ^Error) -> bool_t ---
}
