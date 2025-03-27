package mixologist_gui

import "../common"
import "./clay"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:strings"
import "core:sys/linux"

EVENT_SIZE :: size_of(linux.Inotify_Event)
EVENT_BUF_LEN :: 1024 * (EVENT_SIZE + 16)
IPC_DELAY_MS :: 500

Context_Status :: enum u8 {
	ADDING_NEW,
	ADDING,
	RULES,
	VOLUME,
	CONNECTED,
}
Context_Statuses :: bit_set[Context_Status]

Context :: struct {
	ui_ctx:          UI_Context,
	// rule modification
	active_line_buf: [1024]u8,
	active_line_len: int,
	active_line:     int,
	volume:          f32,
	// rule creation
	new_rule_buf:    [1024]u8,
	new_rule_len:    int,
	rule_scrollbar:  UI_Scrollbar_Data,
	// config state
	aux_rules:       [dynamic]string,
	config_file:     string,
	inotify_fd:      linux.Fd,
	inotify_wd:      linux.Wd,
	statuses:        Context_Statuses,
	// ipc
	ipc:             IPC_Client_Context,
	// allocations
	arena:           virtual.Arena,
	allocator:       mem.Allocator,
}

main :: proc() {
	// set up logging
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(lowest = common.get_log_level())
		defer log.destroy_console_logger(context.logger)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	ctx: Context
	if virtual.arena_init_growing(&ctx.arena) != nil {
		panic("Couldn't initialize arena")
	}
	ctx.allocator = virtual.arena_allocator(&ctx.arena)

	// load config rules from disk
	{
		config_dir := os2.user_config_dir(ctx.allocator) or_else panic("config dir not found")
		config_dir = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist"},
			ctx.allocator,
		)
		if !os2.exists(config_dir) {
			os2.mkdir(config_dir)
		}

		ctx.config_file = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist.conf"},
			ctx.allocator,
		)

		reload_config(&ctx)

		// set up config file watch
		{
			in_err: linux.Errno
			ctx.inotify_fd, in_err = linux.inotify_init1({.NONBLOCK})
			assert(in_err == nil)
			ctx.inotify_wd, in_err = linux.inotify_add_watch(
				ctx.inotify_fd,
				strings.clone_to_cstring(config_dir, ctx.allocator),
				{.CREATE, .DELETE, .MODIFY} + linux.IN_MOVE,
			)
			assert(in_err == nil)
		}
	}

	connection := mixgui_connect(&ctx)
	if connection == nil do ctx.statuses += {.CONNECTED}

	UI_init(&ctx.ui_ctx)
	UI_load_font_mem(&ctx.ui_ctx, 16, #load("resources/fonts/Roboto-Regular.ttf"))

	mainloop: for !UI_should_exit(&ctx.ui_ctx) {
		// rule reloading
		{
			inotify_buf: [EVENT_BUF_LEN]u8
			length, read_err := linux.read(ctx.inotify_fd, inotify_buf[:])
			assert(read_err == nil || read_err == .EAGAIN)

			config_modified := false
			for i := 0; i < length; {
				event := cast(^linux.Inotify_Event)&inotify_buf[i]

				if transmute(cstring)uintptr(&event.name) == "mixologist.conf" {
					config_modified = true
					break
				}

				i += EVENT_SIZE + int(event.len)
			}

			if config_modified {
				reload_config(&ctx)
			}
		}

		// ipc
		if .CONNECTED in ctx.statuses {
			if .VOLUME in ctx.statuses {
				ctx.statuses -= {.VOLUME}
				mixd_set_volume(&ctx)
			}
			IPC_Client_recv(&ctx.ipc, &ctx)
		} else {
			if mixgui_connect(&ctx) == .NONE do ctx.statuses += {.CONNECTED}
		}

		UI_tick(&ctx.ui_ctx, UI_create_layout, &ctx)

		if .RULES in ctx.statuses {
			save_rules(&ctx)
			ctx.statuses -= {.RULES}
			ctx.active_line = 0
			UI_unfocus_all(&ctx.ui_ctx)
		}
		free_all(context.temp_allocator)
	}

	if .CONNECTED in ctx.statuses do IPC_Client_deinit(&ctx.ipc)
	UI_deinit(&ctx.ui_ctx)
	for &rule in ctx.aux_rules {
		delete(rule)
	}
	delete(ctx.aux_rules)
}

UI_create_layout :: proc(
	ctx: ^UI_Context,
	userdata: rawptr,
) -> clay.ClayArray(clay.RenderCommand) {
	mgst_ctx := cast(^Context)userdata
	return create_layout(mgst_ctx)
}

