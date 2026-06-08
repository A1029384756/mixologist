package dbus

import "core:c"

AddressEntry :: struct {
}

@(default_calling_convention = "c", link_prefix = "dbus_")
foreign lib {
	adress_entries_free :: proc(entries: [^]^AddressEntry) ---
	address_entry_get_method :: proc(entry: ^AddressEntry) -> cstring ---
	address_entry_get_value :: proc(entry: ^AddressEntry, key: cstring) -> cstring ---
	parse_address :: proc(address: cstring, entry_result: ^[^]^AddressEntry, array_len: ^c.int, error: ^Error) -> bool_t ---
	address_escape_value :: proc(value: cstring) -> cstring ---
	address_unescape_value :: proc(value: cstring, error: ^Error) -> cstring ---
}
