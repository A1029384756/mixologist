package mixologist_daemon

import "../common"
import sa "core:container/small_array"
import "core:encoding/cbor"
import "core:fmt"
import "core:log"
import "core:os/os2"
import "core:slice"
import "core:strings"
import "core:sys/linux"

SERVER_SOCKET :: "\x00mixologist"
MAX_CLIENTS :: 64
BUF_SIZE :: 1024

IPC_Server_Context :: struct {
	server_fd:            linux.Fd,
	server_addr:          linux.Sock_Addr_Un,
	_clients:             sa.Small_Array(MAX_CLIENTS, linux.Poll_Fd),
	_volume_subscribers:  sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_program_subscribers: sa.Small_Array(MAX_CLIENTS, linux.Fd),
	_buf:                 [BUF_SIZE]u8,
}

IPC_Server_init :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
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

IPC_Server_poll :: proc(ctx: ^IPC_Server_Context, mixd_ctx: ^Context) {
	_, poll_err := linux.poll(sa.slice(&ctx._clients), 5)
	if poll_err != nil && mixd_ctx.should_exit do return
	else if poll_err != nil do log.panicf("poll error: %v", poll_err)

	if sa.get(ctx._clients, 0).revents >= {.IN} {
		client_fd, client_err := linux.accept(ctx.server_fd, &ctx.server_addr, {.NONBLOCK})
		if client_err != nil do log.panicf("accept error %v", client_err)
		sa.append(&ctx._clients, linux.Poll_Fd{fd = client_fd, events = {.IN}})
	}

	#reverse for &client, idx in sa.slice(&ctx._clients)[1:] {
		if client.revents >= {.IN} {
			bytes_read, read_err := linux.read(client.fd, ctx._buf[:])
			if read_err != nil do log.panicf("read error %v: socket %v", read_err, client.fd)
			if bytes_read == 0 {
				log.debugf("client disconnected: socket %v", client.fd)
				linux.close(client.fd)
				sa.unordered_remove(&ctx._clients, idx + 1)
			} else {
				log.debugf("read %v bytes: socket %v", bytes_read, client.fd)
				msg_bytes := ctx._buf[:bytes_read]
				IPC_Server__handle_msg(ctx, mixd_ctx, client, msg_bytes)
			}
		}
	}
}

IPC_Server__handle_msg :: proc(
	ctx: ^IPC_Server_Context,
	mixd_ctx: ^Context,
	client: linux.Poll_Fd,
	msg_bytes: []u8,
) {
	msg: common.Message
	cbor.unmarshal(string(msg_bytes), &msg)

	switch msg in msg {
	case common.Volume:
		switch msg.act {
		case .Subscribe:
			IPC_Server_add_volume_subscriber(ctx, client.fd)
		case .Set:
			mixd_ctx.vol = clamp(msg.val, -1, 1)
			mixd_ctx.default_sink.volume, mixd_ctx.aux_sink.volume = sink_vols_from_ctx_vol(
				msg.val,
			)
			IPC_Server_notify_volume_subscription(ctx, mixd_ctx)
		case .Shift:
			mixd_ctx.vol += msg.val
			mixd_ctx.vol = clamp(mixd_ctx.vol, -1, 1)
			mixd_ctx.default_sink.volume, mixd_ctx.aux_sink.volume = sink_vols_from_ctx_vol(
				mixd_ctx.vol,
			)
			IPC_Server_notify_volume_subscription(ctx, mixd_ctx)
		case .Get:
			vol := common.Volume {
				act = .Get,
				val = mixd_ctx.vol,
			}
			IPC_Server_send(ctx, client.fd, vol)
		}

		sink_set_volume(&mixd_ctx.default_sink, mixd_ctx.default_sink.volume)
		sink_set_volume(&mixd_ctx.aux_sink, mixd_ctx.aux_sink.volume)
		// save out config volume to file
		{
			vol_str := fmt.tprintf("%f", mixd_ctx.vol)
			write_err := os2.write_entire_file(mixd_ctx.cache_file, transmute([]u8)vol_str)
			if write_err != nil {
				log.logf(.Error, "could not save out config file: %v", write_err)
			}
		}
	case common.Program:
		switch msg.act {
		case .Subscribe:
			IPC_Server_add_program_subscriber(ctx, client.fd)
		case .Add:
			log.logf(.Info, "Adding program %s", msg.val)
			add_program(mixd_ctx, msg.val)
			IPC_Server_notify_program_subscription(ctx, mixd_ctx)
		case .Remove:
			log.logf(.Info, "Removing program %s", msg.val)
			remove_program(mixd_ctx, msg.val)
			IPC_Server_notify_program_subscription(ctx, mixd_ctx)
		}

		// save out rules to file
		{
			builder: strings.Builder
			strings.builder_init(&builder, context.temp_allocator)
			for rule in mixd_ctx.aux_rules {
				fmt.sbprintln(&builder, rule)
			}
			rules_file := strings.to_string(builder)
			write_err := os2.write_entire_file(mixd_ctx.config_file, transmute([]u8)rules_file)
			if write_err != nil {
				log.logf(.Error, "could not save out config file: %v", write_err)
			}
		}
	}
}

IPC_Server_send :: proc(ctx: ^IPC_Server_Context, client_fd: linux.Fd, msg: common.Message) {
	cbor_msg, _ := cbor.marshal(msg)
	bytes_sent, send_err := linux.send(client_fd, cbor_msg, {})
	if send_err != nil do log.panicf("could not send with error %v", send_err)
	log.debugf("sent %v bytes from server", bytes_sent)
	delete(cbor_msg)
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

IPC_Server_notify_volume_subscription :: proc(ctx: ^IPC_Server_Context, mixd_ctx: ^Context) {
	msg := common.Volume{.Get, mixd_ctx.vol}
	for client_fd in sa.slice(&ctx._volume_subscribers) do IPC_Server_send(ctx, client_fd, msg)
}

IPC_Server_notify_program_subscription :: proc(ctx: ^IPC_Server_Context, mixd_ctx: ^Context) {
	// [TODO] implement way for active programs to be queried
	unimplemented()
}

IPC_Server_deinit :: proc(ctx: ^IPC_Server_Context) -> linux.Errno {
	for client in sa.slice(&ctx._clients) do linux.close(client.fd)
	return linux.close(ctx.server_fd)
}
