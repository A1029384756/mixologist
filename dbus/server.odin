package dbus

import "core:c"

//odinfmt:disable
Server :: struct {}
//odinfmt:enable

NewConnectionProc :: #type proc(server: ^Server, new_connection: ^Connection, data: rawptr)

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	server_listen :: proc(address: cstring, error: ^Error) -> ^Server ---
	server_ref :: proc(server: ^Server) -> ^Server ---
	server_unref :: proc(server: ^Server) ---
	server_disconnect :: proc(server: ^Server) ---
	server_get_is_connected :: proc(server: ^Server) -> bool_t ---
	server_get_address :: proc(server: ^Server) -> cstring ---
	server_get_id :: proc(server: ^Server) -> cstring ---
	server_set_new_connection_function :: proc(server: ^Server, function: NewConnectionProc, data: rawptr, free_data_function: FreeProc) ---
	server_set_watch_functions :: proc(server: ^Server, add_function: AddWatchProc, remove_function: RemoveWatchProc, toggled_function: WatchToggledProc, data: rawptr, free_data_function: FreeProc) -> bool_t ---
	server_set_timeout_functions :: proc(server: ^Server, add_function: AddTimeoutProc, remove_function: RemoveTimeoutProc, toggled_function: TimeoutToggledProc, data: rawptr, free_data_function: FreeProc) -> bool_t ---
	server_set_auth_mechanisms :: proc(server: ^Server, mechanisms: [^]cstring) -> bool_t ---
	server_allocate_data_slot :: proc(slot_p: ^c.int32_t) -> bool_t ---
	server_free_data_slot :: proc(slot_p: ^c.int32_t) ---
	server_set_data :: proc(server: ^Server, slot: c.int, data: rawptr, free_data_func: FreeProc) -> bool_t ---
	server_get_data :: proc(server: ^Server, slot: c.int) -> rawptr ---
}
