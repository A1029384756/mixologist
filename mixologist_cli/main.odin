package mixologist_cli

import pw "../pipewire"
import "core:log"
import "core:sys/posix"

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	sock := posix.socket(.UNIX, .STREAM)
	flags := transmute(posix.O_Flags)posix.fcntl(sock, .GETFL) + {.NONBLOCK}
	posix.fcntl(sock, .SETFL, flags)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], "/tmp/mixologist\x00")

	if posix.connect(sock, cast(^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		log.panic("could not connect to socket")
	}

	message := "this is an arbitrary message"

	n_bytes := posix.send(sock, raw_data(message), len(message), {})
	if n_bytes == -1 {
		log.panicf("could not send data with error %v", posix.errno())
	}
	log.logf(.Debug, "sent bytes to server, got %d bytes", n_bytes)
}
