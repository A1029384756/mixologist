package mixologist

import "base:runtime"
import "core:encoding/cbor"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"

ProgramList :: distinct [dynamic]string

CLIArgs :: struct {
	set_volume:   f32 `usage:"volume to assign nodes"`,
	shift_volume: f32 `usage:"volume to increment nodes"`,
	add_rule:     ProgramList `usage:"rule to add"`,
	remove_rule:  ProgramList `usage:"rule to remove"`,
	get_volume:   bool `usage:"the current mixologist volume"`,
	daemon:       bool `usage:"start mixologist in daemon mode (no window)"`,
}

CLIState :: struct {
	option_sel: bool,
	get_volume: bool,
	set_volume: bool,
	add_volume: bool,
	opts:       CLIArgs,
}

cli: CLIState

type_setter :: proc(
	data: rawptr,
	data_type: typeid,
	unparsed_value: string,
	args_tag: string,
) -> (
	error: string,
	handled: bool,
	alloc_error: runtime.Allocator_Error,
) {
	if data_type == ProgramList {
		handled = true
		list := cast(^ProgramList)data
		programs := unparsed_value
		for program in strings.split_iterator(&programs, ",") {
			append(list, program)
		}
	}
	return
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
		if cli.set_volume || cli.add_volume || cli.get_volume {
			error = "cannot perform multiple volume operations at once"
			return
		}

		if name == "set_volume" {
			cli.set_volume = true
		} else if name == "shift_volume" {
			cli.add_volume = true
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

cli_init :: proc() {
	flags.register_type_setter(type_setter)
	flags.register_flag_checker(flag_checker)
	flags.parse_or_exit(&cli.opts, os.args, .Odin)
}

cli_deinit :: proc() {
	delete(cli.opts.add_rule)
	delete(cli.opts.remove_rule)
}

cli_messages :: proc(cli: CLIState) {
	if cli.set_volume {
		send_message({topic = .Volume, volume = {kind = .Set, data = cli.opts.set_volume}})
	} else if cli.add_volume {
		send_message({topic = .Volume, volume = {kind = .Add, data = cli.opts.set_volume}})
	}

	for program in cli.opts.add_rule {
		send_message({topic = .Rule, list = {kind = .Add, val = program}})
	}

	for program in cli.opts.remove_rule {
		send_message({topic = .Rule, list = {kind = .Remove, val = program}})
	}

	if cli.opts.get_volume {
		// todo fix
		send_message({topic = .Volume, volume = {kind = .Get}}, true)
	}
}

send_message :: proc(msg: Message, recv := false) {
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

		response: Message
		response_err := cbor.unmarshal(string(buf[:bytes_read]), &response)
		if response_err != nil do log.panicf("unmarshal from server failed: %v", response_err)
		res := response.volume.data
		fmt.println(res)
		break
	}
}