mixgui_connect :: proc(ctx: ^Context) -> linux.Errno {
	log.debugf("attempting to connect to mixd...")
	IPC_Client_init(&ctx.ipc) or_return
	return IPC_Client_send(&ctx.ipc, common.Volume{.Subscribe, 0})
}

mixd_set_volume :: proc(ctx: ^Context) {
	msg := common.Volume {
		act = .Set,
		val = ctx.volume,
	}
	log.debugf("sending volume of %v", msg.val)
	IPC_Client_send(&ctx.ipc, msg)
}

reload_config :: proc(ctx: ^Context) {
	assert(len(ctx.config_file) > 0, "must load config before running")
	for &rule in ctx.aux_rules {
		delete(rule)
	}
	clear(&ctx.aux_rules)
	file_bytes, config_file_err := os2.read_entire_file(ctx.config_file, context.allocator)
	defer delete(file_bytes)

	file_string: string
	if config_file_err == nil {
		file_string = string(file_bytes)
	} else {
		log.errorf("could not get read file")
	}

	for line in strings.split_lines_iterator(&file_string) {
		append(&ctx.aux_rules, strings.clone(line))
	}
}

save_rules :: proc(ctx: ^Context) {
	// save out rules to file
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for rule in ctx.aux_rules {
		fmt.sbprintln(&builder, rule)
	}
	rules_file := strings.to_string(builder)
	write_err := os2.write_entire_file(ctx.config_file, transmute([]u8)rules_file)
	if write_err != nil {
		log.errorf("could not save out config file: %v", write_err)
	}
}

create_layout :: proc(ctx: ^Context) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI()(
	{id = clay.ID("root"), layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}},
	) {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BASE,
		},
		) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
				if clay.UI()(
				{
					id = clay.ID("rules"),
					layout = {
						sizing = {clay.SizingGrow({}), clay.SizingFit({})},
						padding = clay.PaddingAll(16),
						childAlignment = {x = .Center},
					},
					scroll = {vertical = true},
				},
				) {
					if clay.UI()(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {clay.SizingPercent(0.8), clay.SizingGrow({})},
						},
						backgroundColor = MANTLE,
						cornerRadius = clay.CornerRadiusAll(10),
					},
					) {
						if clay.UI()(
						{
							layout = {
								sizing = {clay.SizingPercent(1), clay.SizingFit({})},
								layoutDirection = .TopToBottom,
								padding = clay.PaddingAll(16),
								childGap = 8,
							},
						},
						) {
							rules_label(ctx)

							if clay.UI()(
							{
								layout = {
									sizing = {clay.SizingPercent(1), clay.SizingFit({})},
									layoutDirection = .TopToBottom,
								},
								backgroundColor = CRUST,
								cornerRadius = clay.CornerRadiusAll(10),
							},
							) {
								for &elem, i in ctx.aux_rules do rule_line(ctx, &elem, i + 1, len(ctx.aux_rules))
							}
						}
					}
				}
				scrollbar(ctx)
			}

			volume_slider(ctx)
		}
	}
	disconnected_overlay(ctx)
	rule_add_modal(ctx)

	return clay.EndLayout()
}

disconnected_overlay :: proc(ctx: ^Context) {
	if .CONNECTED not_in ctx.statuses {
		if clay.UI()(
		{
			floating = {
				attachment = {element = .CenterCenter, parent = .CenterCenter},
				attachTo = .Parent,
			},
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = CRUST * {1, 1, 1, 0.75},
		},
		) {
			if clay.UI()(
			{
				layout = {
					sizing = {clay.SizingPercent(0.7), clay.SizingPercent(0.7)},
					childAlignment = {x = .Center, y = .Center},
					layoutDirection = .TopToBottom,
					childGap = 16,
				},
				backgroundColor = BASE,
				cornerRadius = clay.CornerRadiusAll(5),
			},
			) {
				clay.Text(
					"Could not connect to Mixd",
					clay.TextConfig({textColor = TEXT, fontSize = 32}),
				)
				clay.Text(
					"Is it running?",
					clay.TextConfig({textColor = SUBTEXT_0, fontSize = 24}),
				)
			}
		}
	}
}

volume_slider :: proc(ctx: ^Context) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFixed(48)},
			padding = clay.PaddingAll(16),
			childGap = 12,
			childAlignment = {.Center, .Center},
			layoutDirection = .LeftToRight,
		},
		backgroundColor = SURFACE_0,
	},
	) {
		slider_res, _ := UI_slider(
			&ctx.ui_ctx,
			&ctx.volume,
			0,
			-1,
			1,
			OVERLAY_2,
			OVERLAY_1,
			OVERLAY_0,
			SURFACE_2,
			MAUVE,
			{sizing = {clay.SizingGrow({}), clay.SizingFixed(16)}},
			0.025,
			0,
		)

		if .CHANGE in slider_res do ctx.statuses += {.VOLUME}
	}
}

