package mixologist

import "../common"
import "core:encoding/cbor"
import "core:fmt"
import "core:log"
import "core:sys/linux"


CLI_Args :: struct {
	set_volume:     f32 `usage:"volume to assign nodes"`,
	shift_volume:   f32 `usage:"volume to increment nodes"`,
	add_program:    [dynamic]string `usage:"name of program to add to aux"`,
	remove_program: [dynamic]string `usage:"name of program to remove from aux"`,
	get_volume:     bool `usage:"the current mixologist volume"`,
	daemon:         bool `usage:"start mixologist in daemon mode (no window)"`,
}

CLI_State :: struct {
	option_sel:   bool,
	get_volume:   bool,
	set_volume:   bool,
	shift_volume: bool,
	opts:         CLI_Args,
}

flag_checker :: proc(
	model: rawptr,
	name: string,
	value: any,
	args_tag: string,
) -> (
	error: string,
) {
	if name == "daemon" {
		if cli.option_sel {
			error = "\"-daemon\" cannot be used with other flags"
			return
		}
	} else if name == "set_volume" || name == "shift_volume" || name == "get_volume" {
		if cli.set_volume || cli.shift_volume || cli.get_volume {
			error = "cannot perform multiple volume operations at once"
			return
		}

		if name == "set_volume" {
			cli.set_volume = true
		} else if name == "shift_volume" {
			cli.shift_volume = true
		} else if name == "get_volume" {
			cli.get_volume = true
			cli.option_sel = true
			return
		}

		v := value.(f32)
		if -1 > v || v > 1 {
			error = fmt.tprintf("incorrect volume %v. Must be between `-1` and `1`", v)
		}
	}
	cli.option_sel = true

	return
}

cli_messages :: proc(cli: CLI_State) {
	if cli.set_volume {
		send_message(common.Volume{.Set, cli.opts.set_volume})
	} else if cli.shift_volume {
		send_message(common.Volume{.Shift, cli.opts.shift_volume})
	}

	for program in cli.opts.add_program {
		msg := common.Program {
			act = .Add,
			val = program,
		}
		send_message(msg)
	}

	for program in cli.opts.remove_program {
		msg := common.Program {
			act = .Remove,
			val = program,
		}
		send_message(msg)
	}

	if cli.opts.get_volume {
		msg := common.Volume {
			act = .Get,
			val = 0,
		}
		send_message(msg, true)
	}
}

send_message :: proc(msg: common.Message, recv := false) {
	message, encoding_err := cbor.marshal(msg)
	assert(encoding_err == nil)
	defer delete(message)

	client_fd, socket_err := linux.socket(.UNIX, .STREAM, {.NONBLOCK}, .HOPOPT)
	defer linux.close(client_fd)
	if socket_err != nil do log.panicf("could not create socket with error %v", socket_err)

	client_addr: linux.Sock_Addr_Un
	client_addr.sun_family = .UNIX
	copy(client_addr.sun_path[:], SERVER_SOCKET)

	connect_err := linux.connect(client_fd, &client_addr)
	if connect_err != nil do log.panicf("could not connect to socket with error %v, message %v", connect_err, msg)

	bytes_sent, send_err := linux.send(client_fd, message, {})
	if send_err != nil do log.panicf("could not send data with error %v", send_err)
	log.debugf("sent bytes %d bytes to server", bytes_sent)
	if !recv do return

	buf: [1024]u8
	for {
		bytes_read, recv_err := linux.recv(client_fd, buf[:], {})
		if recv_err != nil {
			if recv_err == .EWOULDBLOCK || recv_err == .EAGAIN do continue
			else do log.panicf("could not recv data with error %v", recv_err)
		}

		log.logf(.Debug, "recieved %d bytes from server", bytes_read)

		response: common.Message
		response_err := cbor.unmarshal(string(buf[:bytes_read]), &response)
		if response_err != nil do log.panicf("unmarhal from server failed: %v", response_err)
		res := response.(common.Volume)
		fmt.println(res.val)
		break
	}
}
