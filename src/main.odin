package mixologist

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import sdl "vendor:sdl3"

PROFILING :: #config(profiling, false)

shared_state: SharedState
SharedState :: struct {
	odin_ctx:      runtime.Context,
	gui_chan:      chan.Chan(Message),
	daemon_chan:   chan.Chan(Message),
	state_eventfd: linux.Fd,
	quit_eventfd:  linux.Fd,
	is_daemon:     bool,
}
shared_state_init :: proc() {
	shared_state.odin_ctx = context
	shared_state.gui_chan, _ = chan.create_buffered(MessageChan, 128, context.allocator)
	shared_state.daemon_chan, _ = chan.create_buffered(MessageChan, 128, context.allocator)
	shared_state.quit_eventfd, _ = linux.eventfd(0, {})
	shared_state.state_eventfd, _ = linux.eventfd(0, {})
}
shared_state_fini :: proc() {
	message_chan_flush(shared_state.gui_chan)
	message_chan_flush(shared_state.daemon_chan)
	chan.close(shared_state.gui_chan)
	chan.close(shared_state.daemon_chan)
	chan.destroy(shared_state.gui_chan)
	chan.destroy(shared_state.daemon_chan)
	linux.close(shared_state.quit_eventfd)
	linux.close(shared_state.state_eventfd)
}

main :: proc() {
	when PROFILING {
		spall_ctx = spall.context_create("mixologist_" + ODIN_OS_STRING + ".spall")
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(os.get_current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
	}

	default_heap := context.allocator
	directories_init(default_heap, context.temp_allocator)

	context.logger = logging_init()
	defer logging_fini(default_heap)

	context.allocator = allocator_init()
	defer allocator_fini()

	cli_init()
	defer cli_fini()
	if cli.opts.daemon {
		shared_state.is_daemon = true
	} else if cli.option_sel {
		cli_messages()
		return
	}

	if err := ipc_init(); err != nil {
		if err == .EADDRINUSE {
			log.infof("mixologist already running, sending wake command")
			cli_send_message({kind = .Wake})
		} else {
			log.fatalf("could not start ipc: %v", err)
		}
		return
	}

	posix.signal(.SIGINT, handle_term)
	posix.signal(.SIGTERM, handle_term)

	config_init()
	shared_state_init()

	daemon_init()
	if shared_state.is_daemon {
		daemon_proc()
	} else {
		gui_init()
		gui := thread.create_and_start(gui_proc, context)
		daemon_proc()
		thread.join(gui)
	}
	daemon_fini()

	shared_state_fini()
	config_fini()
	directories_fini(default_heap)
}

directories: Directories
Directories :: struct {
	config: string,
	cache:  string,
}
directories_init :: proc(allocator, temp_allocator: runtime.Allocator) {
	user_config_dir, _ := os.user_config_dir(temp_allocator)
	directories.config, _ = os.join_path({user_config_dir, "mixologist"}, allocator)
	if !os.exists(directories.config) {
		config_dir_err := os.make_directory_all(directories.config)
		if config_dir_err != nil {
			panic("could not create config dir")
		}
	}

	user_cache_dir, _ := os.user_cache_dir(temp_allocator)
	directories.cache, _ = os.join_path({user_cache_dir, "mixologist"}, allocator)
	if !os.exists(directories.cache) {
		cache_dir_err := os.make_directory_all(directories.cache)
		if cache_dir_err != nil {
			panic("could not create config dir")
		}
	}
}

directories_fini :: proc(allocator: runtime.Allocator) {
	delete(directories.cache, allocator)
	delete(directories.config, allocator)
}

logging_init :: proc() -> log.Logger {
	when ODIN_DEBUG {
		return log.create_console_logger(
			get_log_level(),
			log.Default_Console_Logger_Opts + {.Thread_Id},
		)
	} else {
		log_path :=
			os.join_path(
				{directories.cache, "mixologist.log"},
				context.temp_allocator,
			) or_else log.panic("could not create log path")

		open_flags := os.File_Flags{.Write, .Create}
		TRUNC_THRESHOLD :: 1024 * 1024 // 1MB

		if os.exists(log_path) {
			log_info, stat_err := os.stat(log_path, context.temp_allocator)

			if stat_err != nil && log_info.size > TRUNC_THRESHOLD {
				open_flags += {.Trunc}
			} else if log_info.size <= TRUNC_THRESHOLD {
				open_flags += {.Append}
			}
		}

		log_file := os.open(log_path, open_flags) or_else panic("could not access log file")
		return log.create_file_logger(
			log_file,
			get_log_level(),
			log.Default_File_Logger_Opts + {.Thread_Id},
		)
	}
}

logging_fini :: proc(allocator := context.allocator) {
	when ODIN_DEBUG {
		log.destroy_console_logger(context.logger, allocator)
	} else {
		log.destroy_file_logger(context.logger, allocator)
	}
}

allocator_init :: proc() -> runtime.Allocator {
	when ODIN_DEBUG {
		mem.tracking_allocator_init(&track, context.allocator)
		return mem.tracking_allocator(&track)
	} else {
		return context.allocator
	}
}

allocator_fini :: proc() {
	when ODIN_DEBUG {
		for _, leak in track.allocation_map {
			if strings.contains(leak.location.file_path, "mixologist") {
				log.warnf("%v leaked %m\n", leak.location, leak.size)
			}
		}
	}
}

when ODIN_DEBUG {
	track: mem.Tracking_Allocator
}

when PROFILING {
	spall_ctx: spall.Context
	@(thread_local)
	spall_buffer: spall.Buffer

	@(instrumentation_enter)
	spall_enter :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (
		proc_address, call_site_return_address: rawptr,
		loc: runtime.Source_Code_Location,
	) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}

handle_term :: proc "c" (_: posix.Signal) {
	context = shared_state.odin_ctx
	if sync.atomic_load_explicit(&gui.finished_setup, .Relaxed) {
		_ = sdl.PushEvent(&{type = .QUIT})
	}
	eventfd_write(shared_state.quit_eventfd)
}
