package mixologist_cli

import "../common"
import "core:encoding/cbor"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:log"
import "core:os/os2"
import "core:sys/posix"

Options :: struct {
	set_volume:     f32 `args:"name=set-volume" usage:"volume to assign nodes"`,
	shift_volume:   f32 `args:"name=shift-volume" usage:"volume to increment nodes"`,
	add_program:    [dynamic]string `args:"name=add-program" usage:"name of program to add to aux"`,
	remove_program: [dynamic]string `args:"name=remove-program" usage:"name of program to remove from aux"`,
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
	context.logger = log.create_console_logger()
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
}

send_message :: proc(msg: common.Message) {
	message, encoding_err := cbor.marshal(msg)
	assert(encoding_err == nil)
	defer delete(message)

	sock := posix.socket(.UNIX, .STREAM)
	flags := transmute(posix.O_Flags)posix.fcntl(sock, .GETFL) + {.NONBLOCK}
	posix.fcntl(sock, .SETFL, flags)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], "\x00mixologist")

	if posix.connect(sock, cast(^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		log.panic("could not connect to socket, is the mixologist daemon running?")
	}

	n_bytes := posix.send(sock, raw_data(message), len(message), {})
	if n_bytes == -1 {
		log.panicf("could not send data with error %v", posix.errno())
	}
	log.logf(.Debug, "sent bytes to server, got %d bytes", n_bytes)
}
