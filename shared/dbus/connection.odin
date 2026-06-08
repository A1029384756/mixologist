package dbus

import "core:c"

//odinfmt:disable
Connection :: struct {}
Watch :: struct {}
Timeout :: struct {}
PreallocatedSend :: struct {}
PendingCall :: struct {}
//odinfmt:enable

ObjectPathVTable :: struct {
	unregister_function: ObjectPathUnregisterProc,
	message_function:    ObjectPathMessageProc,
	pad_1:               rawptr,
	pad_2:               rawptr,
	pad_3:               rawptr,
	pad_4:               rawptr,
}

ObjectPathUnregisterProc :: #type proc "c" (connection: ^Connection, user_data: rawptr)
ObjectPathMessageProc :: #type proc "c" (
	connection: ^Connection,
	message: ^Message,
	user_data: rawptr,
) -> HandlerResult

AddWatchProc :: #type proc "c" (watch: ^Watch, data: rawptr) -> bool_t
WatchToggledProc :: #type proc "c" (watch: ^Watch, data: rawptr)
RemoveWatchProc :: #type proc "c" (watch: ^Watch, data: rawptr)

AddTimeoutProc :: #type proc "c" (timeout: ^Timeout, data: rawptr) -> bool_t
TimeoutToggledProc :: #type proc "c" (watch: ^Timeout, data: rawptr)
RemoveTimeoutProc :: #type proc "c" (watch: ^Timeout, data: rawptr)

StatusDispatchProc :: #type proc "c" (
	connection: ^Connection,
	new_status: DipatchStatus,
	data: rawptr,
)
WakeupMainProc :: #type proc "c" (data: rawptr)
AllowUnixUserProc :: #type proc "c" (connection: ^Connection, uid: c.ulong, data: rawptr) -> bool_t
AllowWindowsUserProc :: #type proc "c" (connection: ^Connection, user_sid: cstring, data: rawptr)
PendingCallNotifyProc :: #type proc "c" (pending: ^PendingCall, user_data: rawptr)
HandleMessageProc :: #type proc "c" (
	connection: ^Connection,
	message: ^Message,
	user_data: rawptr,
) -> HandlerResult
FreeProc :: #type proc "c" (memory: rawptr)

DipatchStatus :: enum c.int {
	DATA_REMAINS = 0, /**< There is more data to potentially convert to messages. */
	COMPLETE     = 1, /**< All currently available data has been processed. */
	NEED_MEMORY  = 2, /**< More memory is needed to continue. */
}

