package mixologist_gui

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
BUF_SIZE :: 1024

IPC_Client_Context :: struct {
	client_fd:   linux.Fd,
	client_addr: linux.Sock_Addr_Un,
	_buf:        [BUF_SIZE]u8,
}

IPC_Client_init :: proc(ctx: ^IPC_Client_Context) -> linux.Errno {
	ctx.client_fd = linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT) or_return

	ctx.client_addr.sun_family = .UNIX
	copy(ctx.client_addr.sun_path[:], SERVER_SOCKET)

	return linux.connect(ctx.client_fd, &ctx.client_addr)
}

IPC_Client_recv :: proc(ctx: ^IPC_Client_Context, mixgui_ctx: ^Context) {
	bytes_read, recv_err := linux.recv(ctx.client_fd, ctx._buf[:], {})
	if recv_err != nil {
		if recv_err == .EAGAIN || recv_err == .EWOULDBLOCK do return
		log.panicf("could not read from socket: %v, is mixd running?", recv_err)
	}
	log.debugf("read %d bytes", bytes_read)

	msg: common.Message
	cbor.unmarshal(string(ctx._buf[:bytes_read]), &msg)

	switch msg in msg {
	case common.Volume:
		#partial switch msg.act {
		case .Get:
			mixgui_ctx.volume = msg.val
		case:
			panic("recieved invalid action")
		}
	case common.Program:
		#partial switch msg.act {
		case:
			panic("recieved invalid action")
		}
	}
}

IPC_Client_send :: proc(ctx: ^IPC_Client_Context, msg: common.Message) {
	cbor_msg, _ := cbor.marshal(msg)
	res, _ := linux.send(ctx.client_fd, cbor_msg, {})
	log.debugf("sent %v bytes: socket %v", res, ctx.client_fd)
	delete(cbor_msg)
}

IPC_Client_deinit :: proc(ctx: ^IPC_Client_Context) -> linux.Errno {
	return linux.close(ctx.client_fd)
}
