package dbus

//odinfmt:disable
SignatureIter :: struct {}
//odinfmt:enable

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	signature_iter_init :: proc(iter: ^SignatureIter, signature: cstring) ---
	signature_get_current_type :: proc(iter: ^SignatureIter) -> Type ---
	signature_iter_get_signature :: proc(iter: ^SignatureIter) -> cstring ---
	signature_iter_get_element_type :: proc(iter: ^SignatureIter) -> Type ---
	signature_iter_next :: proc(iter: ^SignatureIter) -> bool_t ---
	signature_iter_recurse :: proc(iter, subiter: ^SignatureIter) ---
	signature_validate :: proc(signature: cstring, error: ^Error) -> bool_t ---
	signature_validate_single :: proc(signature: cstring, error: ^Error) -> bool_t ---
	type_is_container :: proc(type: Type) -> bool_t ---
	type_is_basic :: proc(type: Type) -> bool_t ---
	type_is_fixed :: proc(type: Type) -> bool_t ---
	type_is_valid :: proc(type: Type) -> bool_t ---
}
