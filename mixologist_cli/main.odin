package mixologist_cli

import "../common"
import "core:encoding/cbor"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:log"
import "core:os/os2"
import "core:sys/linux"

SERVER_SOCKET :: "\x00mixologist"

Options :: struct {
	set_volume:     f32 `args:"name=set-volume" usage:"volume to assign nodes"`,
	shift_volume:   f32 `args:"name=shift-volume" usage:"volume to increment nodes"`,
	add_program:    [dynamic]string `args:"name=add-program" usage:"name of program to add to aux"`,
	remove_program: [dynamic]string `args:"name=remove-program" usage:"name of program to remove from aux"`,
	get_volume:     bool `args:"name=get-volume" usage:"the current mixologist volume"`,
}

State :: struct {
	option_sel:   bool,
	set_volume:   bool,
	shift_volume: bool,
	opts:         Options,
}

flag_checker :: proc(
	model: rawptr,
	name: string,
	value: any,
	args_tag: string,
) -> (
	error: string,
) {
	state.option_sel = true
	if name == "set_volume" || name == "shift_volume" {
		if state.set_volume || state.shift_volume {
			error = "cannot set volume and shift volume in same command"
		}

		if name == "set_volume" {
			state.set_volume = true
		} else if name == "shift_volume" {
			state.shift_volume = true
		}

		v := value.(f32)
		if -1 > v || v > 1 {
			error = fmt.tprintf("incorrect volume %v. Must be between `-1` and `1`", v)
		}
	}

	return
}

state: State
main :: proc() {
	context.logger = log.create_console_logger(lowest = common.get_log_level())
	defer log.destroy_console_logger(context.logger)

	flags.register_flag_checker(flag_checker)
	flags.parse_or_exit(&state.opts, os2.args, .Odin)
	if !state.option_sel {
		flags.write_usage(io.to_writer(os2.stdout.stream), Options)
		os2.exit(1)
	}

	if state.set_volume {
		send_message(common.Volume{.Set, state.opts.set_volume})
	} else if state.shift_volume {
		send_message(common.Volume{.Shift, state.opts.shift_volume})
	}

	for program in state.opts.add_program {
		msg := common.Program {
			act = .Add,
			val = program,
		}
		send_message(msg)
	}

	for program in state.opts.remove_program {
		msg := common.Program {
			act = .Remove,
			val = program,
		}
		send_message(msg)
	}

	if state.opts.get_volume {
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
	if connect_err != nil do log.panicf("could not connect to socket with error %v", connect_err)

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
