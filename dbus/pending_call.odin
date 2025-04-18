package dbus

import "core:c"

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	pending_call_ref :: proc(pending: ^PendingCall) -> ^PendingCall ---
	pending_call_unref :: proc(pending: ^PendingCall) ---
	pending_call_set_notify :: proc(pending: ^PendingCall, function: PendingCallNotifyProc, user_data: rawptr, free_user_data: FreeProc) -> bool_t ---
	pending_call_cancel :: proc(pending: ^PendingCall) ---
	pending_call_get_completed :: proc(pending: ^PendingCall) -> bool_t ---
	pending_call_steal_reply :: proc(pending: ^PendingCall) -> ^Message ---
	pending_casll_block :: proc(pending: ^PendingCall) ---
	pending_call_allocate_data_slot :: proc(slot_p: ^c.int32_t) -> bool_t ---
	pending_call_free_data_slot :: proc(slot_p: ^c.int32_t) ---
	pending_call_set_data :: proc(pending: ^PendingCall, slot: c.int32_t, data: rawptr, free_data_func: FreeProc) -> bool_t ---
	pending_call_get_data :: proc(pending: ^PendingCall, slot: c.int32_t) -> rawptr ---
}