scrollbar :: proc(ctx: ^Context) {
	if clay.UI()(
	{layout = {sizing = {clay.SizingFit({}), clay.SizingGrow({})}, padding = {right = 4}}},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingFit({}), clay.SizingGrow({})},
				childAlignment = {.Right, .Top},
			},
		},
		) {
			UI_scrollbar(
				&ctx.ui_ctx,
				clay.GetScrollContainerData(clay.GetElementId(clay.MakeString("rules"))),
				&ctx.rule_scrollbar,
				8,
				SURFACE_1,
				SURFACE_2,
				OVERLAY_0,
				OVERLAY_1,
			)
		}
	}
}

rules_label :: proc(ctx: ^Context) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingFit({}), clay.SizingGrow({})},
				childGap = 8,
				layoutDirection = .TopToBottom,
			},
		},
		) {
			UI_textlabel("Rules", {textColor = TEXT, fontSize = 20})
			UI_textlabel("Selected Programs", {textColor = TEXT * 0.8, fontSize = 16})
		}
		UI_spacer(&ctx.ui_ctx)

		res, _ := UI_text_button(
			&ctx.ui_ctx,
			"Add Rule",
			{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
			clay.CornerRadiusAll(5),
			SURFACE_2,
			SURFACE_1,
			SURFACE_0,
			TEXT,
			16,
			5,
		)

		if .RELEASE in res {
			ctx.statuses += {.ADDING, .ADDING_NEW}
		}
	}
}

rule_line :: proc(ctx: ^Context, entry: ^string, idx, rule_count: int) {
	if clay.UI()(
	{
		layout = {
			layoutDirection = .LeftToRight,
			sizing = {clay.SizingPercent(1), clay.SizingFixed(64)},
			padding = clay.PaddingAll(16),
			childAlignment = {y = .Center},
		},
	},
	) {
		row_selected := idx == ctx.active_line

		tb_res, tb_id := UI_textbox(
			&ctx.ui_ctx,
			ctx.active_line_buf[:],
			&ctx.active_line_len,
			row_selected ? string(ctx.active_line_buf[:ctx.active_line_len]) : entry^,
			{
				layout = {
					sizing = {clay.SizingPercent(0.5), clay.SizingPercent(1)},
					padding = clay.PaddingAll(5),
				},
				backgroundColor = SURFACE_1,
				cornerRadius = clay.CornerRadiusAll(5),
			},
			{color = MAUVE, width = {2, 2, 2, 2, 2}},
			{textColor = TEXT, fontSize = 16},
			row_selected,
		)

		active := UI_widget_active(&ctx.ui_ctx, tb_id)
		if .SUBMIT in tb_res {
			delete(entry^)
			if ctx.active_line_len == 0 {
				ordered_remove(&ctx.aux_rules, idx - 1)
			} else {
				entry^ = strings.clone(string(ctx.active_line_buf[:ctx.active_line_len]))
			}
			ctx.statuses += {.RULES}
			ctx.active_line = 0
			row_selected = false
		}

		UI_spacer(&ctx.ui_ctx)

		if row_selected {
			if clay.UI()({layout = {childGap = 5}}) {
				delete_res, _ := UI_text_button(
					&ctx.ui_ctx,
					"Delete",
					{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
					clay.CornerRadiusAll(5),
					RED,
					RED * {0.9, 0.9, 0.9, 1},
					RED * {0.8, 0.8, 0.8, 1},
					CRUST,
					16,
					5,
				)

				cancel_res, _ := UI_text_button(
					&ctx.ui_ctx,
					"Cancel",
					{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
					clay.CornerRadiusAll(5),
					SURFACE_2,
					SURFACE_1,
					SURFACE_0,
					TEXT,
					16,
					5,
				)

				apply_res, _ := UI_text_button(
					&ctx.ui_ctx,
					"Apply",
					{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
					clay.CornerRadiusAll(5),
					MAUVE,
					MAUVE * {0.9, 0.9, 0.9, 1},
					MAUVE * {0.8, 0.8, 0.8, 1},
					CRUST,
					16,
					5,
				)

				if .RELEASE in delete_res {
					delete(entry^)
					ordered_remove(&ctx.aux_rules, idx - 1)
					ctx.statuses += {.RULES}
				}
				if .RELEASE in cancel_res {
					ctx.active_line = 0
					UI_unfocus(&ctx.ui_ctx, tb_id)
				}
				if .RELEASE in apply_res {
					delete(entry^)
					if ctx.active_line_len == 0 {
						ordered_remove(&ctx.aux_rules, idx - 1)
					} else {
						entry^ = strings.clone(string(ctx.active_line_buf[:ctx.active_line_len]))
					}
					ctx.statuses += {.RULES}
					ctx.active_line = 0
				}
			}
		} else {
			button_res, _ := UI_text_button(
				&ctx.ui_ctx,
				"Edit",
				{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
				clay.CornerRadiusAll(5),
				SURFACE_2,
				SURFACE_1,
				SURFACE_0,
				TEXT,
				16,
				5,
			)

			if .RELEASE in button_res {
				if active {
					delete(entry^)
					entry^ = strings.clone(string(ctx.active_line_buf[:ctx.active_line_len]))
					ctx.statuses += {.RULES}
					ctx.active_line = 0
				} else {
					UI_widget_focus(&ctx.ui_ctx, tb_id)
					UI_status_add(&ctx.ui_ctx, {.TEXTBOX_SELECTED})
					UI_textbox_reset(&ctx.ui_ctx, len(entry))
					copy(ctx.active_line_buf[:], entry^)
					ctx.active_line_len = len(entry)
					ctx.active_line = idx
				}
			}
		}
	}

	if idx <= rule_count - 1 do list_separator()
}

list_separator :: proc() {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFit({})},
			padding = {left = 6, right = 6},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(1)}},
			backgroundColor = SURFACE_0,
		},
		) {
		}
	}
}

