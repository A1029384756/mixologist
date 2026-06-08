package dbus

ConectionError :: enum {
	None,
	CannotConnect,
	NameTaken,
	SetupErr,
}

connection_open_with_name :: proc(name: cstring) -> (conn: ^Connection, conn_err: ConectionError) {
	err: Error
	error_init(&err)
	defer if error_is_set(&err) {error_free(&err)}

	conn = bus_get_private(.SESSION, &err)
	if error_is_set(&err) {
		conn_err = .CannotConnect
		return
	}

	ret_code := bus_request_name(conn, name, {.DO_NOT_QUEUE}, &err)
	if error_is_set(&err) {
		conn_err = .CannotConnect
		return
	}

	if ret_code != .REPLY_PRIMARY_OWNER {
		conn_err = .NameTaken
		return
	}

	return
}

MethodError :: enum {
	None,
	Send,
	Marshal,
	Unmarshal,
}

method_call :: proc {
	method_call_void,
	method_call_data,
}

method_call_void :: proc(
	conn: ^Connection,
	dest, path, iface, method: cstring,
	contents: any = nil,
) -> MethodError {
	err: Error
	error_init(&err)

	msg := message_new_method_call(dest, path, iface, method)
	defer message_unref(msg)
	if contents != nil {
		if marshal_err := marshal(msg, contents); marshal_err != nil {
			return .Marshal
		}
	}
	reply := connection_send_with_reply_and_block(conn, msg, TIMEOUT_USE_DEFAULT, &err)
	if error_is_set(&err) {
		error_free(&err)
		return .Send
	}

	message_unref(reply)
	return nil
}

method_call_data :: proc(
	$RT: typeid,
	conn: ^Connection,
	dest, path, iface, method: cstring,
	contents: any = nil,
) -> (
	RT,
	MethodError,
) {
	err: Error
	error_init(&err)

	msg := message_new_method_call(dest, path, iface, method)
	defer message_unref(msg)
	if contents != nil {
		if marshal_err := marshal(msg, contents); marshal_err != nil {
			return {}, .Marshal
		}
	}
	reply := connection_send_with_reply_and_block(conn, msg, TIMEOUT_USE_DEFAULT, &err)
	if error_is_set(&err) {
		error_free(&err)
		return {}, .Send
	}
	defer message_unref(reply)

	res: RT
	if unmarshal_err := unmarshal(reply, &res); unmarshal_err != nil {
		return {}, .Unmarshal
	}
	return res, nil
}

method_return :: proc(conn: ^Connection, msg: ^Message, contents: any = nil) {
	reply := message_new_method_return(msg)
	defer message_unref(reply)
	if contents != nil {marshal(reply, contents)}
	connection_send(conn, reply, nil)
}
