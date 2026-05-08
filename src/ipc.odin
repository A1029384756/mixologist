package mixologist

import "core:encoding/cbor"
import "core:log"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

SERVER_SOCKET :: "\x00mixologist"
MAX_CLIENTS :: 64
BUF_SIZE :: 1024

IPCServer :: struct {
	server_fd:        linux.Fd,
	server_addr:      linux.Sock_Addr_Un,
	_clients:         [dynamic; MAX_CLIENTS]linux.Poll_Fd,
	_removed_clients: [dynamic; MAX_CLIENTS]linux.Fd,
	_buf:             [BUF_SIZE]u8,
}

@(private = "file")
ctx: IPCServer

ipc_init :: proc() -> linux.Errno {
	posix.signal(.SIGPIPE, _ipc_handle_sigpipe)

	sock_err: linux.Errno
	ctx.server_fd, sock_err = linux.socket(.UNIX, .STREAM, {}, .HOPOPT)
	if sock_err != nil do log.panicf("could not create socket with error %v", sock_err)

	ctx.server_addr.sun_family = .UNIX
	copy(ctx.server_addr.sun_path[:], SERVER_SOCKET)

	linux.unlink(SERVER_SOCKET)
	linux.bind(ctx.server_fd, &ctx.server_addr) or_return
	listen_err := linux.listen(ctx.server_fd, 1024)
	append(&ctx._clients, linux.Poll_Fd{fd = ctx.server_fd, events = {.IN}})
	return listen_err
}

ipc_server_fd :: proc() -> linux.Fd {
	return ctx.server_fd
}

ipc_accept_one :: proc() -> linux.Fd {
	client_fd, client_err := linux.accept(ctx.server_fd, &ctx.server_addr, {})
	if client_err != nil do log.panicf("accept error %v", client_err)
	log.debugf("client connected: socket %v", client_fd)
	return client_fd
}

ipc_handle_client :: proc(fd: linux.Fd) -> (disconnected: bool) {
	bytes_read, read_err := linux.read(fd, ctx._buf[:])
	if read_err != nil {
		log.debugf("client error %v disconnecting: socket %v", read_err, fd)
		return true
	} else if bytes_read == 0 {
		log.debugf("client disconnected: socket %v", fd)
		return true
	} else if bytes_read == 1024 {
		log.debugf("client error UNKNOWN disconnecting: socket %v", fd)
		return true
	}
	log.debugf("read %v bytes: socket %v", bytes_read, fd)
	ipc_message_handler(ctx._buf[:bytes_read], fd)
	return false
}

ipc_message_handler :: proc(bytes: []u8, sender: linux.Fd) {
	msg: Message
	// todo validate
	unmarshal_err := cbor.unmarshal(string(bytes), &msg, allocator = context.temp_allocator)
	if unmarshal_err != nil {
		log.errorf("could not unmarshal message from %v: %v", sender, unmarshal_err)
		return
	}

	#partial switch msg.kind {
	case .Rule:
		daemon_update_gui_rule(msg.list)
	case .Wake:
		daemon_wake_gui()
	case .Volume:
		v := msg.volume
		switch v.kind {
		case .Add, .Set:
			daemon_update_gui_volume(v)
		case .Get:
			ipc_send(sender, {kind = .Volume, volume = {val = daemon.state.volume}})
		}
	case:
		log.errorf("unexpected %v", msg.kind)
	}
}

ipc_send :: proc(client_fd: linux.Fd, msg: Message) {
	_, found := slice.linear_search(ctx._removed_clients[:], client_fd)
	if found {
		log.debugf("attempted to send to removed socket: %v, skipping", client_fd)
		return
	}

	cbor_msg, _ := cbor.marshal(msg)
	defer delete(cbor_msg)

	bytes_sent, send_err := linux.send(client_fd, cbor_msg, {})
	if send_err != nil {
		log.errorf("could not send with error %v: socket %v", send_err, client_fd)
		append(&ctx._removed_clients, client_fd)
		return
	}

	log.debugf("sent %v bytes from server: socket %v", bytes_sent, client_fd)
}

ipc_fini :: proc() {
	for client in ctx._clients[:] do linux.close(client.fd)
	linux.close(ctx.server_fd)
}

// blank handler to ignore sigpipe
_ipc_handle_sigpipe :: proc "c" (signum: posix.Signal) {}
