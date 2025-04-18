package dbus

import "core:c"

//odinfmt:disable
Message :: struct {}
MessageIter :: struct {}
//odinfmt:enable

MessageType :: enum c.int {
	INVALID       = 0,
	/** Message type of a method call message, see dbus_message_get_type() */
	METHOD_CALL   = 1,
	/** Message type of a method return message, see dbus_message_get_type() */
	METHOD_RETURN = 2,
	/** Message type of an error reply message, see dbus_message_get_type() */
	ERROR         = 3,
	/** Message type of a signal message, see dbus_message_get_type() */
	SIGNAL        = 4,
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	message_get_serial :: proc(message: ^Message) -> c.uint32_t ---
	message_set_reply_serial :: proc(message: ^Message, reply_serial: c.uint32_t) -> bool_t ---
	message_get_reply_serial :: proc(message: ^Message) -> c.uint32_t ---
	message_new :: proc(type: MessageType) -> ^Message ---
	message_new_method_call :: proc(dest, path, iface, method: cstring) -> ^Message ---
	message_new_return :: proc(method_call: ^Message) -> ^Message ---
	message_new_signal :: proc(path, iface, name: cstring) -> ^Message ---
	message_new_error :: proc(reply_to: ^Message, error_name, error_message: cstring) -> ^Message ---
	message_new_error_printf :: proc(reply_to: ^Message, error_name: cstring, error_format: cstring, #c_vararg args: ..any) -> ^Message ---
	message_copy :: proc(message: ^Message) -> ^Message ---
	message_ref :: proc(message: ^Message) -> ^Message ---
	message_unref :: proc(message: ^Message) ---
	message_get_type :: proc(message: ^Message) -> MessageType ---
	message_append_args :: proc(message: ^Message, first_arg_type: Type, #c_vararg args: ..any) -> bool_t ---
	message_append_args_valist :: proc(message: ^Message, first_arg_type: Type, var_args: c.va_list) -> bool_t ---
	message_get_args :: proc(message: ^Message, error: ^Error, first_arg_type: Type, #c_vararg args: ..any) -> bool_t ---
	message_get_args_valist :: proc(message: ^Message, error: ^Error, first_arg_type: Type, var_args: c.va_list) -> bool_t ---
	message_iter_init :: proc(message: ^Message, iter: ^MessageIter) -> bool_t ---
	message_iter_has_next :: proc(iter: ^MessageIter) -> bool_t ---
	message_iter_next :: proc(iter: ^MessageIter) -> bool_t ---
	message_iter_get_arg_type :: proc(iter: ^MessageIter) -> MessageType ---
	message_iter_get_element_type :: proc(iter: ^MessageIter) -> Type ---
	message_iter_recurse :: proc(iter, sub: ^MessageIter) ---
	message_iter_get_signature :: proc(iter: ^MessageIter) -> cstring ---
	message_iter_get_basic :: proc(iter: ^MessageIter, value: rawptr) ---
	message_iter_get_element_count :: proc(iter: ^MessageIter) -> c.int ---
	message_iter_get_array_len :: proc(iter: ^MessageIter) -> c.int ---
	message_iter_get_fixed_array :: proc(iter: ^MessageIter, value: [^]rawptr, n_elements: ^c.int) ---
	message_iter_init_append :: proc(message: ^Message, iter: ^MessageIter) ---
	message_iter_append_basic :: proc(iter: ^MessageIter, type: Type, value: rawptr) -> bool_t ---
	message_iter_append_fixed_array :: proc(iter: ^MessageIter, type: Type, value: [^]rawptr, n_elements: c.int) -> bool_t ---
	message_iter_open_container :: proc(iter: ^MessageIter, type: Type, contained_signature: cstring, sub: ^MessageIter) -> bool_t ---
	message_iter_close_container :: proc(iter, sub: ^MessageIter) -> bool_t ---
	message_iter_abandon_container :: proc(iter, sub: ^MessageIter) ---
	message_iter_abandon_container_if_open :: proc(iter, sub: ^MessageIter) ---
	message_set_no_reply :: proc(message: ^Message, no_reply: bool_t) ---
	message_get_no_reply :: proc(message: ^Message) -> bool_t ---
	message_set_auto_start :: proc(message: ^Message, auto_start: bool_t) ---
	message_get_auto_start :: proc(message: ^Message) -> bool_t ---
	message_set_path :: proc(message: ^Message, path: cstring) ---
	message_get_path :: proc(message: ^Message) -> cstring ---
	message_has_path :: proc(message: ^Message, path: cstring) -> bool_t ---
	message_get_path_decomposed :: proc(message: ^Message, path: ^[^]cstring) -> bool_t ---
	message_set_interface :: proc(message: ^Message, iface: cstring) -> bool_t ---
	message_get_interface :: proc(message: ^Message) -> cstring ---
	message_has_interface :: proc(message: ^Message, iface: cstring) -> bool_t ---
	message_set_member :: proc(message: ^Message, member: cstring) -> bool_t ---
	message_get_member :: proc(message: ^Message) -> cstring ---
	message_has_member :: proc(message: ^Message, member: cstring) -> bool_t ---
	message_set_error_name :: proc(message: ^Message, error_name: cstring) -> bool_t ---
	message_get_error_name :: proc(message: ^Message) -> cstring ---
	message_set_destination :: proc(message: ^Message, destination: cstring) -> bool_t ---
	message_get_destination :: proc(message: ^Message) -> cstring ---
	message_set_sender :: proc(message: ^Message, sender: cstring) -> bool_t ---
	message_get_sender :: proc(message: ^Message) -> cstring ---
	message_get_signature :: proc(message: ^Message) -> cstring ---
	message_is_method_call :: proc(message: ^Message, iface, method: cstring) -> bool_t ---
	message_is_signal :: proc(message: ^Message, iface, signal_name: cstring) -> bool_t ---
	message_is_error :: proc(message: ^Message, error_name: cstring) -> bool_t ---
	message_has_destination :: proc(message: ^Message, name: cstring) -> bool_t ---
	message_has_sender :: proc(message: ^Message, name: cstring) -> bool_t ---
	message_has_signature :: proc(message: ^Message, signature: cstring) -> bool_t ---
	set_error_from_message :: proc(error: ^Error, message: ^Message) -> bool_t ---
	message_contains_unix_fds :: proc(message: ^Message) -> bool_t ---
	message_set_container_instance :: proc(message: ^Message, object_path: cstring) -> bool_t ---
	message_get_container_instance :: proc(message: ^Message) -> cstring ---
	message_set_serial :: proc(message: ^Message, serial: c.uint32_t) ---
	messager_iter_init_closed :: proc(iter: ^MessageIter) ---
	message_lock :: proc(message: ^Message) ---
	message_allocate_data_slot :: proc(slot_p: ^c.int32_t) -> bool_t ---
	message_free_data_slot :: proc(slot_p: ^c.int32_t) ---
	message_set_data :: proc(message: ^Message, slot: c.int32_t, dta: rawptr, free_data_func: FreeProc) -> bool_t ---
	message_get_data :: proc(message: ^Message, slot: c.int32_t) -> rawptr ---
	message_type_from_string :: proc(type_str: cstring) -> MessageType ---
	message_type_to_string :: proc(type: MessageType) -> cstring ---
	message_marshal :: proc(message: ^Message, marshalled_data: ^cstring, len_p: c.int) -> bool_t ---
	message_demarshal :: proc(str: cstring, len: c.int, error: ^Error) -> ^Message ---
	message_demarshal_bytes_needed :: proc(str: cstring, len: c.int) -> c.int ---
	message_set_allow_interactive_authorization :: proc(message: ^Message, allow: bool_t) ---
	message_get_allow_interactive_authorization :: proc(message: ^Message) -> bool_t ---
}
