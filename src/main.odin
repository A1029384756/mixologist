package mixologist

import "base:runtime"
import "core:log"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

PROFILING :: #config(profiling, false)

Features :: bit_set[Feature]
Feature :: enum {
	GlobalShortcuts,
	Daemon,
	Gui,
}

Event :: union {
	Rule_Add,
	Rule_Remove,
	Rule_Update,
	Program_Add,
	Program_Remove,
	Settings,
	Open,
}
Rule_Add :: distinct string
Rule_Remove :: distinct string
Program_Add :: distinct string
Program_Remove :: distinct string
Rule_Update :: struct {
	prev: string,
	cur:  string,
}
Open :: distinct rawptr

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

quit_requested: bool

handle_term :: proc "c" (_: posix.Signal) {
	sync.atomic_store_explicit(&quit_requested, true, .Relaxed)
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
	context.logger = mixologist_init_logging()
	defer mixologist_deinit_logging(default_heap)

	context.allocator = mixologist_init_allocator()
	defer mixologist_deinit_allocator()

	// command line parsing
	features: Features
	cli_init()
	defer cli_deinit()
	if cli.opts.daemon {
		features += {.Daemon}
	} else if !cli.option_sel {
		features += {.Daemon, .Gui}
	} else {
		cli_messages(cli)
		return
	}

	bus_init()
	file_manager_init()
	if err := ipc_init(); err != nil {
		if err == .EADDRINUSE {
			log.fatalf("could not start mixologist ipc, is another instance already running?")
		} else {
			log.fatalf("could not start ipc: %v", err)
		}
		bus_deinit()
		return
	}
	if global_shortcuts_init() {
		features += {.GlobalShortcuts}
	}
	if .Daemon in features {
		daemon_init()
	}
	if .Gui in features {
		gui_init()
	}

	threads: [dynamic; 8]^thread.Thread
	file_manager_seed_state()
	append(&threads, thread.create_and_start(ipc_proc, context))
	append(&threads, thread.create_and_start(file_manager_proc, context))
	if .GlobalShortcuts in features {
		append(&threads, thread.create_and_start(global_shortcuts_proc, context))
	}
	if .Daemon in features {
		append(&threads, thread.create_and_start(daemon_proc, context))
	}
	if .Gui in features {
		append(&threads, thread.create_and_start(gui_proc, context))
	}

	posix.signal(.SIGINT, handle_term)
	posix.signal(.SIGTERM, handle_term)
	thread.join_multiple(..threads[:])

	if .GlobalShortcuts in features {
		global_shortcuts_deinit()
	}
	if .Daemon in features {
		daemon_deinit()
	}
	if .Gui in features {
		gui_deinit()
	}
	file_manager_deinit()
	ipc_deinit()
	bus_deinit()
}

mixologist_init_logging :: proc() -> log.Logger {
	when ODIN_DEBUG {
		return log.create_console_logger(
			get_log_level(),
			log.Default_Console_Logger_Opts + {.Thread_Id},
		)
	} else {
		cache_dir, _ := os.user_cache_dir(context.allocator)
		defer delete(cache_dir)
		mixologist_cache_dir, _ := os.join_path({cache_dir, "mixologist"}, context.allocator)

		log_path :=
			os.join_path(
				{mixologist_cache_dir, "mixologist.log"},
				context.allocator,
			) or_else log.panic("could not create log path")

		open_flags := os.File_Flags{.Write, .Create}
		TRUNC_THRESHOLD :: 1024 * 1024 // 1MB

		if os.exists(log_path) {
			log_info, stat_err := os.stat(log_path, context.allocator)

			if stat_err != nil && log_info.size > TRUNC_THRESHOLD {
				open_flags += {.Trunc}
			} else if log_info.size <= TRUNC_THRESHOLD {
				open_flags += {.Append}
			}
		}

		log_file := os.open(log_path, open_flags) or_else log.panic("could not access log file")
		return log.create_file_logger(
			log_file,
			get_log_level(),
			log.Default_File_Logger_Opts + {.Thread_Id},
		)
	}
}

mixologist_deinit_logging :: proc(allocator := context.allocator) {
	when ODIN_DEBUG {
		log.destroy_console_logger(context.logger, allocator)
	} else {
		log.destroy_file_logger(context.logger, allocator)
	}
}

mixologist_init_allocator :: proc() -> runtime.Allocator {
	when ODIN_DEBUG {
		mem.tracking_allocator_init(&track, context.allocator)
		return mem.tracking_allocator(&track)
	} else {
		return context.allocator
	}
}

mixologist_deinit_allocator :: proc() {
	when ODIN_DEBUG {
		for _, leak in track.allocation_map {
			if strings.contains(leak.location.file_path, "mixologist") {
				log.warnf("%v leaked %m\n", leak.location, leak.size)
			}
		}
	}
}
