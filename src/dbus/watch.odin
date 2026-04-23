package dbus

import "core:c"

WatchFlag :: enum c.uint {
	READABLE = 0, /**< As in POLLIN */
	WRITABLE = 1, /**< As in POLLOUT */
	ERROR    = 2, /**< As in POLLERR (can't watch for
                                 *   this, but can be present in
                                 *   current state passed to
                                 *   dbus_watch_handle()).
                                 */
	HANGUP   = 3, /**< As in POLLHUP (can't watch for
                                 *   it, but can be present in current
                                 *   state passed to
                                 *   dbus_watch_handle()).
                                 */
}

WatchFlags :: bit_set[WatchFlag;c.uint]

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	watch_get_unix_fd :: proc(watch: ^Watch) -> c.int ---
	watch_get_socket :: proc(watch: ^Watch) -> c.int ---
	watch_get_flags :: proc(watch: ^Watch) -> WatchFlags ---
	watch_get_data :: proc(watch: ^Watch) -> rawptr ---
	watch_set_data :: proc(watch: ^Watch, data: rawptr, free_data_function: FreeProc) ---
	watch_handle :: proc(watch: ^Watch, flags: WatchFlags) -> bool_t ---
	watch_get_enabled :: proc(watch: ^Watch) -> bool_t ---
}