rule_add_modal :: proc(ctx: ^Context) {
	if .ADDING in ctx.statuses {
		res, _ := UI_modal_escapable(&ctx.ui_ctx, CRUST * {1, 1, 1, 0.75}, rule_add, ctx)
		if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.ADDING}
	}
}

rule_add :: proc(ui_ctx: ^UI_Context, ctx: rawptr) -> (res: UI_WidgetResults, id: clay.ElementId) {
	ctx := cast(^Context)ctx

	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingFit({}), clay.SizingFit({})},
			childAlignment = {y = .Center},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(16),
			childGap = 16,
		},
		backgroundColor = BASE,
		cornerRadius = clay.CornerRadiusAll(10),
	},
	) {
		if !clay.Hovered() && .LEFT in ctx.ui_ctx.mouse_pressed do res += {.CANCEL}
		UI_textlabel("Add Rule", {textColor = TEXT, fontSize = 20})

		placeholder_str := "New rule..."
		tb_res, tb_id := UI_textbox(
			&ctx.ui_ctx,
			ctx.new_rule_buf[:],
			&ctx.new_rule_len,
			placeholder_str,
			{
				layout = {
					sizing = {clay.SizingFixed(240), clay.SizingFixed(32)},
					padding = clay.PaddingAll(5),
				},
				backgroundColor = SURFACE_1,
				cornerRadius = clay.CornerRadiusAll(5),
			},
			{color = MAUVE, width = {2, 2, 2, 2, 2}},
			{textColor = TEXT, fontSize = 16},
		)

		UI_widget_focus(ui_ctx, tb_id)
		if .ADDING_NEW in ctx.statuses {
			tb_res += {.FOCUS}
			ctx.statuses -= {.ADDING_NEW}
		}

		if .FOCUS in tb_res {
			ctx.new_rule_len = 0
		}

		if .SUBMIT in tb_res {
			if ctx.new_rule_len > 0 {
				append(&ctx.aux_rules, strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len])))
				ctx.new_rule_len = 0
				ctx.statuses += {.RULES}
				res += {.SUBMIT}
			}
		}

		if clay.UI()(
		{
			layout = {
				childAlignment = {x = .Center},
				sizing = {clay.SizingGrow({}), clay.SizingFit({})},
			},
		},
		) {
			button_res, _ := UI_text_button(
				&ctx.ui_ctx,
				"Add Rule",
				{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
				clay.CornerRadiusAll(32),
				SURFACE_2,
				SURFACE_1,
				SURFACE_0,
				TEXT,
				16,
				12,
				ctx.new_rule_len > 0,
			)

			if .RELEASE in button_res {
				if ctx.new_rule_len > 0 {
					append(
						&ctx.aux_rules,
						strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len])),
					)
					ctx.new_rule_len = 0
					ctx.statuses += {.RULES}
					res += {.SUBMIT}
				}
			}
		}
	}

	return
}
