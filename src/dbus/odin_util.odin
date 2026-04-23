package dbus

@(deferred_in = message_iter_pop_container)
message_iter_push_container :: proc(
	base: ^MessageIter,
	type: Type,
	contained: cstring,
	sub: ^MessageIter,
) -> bool_t {
	return message_iter_open_container(base, type, contained, sub)
}

message_iter_pop_container :: proc(
	base: ^MessageIter,
	_type: Type,
	_contained: cstring,
	sub: ^MessageIter,
) {
	message_iter_close_container(base, sub)
}