HandlerResult :: enum c.int {
	HANDLED         = 0, /**< Message has had its effect - no need to run more handlers. */
	NOT_YET_HANDLED = 1, /**< Message has not had any effect - see if other handlers want it. */
	NEED_MEMORY     = 2, /**< Need more memory in order to return #DBUS_HANDLER_RESULT_HANDLED or #DBUS_HANDLER_RESULT_NOT_YET_HANDLED. Please try again later with more memory. */
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	connection_open :: proc(address: cstring, error: ^Error) -> ^Connection ---
	connection_open_private :: proc(address: cstring, error: ^Error) -> ^Connection ---
	connection_ref :: proc(connection: ^Connection) -> ^Connection ---
	connection_unref :: proc(connection: ^Connection) ---
	connection_close :: proc(connection: ^Connection) ---
	connection_get_is_connected :: proc(connection: ^Connection) -> bool_t ---
	connection_get_is_authenticated :: proc(connection: ^Connection) -> bool_t ---
	connection_get_is_anonymous :: proc(connection: ^Connection) -> bool_t ---
	connection_get_is_server_id :: proc(connection: ^Connection) -> cstring ---
	connection_can_send_type :: proc(connection: ^Connection, type: Type) -> bool_t ---
	connection_set_exit_on_disconnect :: proc(connection: ^Connection, exit_on_disconnect: bool_t) ---
	connection_preallocate_send :: proc(connection: ^Connection) -> ^PreallocatedSend ---
	connection_free_preallocated_send :: proc(connection: ^Connection, preallocated: ^PreallocatedSend) ---
	connection_send_preallocated :: proc(connection: ^Connection, preallocated: ^PreallocatedSend, message: ^Message, client_serial: ^c.uint32_t) ---
	connection_send :: proc(connection: ^Connection, message: ^Message, serial: ^c.uint32_t) -> bool_t ---
	connection_send_with_reply :: proc(connection: ^Connection, message: ^Message, pending_return: ^^PendingCall, timeout_ms: c.int) -> bool_t ---
	connection_send_with_reply_and_block :: proc(connection: ^Connection, message: ^Message, timeout_ms: c.int, error: ^Error) -> ^Message ---
	connection_flush :: proc(connection: ^Connection) ---
	connection_read_write_dispatch :: proc(connection: ^Connection, timeout_ms: c.int) -> bool_t ---
	connection_read_write :: proc(connection: ^Connection, timeout_ms: c.int) -> bool_t ---
	connection_borrow_message :: proc(connection: ^Connection) -> ^Message ---
	connection_return_message :: proc(connection: ^Connection, message: ^Message) ---
	connection_steal_borrowed_message :: proc(connection: ^Connection, message: ^Message) ---
	connection_pop_message :: proc(connection: ^Connection) -> ^Message ---
	connection_get_dispatch_status :: proc(connection: ^Connection) -> DipatchStatus ---
	connection_dispatch :: proc(connection: ^Connection) -> DipatchStatus ---
	connection_set_watch_functions :: proc(connection: ^Connection, add_function: AddWatchProc, remove_function: RemoveWatchProc, toggled_function: WatchToggledProc, data: rawptr, free_data_function: FreeProc) -> bool_t ---
	connection_set_timeout_functions :: proc(connection: ^Connection, add_function: AddTimeoutProc, remove_function: RemoveTimeoutProc, toggled_function: TimeoutToggledProc, data: rawptr, free_data_function: FreeProc) -> bool_t ---
	connection_set_wakeup_main_function :: proc(connection: ^Connection, wakeup_main_function: WakeupMainProc, data: rawptr, free_data_function: FreeProc) ---
	connection_set_dispatch_status_function :: proc(connection: ^Connection, function: StatusDispatchProc, data: rawptr, free_data_function: FreeProc) ---
	connection_get_unix_fd :: proc(connection: ^Connection, fd: ^c.int) -> bool_t ---
	connection_get_socket :: proc(connection: ^Connection, fd: ^c.int) -> bool_t ---
	connection_get_unix_user :: proc(connection: ^Connection, fd: ^c.ulong) -> bool_t ---
	connection_get_unix_pid :: proc(connection: ^Connection, fd: ^c.ulong) -> bool_t ---
	connection_get_adt_audit_session_data :: proc(connection: ^Connection, data: [^]rawptr, data_size: c.int32_t) -> bool_t ---
	connection_set_unix_user_function :: proc(connection: ^Connection, function: AllowUnixUserProc, data: rawptr, free_data_function: FreeProc) ---
	connection_get_windows_user :: proc(connection: ^Connection, windows_sid_p: ^cstring) -> bool_t ---
	connection_set_windows_user_function :: proc(connection: ^Connection, function: AllowWindowsUserProc, data: rawptr, free_data_function: FreeProc) ---
	connection_set_allow_anonymous :: proc(connection: ^Connection, value: bool_t) ---
	connection_set_route_peer_messages :: proc(connection: ^Connection, value: bool_t) ---
	connection_add_filter :: proc(connection: ^Connection, function: HandleMessageProc, user_data: rawptr, free_data_function: FreeProc) -> bool_t ---
	connection_remove_filter :: proc(connection: ^Connection, function: HandleMessageProc, user_data: rawptr) ---
	connection_try_register_object_path :: proc(connection: ^Connection, path: cstring, vtable: ^ObjectPathVTable, user_data: rawptr, error: ^Error) -> bool_t ---
	connection_register_object_path :: proc(connection: ^Connection, path: cstring, vtable: ^ObjectPathVTable, user_data: rawptr) -> bool_t ---
	connection_try_register_fallback :: proc(connection: ^Connection, path: cstring, vtable: ^ObjectPathVTable, user_data: rawptr, error: ^Error) -> bool_t ---
	connection_register_fallback :: proc(connection: ^Connection, path: cstring, vtable: ^ObjectPathVTable, user_data: rawptr) -> bool_t ---
	connection_unregister_object_path :: proc(connection: ^Connection, path: cstring) -> bool_t ---
	connection_get_boject_path_data :: proc(connection: ^Connection, path: cstring, data_p: ^rawptr) -> bool_t ---
	connection_list_registered :: proc(connection: ^Connection, parent_path: cstring, child_entries: ^^cstring) -> bool_t ---
	connection_allocate_data_slot :: proc(slot_p: ^c.int32_t) -> bool_t ---
	connection_free_data_slot :: proc(slot_p: ^c.int32_t) ---
	connection_set_data :: proc(connection: ^Connection, slot: c.int32_t, data: rawptr, free_data_function: FreeProc) -> bool_t ---
	connection_get_data :: proc(connection: ^Connection, slot: c.int32_t) -> rawptr ---
	connection_set_change_sigpipe :: proc(will_modify_sigpipe: bool_t) ---
	connection_set_max_message_size :: proc(connection: ^Connection, size: c.long) ---
	connection_get_max_message_size :: proc(connection: ^Connection) -> c.long ---
	connection_set_max_message_unix_fds :: proc(connection: ^Connection, n: c.long) ---
	connection_get_max_message_unix_fds :: proc(connection: ^Connection) -> c.long ---
	connection_set_max_received_size :: proc(connection: ^Connection, size: c.long) ---
	connection_get_max_received_size :: proc(connection: ^Connection) -> c.long ---
	connection_set_max_received_unix_fds :: proc(connection: ^Connection, n: c.long) ---
	connection_get_max_received_unix_fds :: proc(connection: ^Connection) -> c.long ---
	connection_connection_get_outgoing_size :: proc(connection: ^Connection) -> c.long ---
	connection_get_outgoing_unix_fds :: proc(connection: ^Connection) -> c.long ---
	connection_has_messages_to_send :: proc(connection: ^Connection) -> bool_t ---
}
