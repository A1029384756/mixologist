package mixologist

import "core:encoding/cbor"
import "core:log"
import "core:os"
import "core:prof/spall"
import "core:slice"
import "core:sys/linux"
import "core:sys/posix"

SERVER_SOCKET :: "\x00mixologist"
MAX_CLIENTS :: 64
BUF_SIZE :: 1024

IPCServer :: struct {
	subscription:     Subscriber,
	server_fd:        linux.Fd,
	server_addr:      linux.Sock_Addr_Un,
	_clients:         [dynamic; MAX_CLIENTS]linux.Poll_Fd,
	_removed_clients: [dynamic; MAX_CLIENTS]linux.Fd,
	_buf:             [BUF_SIZE]u8,
}

@(private = "file")
ctx: IPCServer

ipc_init :: proc() -> linux.Errno {
	subscriber_init(&ctx.subscription, .Ipc, {.Quit})
	bus_subscribe(&bus, ctx.subscription)
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

ipc_proc :: proc() {
	when PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(os.get_current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
	}

	should_exit := false
	for !should_exit {
		for msg in subscriber_poll(&ctx.subscription) {
			#partial switch msg.topic {
			case .Quit:
				should_exit = true
			case:
				log.errorf("unexpected \"%v\" message", msg.topic)
			}
			message_unref(msg)
		}
		ipc_poll(&ctx)
	}
}

ipc_poll :: proc(ctx: ^IPCServer) {
	_, poll_err := linux.poll(ctx._clients[:], 5)
	if poll_err != nil do return

	if ctx._clients[0].revents >= {.IN} {
		client_fd, client_err := linux.accept(ctx.server_fd, &ctx.server_addr, {})
		if client_err != nil do log.panicf("accept error %v", client_err)
		log.debugf("client connected: socket %v", client_fd)
		append(&ctx._clients, linux.Poll_Fd{fd = client_fd, events = {.IN}})
	}

	n_bytes: int
	clear(&ctx._removed_clients)
	#reverse for &client, idx in ctx._clients[1:] {
		if client.revents >= {.IN} {
			bytes_read, read_err := linux.read(client.fd, ctx._buf[n_bytes:])
			if read_err != nil {
				log.debugf("client error %v disconnecting: socket %v", read_err, client.fd)
				unordered_remove(&ctx._clients, idx + 1)
				append(&ctx._removed_clients, client.fd)
			} else if bytes_read == 0 {
				log.debugf("client disconnected: socket %v", client.fd)
				unordered_remove(&ctx._clients, idx + 1)
				append(&ctx._removed_clients, client.fd)
			} else if bytes_read == 1024 {
				log.debugf("client error UNKNOWN disconnecting: socket %v", client.fd)
				unordered_remove(&ctx._clients, idx + 1)
				append(&ctx._removed_clients, client.fd)
			} else {
				log.debugf("read %v bytes: socket %v", bytes_read, client.fd)
				msg_bytes := ctx._buf[n_bytes:n_bytes + bytes_read]
				ipc_message_handler(msg_bytes, client.fd)
				n_bytes += bytes_read
			}
		}
	}

	for fd in ctx._removed_clients {
		linux.close(fd)
	}
}

ipc_message_handler :: proc(bytes: []u8, sender: linux.Fd) {
	msg: Message
	unmarshal_err := cbor.unmarshal(string(bytes), &msg)
	if unmarshal_err != nil {
		log.errorf("could not unmarshal message from %v: %v", sender, unmarshal_err)
		return
	}

	#partial switch msg.topic {
	case .Rule, .Volume:
		bus_publish(&bus, msg)
	case:
		log.errorf("unexpected topic %v", msg.topic)
	}
}

ipc_send :: proc(ctx: ^IPCServer, client_fd: linux.Fd, msg: Message) {
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

ipc_deinit :: proc() {
	for client in ctx._clients[:] do linux.close(client.fd)
	linux.close(ctx.server_fd)
	subscriber_flush(&ctx.subscription)
	subscriber_destroy(&ctx.subscription)
}

// blank handler to ignore sigpipe
_ipc_handle_sigpipe :: proc "c" (signum: posix.Signal) {}
