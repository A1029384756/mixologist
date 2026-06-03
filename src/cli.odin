package mixologist

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "dbus"

RuleList :: distinct [dynamic]string

CLIArgs :: struct {
	set_volume:   f32 `usage:"volume to assign nodes"`,
	shift_volume: f32 `usage:"volume to increment nodes"`,
	add_rule:     RuleList `usage:"rule to add"`,
	remove_rule:  RuleList `usage:"rule to remove"`,
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
	if data_type == RuleList {
		handled = true
		list := cast(^RuleList)data
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

cli_fini :: proc() {
	delete(cli.opts.add_rule)
	delete(cli.opts.remove_rule)
}

cli_messages :: proc() -> IpcError {
	context.logger = log.create_console_logger(
		get_log_level(),
		log.Default_Console_Logger_Opts + {.Thread_Id},
	)

	conn, name := dbus_open_connection_with_name(fmt.tprintf("client-%v", os.get_pid())) or_return
	defer delete(name)

	if cli.set_volume {
		cli_send_message(conn, {kind = .Volume, volume = {kind = .Set, val = cli.opts.set_volume}})
	} else if cli.add_volume {
		cli_send_message(conn, {kind = .Volume, volume = {kind = .Add, val = cli.opts.set_volume}})
	}

	for program in cli.opts.add_rule {
		cli_send_message(conn, {kind = .Rule, list = {kind = .Add, val = program}})
	}

	for program in cli.opts.remove_rule {
		cli_send_message(conn, {kind = .Rule, list = {kind = .Remove, val = program}})
	}

	if cli.opts.get_volume {
		cli_send_message(conn, {kind = .Volume, volume = {kind = .Get}}, true)
	}
	dbus.connection_flush(conn)
	dbus.connection_close(conn)
	return nil
}

cli_send_message :: proc(conn: ^dbus.Connection, msg: Message, recv := false) {
	err: dbus.Error
	dbus.error_init(&err)
	defer if dbus.error_is_set(&err) {dbus.error_free(&err)}

	#partial switch msg.kind {
	case .Wake:
		wake_msg := dbus.message_new_method_call(APP_ID, IPC_OBJECT_PATH, APP_ID, IPC_METHOD_WAKE)
		_send_and_recv(conn, wake_msg)
	case .Rule:
		rule_msg := dbus.message_new_method_call(APP_ID, IPC_OBJECT_PATH, APP_ID, IPC_METHOD_RULE)
		defer dbus.message_unref(rule_msg)
		if err := dbus.marshal(rule_msg, msg.list); err != nil {
			log.panic("could not marshal rule message")
		}
		_send_and_recv(conn, rule_msg)
	case .Volume:
		rule_msg := dbus.message_new_method_call(
			APP_ID,
			IPC_OBJECT_PATH,
			APP_ID,
			IPC_METHOD_VOLUME,
		)
		defer dbus.message_unref(rule_msg)
		if err := dbus.marshal(rule_msg, msg.volume); err != nil {
			log.panicf("could not marshal volume message: %v", err)
		}
		if msg.volume.kind == .Get {
			reply := dbus.connection_send_with_reply_and_block(
				conn,
				rule_msg,
				dbus.TIMEOUT_USE_DEFAULT,
				&err,
			)
			defer dbus.message_unref(reply)
			v: Volume
			if err := dbus.unmarshal(reply, &v); err != nil {
				log.panicf("could not unmarshal volume response: %v", err)
			}
			fmt.println(v.val)
		} else {
			_send_and_recv(conn, rule_msg)
		}
	case:
		log.panicf("unexpected message kind via ipc")
	}
}

_send_and_recv :: proc(conn: ^dbus.Connection, msg: ^dbus.Message) {
	err: dbus.Error
	dbus.error_init(&err)
	defer if dbus.error_is_set(&err) {
		log.error("error sending message")
		dbus.error_free(&err)
	}

	reply := dbus.connection_send_with_reply_and_block(conn, msg, dbus.TIMEOUT_USE_DEFAULT, &err)
	dbus.message_unref(reply)
}
