package mixologist

import "../common"
import sa "core:container/small_array"
import "core:encoding/cbor"
import "core:log"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

SERVER_SOCKET :: "\x00mixologist"
MAX_CLIENTS :: 64
BUF_SIZE :: 1024

IPC_Server_Context :: struct {
	server_fd:            linux.Fd,
	server_addr:          linux.Sock_Addr_Un,
	messages:             [dynamic]IPC_Message,
	_clients:             sa.Small_Array(MAX_CLIENTS, linux.Poll_Fd),
	_removed_clients:     sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_volume_subscribers:  sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_program_subscribers: sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_buf:                 [BUF_SIZE]u8,
}

IPC_Message :: struct {
	msg_bytes: []u8,
	sender:    linux.Fd,
}

IPC_Server_init :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	posix.signal(.SIGPIPE, IPC_Server__handle_sigpipe)

	sock_err: linux.Errno
	ctx.server_fd, sock_err = linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT)
	if sock_err != nil do log.panicf("could not create socket with error %v", sock_err)

	ctx.server_addr.sun_family = .UNIX
	copy(ctx.server_addr.sun_path[:], SERVER_SOCKET)

	linux.unlink(SERVER_SOCKET)
	linux.bind(ctx.server_fd, &ctx.server_addr) or_return
	listen_err := linux.listen(ctx.server_fd, 1024)
	sa.append(&ctx._clients, linux.Poll_Fd{fd = ctx.server_fd, events = {.IN}})
	return listen_err
}

IPC_Server_poll :: proc(ctx: ^IPC_Server_Context) {
	_, poll_err := linux.poll(sa.slice(&ctx._clients), 5)
	if poll_err != nil do return

	if sa.get(ctx._clients, 0).revents >= {.IN} {
		client_fd, client_err := linux.accept(ctx.server_fd, &ctx.server_addr, {.NONBLOCK})
		if client_err != nil do log.panicf("accept error %v", client_err)
		log.debugf("client connected: socket %v", client_fd)
		sa.append(&ctx._clients, linux.Poll_Fd{fd = client_fd, events = {.IN}})
	}

	n_bytes: int
	clear(&ctx.messages)
	sa.clear(&ctx._removed_clients)
	#reverse for &client, idx in sa.slice(&ctx._clients)[1:] {
		if client.revents >= {.IN} {
			bytes_read, read_err := linux.read(client.fd, ctx._buf[n_bytes:])
			if read_err == .EWOULDBLOCK || read_err == .EAGAIN do continue
			if read_err != nil {
				log.debugf("client error %v disconnecting: socket %v", read_err, client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
				sa.append(&ctx._removed_clients, client.fd)
			} else if bytes_read == 0 {
				log.debugf("client disconnected: socket %v", client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
				sa.append(&ctx._removed_clients, client.fd)
			} else {
				log.debugf("read %v bytes: socket %v", bytes_read, client.fd)
				msg_bytes := ctx._buf[n_bytes:n_bytes + bytes_read]
				append(&ctx.messages, IPC_Message{msg_bytes, client.fd})
				n_bytes += bytes_read
			}
		}
	}

	for fd in sa.slice(&ctx._removed_clients) {
		IPC_Server_remove_volume_subscriber(ctx, fd)
		IPC_Server_remove_program_subscriber(ctx, fd)
		linux.close(fd)
	}
}

IPC_Server_send :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd, msg: common.Message) {
	_, found := slice.linear_search(sa.slice(&ctx._removed_clients), client_fd)
	if found {
		log.debugf("attempted to send to removed socket: %v, skipping", client_fd)
		return
	}

	cbor_msg, _ := cbor.marshal(msg)
	defer delete(cbor_msg)

	bytes_sent, send_err := linux.send(client_fd, cbor_msg, {})
	if send_err != nil {
		log.errorf("could not send with error %v: socket %v", send_err, client_fd)
		sa.append(&ctx._removed_clients, client_fd)
		return
	}

	log.debugf("sent %v bytes from server: socket %v", bytes_sent, client_fd)
}

IPC_Server_add_volume_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
	_, found := slice.linear_search(sa.slice(&ctx._volume_subscribers), client_fd)
	if !found do sa.append(&ctx._volume_subscribers, client_fd)
}

IPC_Server_remove_volume_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
	idx, found := slice.linear_search(sa.slice(&ctx._volume_subscribers), client_fd)
	if found {
		log.debugf("removed volume subscriber: socket %v", client_fd)
		sa.unordered_remove(&ctx._volume_subscribers, idx)
	}
}

IPC_Server_add_program_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
	_, found := slice.linear_search(sa.slice(&ctx._program_subscribers), client_fd)
	if !found do sa.append(&ctx._program_subscribers, client_fd)
}

IPC_Server_remove_program_subscriber :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd) {
	idx, found := slice.linear_search(sa.slice(&ctx._program_subscribers), client_fd)
	if found {
		log.debugf("removed program subscriber: socket %v", client_fd)
		sa.unordered_remove(&ctx._program_subscribers, idx)
	}
}

IPC_Server_notify_volume_subscription :: proc(ctx: ^IPC_Server_Context, volume: f32) {
	msg := common.Volume{.Get, volume}
	for client_fd in sa.slice(&ctx._volume_subscribers) do IPC_Server_send(ctx, client_fd, msg)
}

IPC_Server_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	delete(ctx.messages)
	for client in sa.slice(&ctx._clients) do linux.close(client.fd)
	return linux.close(ctx.server_fd)
}

// blank handler to ignore sigpipe
IPC_Server__handle_sigpipe :: proc "c" (signum: posix.Signal) {}
