package mixologist

import "base:runtime"
import "core:os"
import "core:prof/spall"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "shared:ui"
import "shared:ui/clay"
import sdl "vendor:sdl3"

GUI_Context_Status :: enum u8 {
	AddingNew,
	Adding,
	Settings,
	Rules,
	Volume,
	Debugging,
}
GUI_Context_Statuses :: bit_set[GUI_Context_Status]

gui: GUIContext
GUIContext :: struct {
	state:             State,
	ui_ctx:            ui.Context,
	// rule modification
	active_line_buf:   [1024]u8,
	active_line_len:   int,
	active_line:       int,
	volume:            f32,
	// rule addition
	selected_programs: [dynamic]string,
	// custom rule creation
	new_rule_buf:      [1024]u8,
	new_rule_len:      int,
	rule_scrollbar:    ui.Scrollbar_Data,
	program_scrollbar: ui.Scrollbar_Data,
	// config state
	statuses:          GUI_Context_Statuses,
	// atomic
	finished_setup:    bool,
}

gui_proc :: proc() {
	when PROFILING {
		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing, u32(os.get_current_thread_id()))
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

		spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
	}

	gui_init_internal(&gui, gui.state.settings.start_minimized)
	for !ui.should_exit(&gui.ui_ctx) {
		gui_ui_tick(&gui)
		free_all(context.temp_allocator)
	}
	gui_demand_daemon_exit()
	gui_fini_internal(&gui)
}

Icons :: enum {
	Game,
	Music,
	Edit,
	Cancel,
	Delete,
	Apply,
	Plus,
	Settings,
	Dropdown,
	Close,
}
icons: [Icons]int

gui_init :: proc() {
	state_populate(&gui.state)
}

gui_init_internal :: proc(ctx: ^GUIContext, minimized: bool) {
	ui.init(&ctx.ui_ctx, "Mixologist", minimized)
	ui.load_font_mem(&ctx.ui_ctx, #load("resources/fonts/Roboto-Regular.ttf"), 16)
	shared_state.gui_pump_event = cast(sdl.EventType)sdl.RegisterEvents(1)
	// odinfmt:disable
	icons[.Game]     = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/gamepad2-symbolic.svg"), {64, 64})
	icons[.Music]    = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/music-note-symbolic.svg"), {64, 64})
	icons[.Edit]     = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/edit-symbolic.svg"), {64, 64})
	icons[.Cancel]   = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/cancel-symbolic.svg"), {64, 64})
	icons[.Delete]   = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/trash-symbolic.svg"), {64, 64})
	icons[.Apply]    = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/check-plain-symbolic.svg"), {64, 64})
	icons[.Plus]     = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/plus-symbolic.svg"), {64, 64})
	icons[.Settings] = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/settings-symbolic.svg"), {64, 64})
	icons[.Dropdown] = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/dropdown-symbolic.svg"), {64, 64})
	icons[.Close]    = ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/close-symbolic.svg"), {64, 64})
	// odinfmt:enable
	sync.atomic_store_explicit(&ctx.finished_setup, true, .Relaxed)
}

gui_ui_tick :: proc(ctx: ^GUIContext) {
	ui.tick(&ctx.ui_ctx, gui_create_layout, gui_process_messages, ctx)
	if !ui.window_closed(&ctx.ui_ctx) {
		if .Volume in ctx.statuses {
			ctx.statuses -= {.Volume}
		}
		if .Rules in ctx.statuses {
			ctx.statuses -= {.Rules}
			ctx.active_line = 0
			ui.unfocus_all(&ctx.ui_ctx)
		}
	}
}

gui_fini_internal :: proc(ctx: ^GUIContext) {
	ui.fini(&ctx.ui_ctx)
	state_destroy(ctx.state)
	str_arr_delete(ctx.selected_programs)
}

gui_process_messages :: proc(ctx: rawptr) {
	ctx := cast(^GUIContext)ctx
	for msg in chan.try_recv(shared_state.daemon_chan) {
		switch msg in msg {
		case Wake:
			ui.open_window(&ctx.ui_ctx)
		case Toggle:
			ui.toggle_window(&ctx.ui_ctx)
		case Rule:
			list_string_modify(&ctx.state.rules, msg, true)
		case Program:
			list_string_modify(&ctx.state.programs, msg, true)
		case Volume:
			modify_volume(&ctx.volume, msg)
		case Settings:
			ctx.state.settings = msg
		}
	}
}

gui_create_layout :: proc(
	ctx: ^ui.Context,
	delta_time: f32,
	userdata: rawptr,
) -> clay.ClayArray(clay.RenderCommand) {
	gui_ctx := cast(^GUIContext)userdata
	layout := create_layout(gui_ctx, delta_time)
	return layout
}

create_layout :: proc(ctx: ^GUIContext, delta_time: f32) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()
	if clay.UI(clay.ID("root"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
		if clay.UI()(
		{
			layout = {
				layoutDirection = .TopToBottom,
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = BASE,
		},
		) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
				if clay.UI(clay.ID("rules"))(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingFit()},
						padding = clay.PaddingAll(16),
						childAlignment = {x = .Center},
					},
					clip = {vertical = true, childOffset = clay.GetScrollOffset()},
				},
				) {
					if clay.UI()(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {clay.SizingPercent(0.8), clay.SizingGrow()},
						},
						backgroundColor = MANTLE,
						cornerRadius = clay.CornerRadiusAll(10),
					},
					) {
						if clay.UI()(
						{
							layout = {
								sizing = {clay.SizingPercent(1), clay.SizingFit()},
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
									sizing = {clay.SizingPercent(1), clay.SizingFit()},
									layoutDirection = .TopToBottom,
								},
								backgroundColor = CRUST,
								cornerRadius = clay.CornerRadiusAll(10),
							},
							) {
								for rule, i in ctx.state.rules do rule_line(ctx, rule, i + 1, len(ctx.state.rules))
							}
						}
					}
				}
				scrollbar(ctx)
			}

			volume_slider(ctx)
		}
	}
	rule_add_modal(ctx)
	settings_modal(ctx)
	when ODIN_DEBUG {
		ui.memory_debug(&ctx.ui_ctx, track)
	}

	return clay.EndLayout(delta_time)
}

volume_slider :: proc(ctx: ^GUIContext) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(48)},
			childAlignment = {.Center, .Center},
			layoutDirection = .LeftToRight,
		},
		backgroundColor = SURFACE_0,
	},
	) {
		res, _ := ui.button(
			&ctx.ui_ctx,
			{ui.IconConfig{id = icons[.Settings], size = 32, color = TEXT}},
			{sizing = {clay.SizingFixed(48), clay.SizingFixed(48)}},
			clay.CornerRadiusAll(0),
			OVERLAY_0,
			SURFACE_2,
			SURFACE_1,
			0,
		)

		if .RELEASE in res {
			ctx.statuses += {.Settings}
		}

		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(48)},
				padding = clay.PaddingAll(16),
				childGap = 12,
				childAlignment = {.Center, .Center},
				layoutDirection = .LeftToRight,
			},
			backgroundColor = SURFACE_0,
		},
		) {
			ui.icon(&ctx.ui_ctx, icons[.Game], {32, 32}, TEXT)

			slider_res, _ := ui.slider(
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
				{sizing = {clay.SizingGrow(), clay.SizingFixed(16)}},
				0.025,
				0,
			)

			if .CHANGE in slider_res {
				gui_update_daemon_volume(ctx.volume)
				ctx.statuses += {.Volume}
			}

			ui.icon(&ctx.ui_ctx, icons[.Music], {32, 32}, TEXT)
		}
	}
}

scrollbar :: proc(ctx: ^GUIContext) {
	if clay.UI()(
	{layout = {sizing = {clay.SizingFit(), clay.SizingGrow()}, padding = {right = 4}}},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingFit(), clay.SizingGrow()},
				childAlignment = {.Right, .Top},
			},
		},
		) {
			ui.scrollbar(
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

rules_label :: proc(ctx: ^GUIContext) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingFit(), clay.SizingGrow()},
				childGap = 8,
				layoutDirection = .TopToBottom,
			},
		},
		) {
			ui.textlabel("Rules", {textColor = TEXT, fontSize = 20})
			ui.textlabel("Selected Programs", {textColor = TEXT * 0.8, fontSize = 16})
		}
		ui.spacer(&ctx.ui_ctx)

		res, _ := ui.button(
			&ctx.ui_ctx,
			{
				ui.IconConfig{id = icons[.Plus], size = 16, color = TEXT},
				ui.HorzSpacerConfig{size = 4},
				ui.TextConfig{text = "Add Rule", size = 16, color = TEXT},
			},
			{sizing = {clay.SizingFit(), clay.SizingFit()}},
			clay.CornerRadiusAll(5),
			SURFACE_2,
			SURFACE_1,
			SURFACE_0,
			5,
		)

		if .RELEASE in res {
			ctx.statuses += {.Adding, .AddingNew}
		}
	}
}

rule_line :: proc(ctx: ^GUIContext, rule: string, idx, rule_count: int) {
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

		tb_res, tb_id := ui.textbox(
			&ctx.ui_ctx,
			ctx.active_line_buf[:],
			&ctx.active_line_len,
			row_selected ? string(ctx.active_line_buf[:ctx.active_line_len]) : rule,
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

		if .SUBMIT in tb_res {
			gui_update_daemon_rule(
				{kind = .Update, mod = {rule, string(ctx.active_line_buf[:ctx.active_line_len])}},
			)
			ctx.statuses += {.Rules}
			ctx.active_line = 0
			row_selected = false
		}

		ui.spacer(&ctx.ui_ctx)

		if row_selected {
			if clay.UI()({layout = {childGap = 5}}) {
				if clay.UI()({}) {
					delete_res, _ := ui.button(
						&ctx.ui_ctx,
						{ui.IconConfig{id = icons[.Delete], size = 16, color = CRUST}},
						{sizing = {clay.SizingFit(), clay.SizingFit()}},
						clay.CornerRadiusAll(5),
						RED,
						RED * {0.9, 0.9, 0.9, 1},
						RED * {0.8, 0.8, 0.8, 1},
						5,
					)
					if .RELEASE in delete_res {
						gui_update_daemon_rule({kind = .Remove, val = rule})
						ctx.statuses += {.Rules}
					}
				}

				if clay.UI()({}) {
					cancel_res, _ := ui.button(
						&ctx.ui_ctx,
						{ui.IconConfig{id = icons[.Cancel], size = 16, color = TEXT}},
						{sizing = {clay.SizingFit(), clay.SizingFit()}},
						clay.CornerRadiusAll(5),
						SURFACE_2,
						SURFACE_1,
						SURFACE_0,
						5,
					)

					if .RELEASE in cancel_res {
						ctx.active_line = 0
					}
				}

				if clay.UI()({}) {
					apply_res, _ := ui.button(
						&ctx.ui_ctx,
						{ui.IconConfig{id = icons[.Apply], size = 16, color = CRUST}},
						{sizing = {clay.SizingFit(), clay.SizingFit()}},
						clay.CornerRadiusAll(5),
						MAUVE,
						MAUVE * {0.9, 0.9, 0.9, 1},
						MAUVE * {0.8, 0.8, 0.8, 1},
						5,
					)

					if .RELEASE in apply_res {
						gui_update_daemon_rule(
							{
								kind = .Update,
								mod = {rule, string(ctx.active_line_buf[:ctx.active_line_len])},
							},
						)
						ctx.statuses += {.Rules}
						ctx.active_line = 0
					}
				}
			}
		} else {
			button_res, _ := ui.button(
				&ctx.ui_ctx,
				{ui.IconConfig{id = icons[.Edit], size = 16, color = TEXT}},
				{sizing = {clay.SizingFit(), clay.SizingFit()}},
				clay.CornerRadiusAll(5),
				SURFACE_2,
				SURFACE_1,
				SURFACE_0,
				5,
			)

			if .RELEASE in button_res {
				ui.widget_focus(&ctx.ui_ctx, tb_id, {.TEXTBOX_JUST_SELECTED})
				ui.textbox_reset(&ctx.ui_ctx, len(rule))
				copy(ctx.active_line_buf[:], rule)
				ctx.active_line_len = len(rule)
				ctx.active_line = idx
			}
		}
	}

	if idx <= rule_count - 1 do list_separator()
}

list_separator :: proc(color: clay.Color = SURFACE_0) {
	if clay.UI()(
	{layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {left = 6, right = 6}}},
	) {
		if clay.UI()(
		{layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(1)}}, backgroundColor = color},
		) {
		}
	}
}

rule_add_modal :: proc(ctx: ^GUIContext) {
	if .Adding in ctx.statuses {
		if ui.modal(clay.ID(#procedure))({CRUST * {1, 1, 1, 0.75}, .Root}) {
			res, _ := rule_add_menu(ctx)
			if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.Adding}
		}
	}
}

settings_modal :: proc(ctx: ^GUIContext) {
	if .Settings in ctx.statuses {
		if ui.modal(clay.ID(#procedure))({CRUST * {1, 1, 1, 0.75}, .Root}) {
			res, _ := settings_menu(ctx)
			if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.Settings}
		}
	}
}

rule_add_menu :: proc(ctx: ^GUIContext) -> (res: ui.WidgetResults, id: clay.ElementId) {
	ctx := cast(^GUIContext)ctx
	if .AddingNew in ctx.statuses {
		ctx.statuses -= {.AddingNew}
		ctx.new_rule_len = 0
		for program in ctx.selected_programs {
			delete(program)
		}
		clear(&ctx.selected_programs)
	}

	if clay.UI()(
	{
		layout = {sizing = {clay.SizingPercent(0.7), clay.SizingFit()}},
		backgroundColor = {10, 10, 10, 255},
		cornerRadius = clay.CornerRadiusAll(10),
		userData = transmute(rawptr)ui.Data_Flags{.SHADOW},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFit()},
				childAlignment = {y = .Center},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(16),
				childGap = 16,
			},
			backgroundColor = BASE,
			cornerRadius = clay.CornerRadiusAll(10),
		},
		) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
				ui.textlabel("Add Rule", {textColor = TEXT, fontSize = 20})
				ui.spacer(&ctx.ui_ctx, {min = 24})
				close_res, _ := ui.button(
					&ctx.ui_ctx,
					{ui.IconConfig{icons[.Close], 20, TEXT}},
					{},
					clay.CornerRadiusAll(max(f32)),
					SURFACE_2,
					SURFACE_1,
					SURFACE_0,
					2,
				)

				if .RELEASE in close_res {
					res += {.CANCEL}
				}
			}

			found_count := 0
			for program in ctx.state.programs {
				// todo this should be if it matches
				if slice.contains(ctx.state.rules[:], program) {
					found_count += 1
				}
			}

			// todo maybe refactor
			if len(ctx.state.programs) > 0 && found_count != len(ctx.state.programs) {
				ui.textlabel("Open Programs", {textColor = TEXT, fontSize = 16})
				if clay.UI()(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingFit()},
						layoutDirection = .LeftToRight,
						padding = clay.PaddingAll(8),
					},
					backgroundColor = SURFACE_0,
					cornerRadius = clay.CornerRadiusAll(10),
				},
				) {
					if clay.UI(clay.ID("open_programs"))(
					{
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {clay.SizingGrow(), clay.SizingFit()},
						},
						clip = {vertical = true, childOffset = clay.GetScrollOffset()},
					},
					) {
						for program, idx in ctx.state.programs {
							// todo this should be if it matches
							if slice.contains(ctx.state.rules[:], program) {
								continue
							}

							selection_idx, selected := slice.linear_search(
								ctx.selected_programs[:],
								program,
							)

							if clay.UI()(
							{
								layout = {
									sizing = {clay.SizingGrow(), clay.SizingFit()},
									padding = clay.PaddingAll(8),
									childAlignment = {x = .Left, y = .Center},
								},
							},
							) {
								select_program_res, _ := ui.button(
									&ctx.ui_ctx,
									selected ? {ui.IconConfig{icons[.Apply], 16, TEXT}} : {},
									{sizing = {clay.SizingFixed(24), clay.SizingFixed(24)}},
									clay.CornerRadiusAll(8),
									selected ? MAUVE * {1, 1, 1, 0.5} : SURFACE_0,
									selected ? MAUVE * {1, 1, 1, 0.6} : SURFACE_2,
									selected ? MAUVE * {1, 1, 1, 0.7} : SURFACE_1,
									2,
									border_config = {
										width = {2, 2, 2, 2, 2},
										color = selected ? MAUVE : SURFACE_2,
									},
								)
								ui.horz_spacer(&ctx.ui_ctx, 24)
								ui.textlabel(program, {textColor = TEXT, fontSize = 16})

								if .RELEASE in select_program_res {
									if selected {
										delete(ctx.selected_programs[selection_idx])
										unordered_remove(&ctx.selected_programs, selection_idx)
									} else {
										append(&ctx.selected_programs, strings.clone(program))
									}
								}
							}
							if idx < len(ctx.state.programs) - 1 - found_count {
								list_separator(SURFACE_1)
							}
						}
					}

					ui.horz_spacer(&ctx.ui_ctx, 8)

					if clay.UI()({layout = {sizing = {clay.SizingFit(), clay.SizingGrow()}}}) {
						ui.scrollbar(
							&ctx.ui_ctx,
							clay.GetScrollContainerData(clay.ID("open_programs")),
							&ctx.program_scrollbar,
							8,
							0,
							SURFACE_2,
							OVERLAY_0,
							OVERLAY_1,
						)
					}
				}
			}

			ui.textlabel("Custom Rule", {textColor = TEXT, fontSize = 16})
			if clay.UI()(
			{
				layout = {
					childAlignment = {x = .Center},
					sizing = {clay.SizingGrow(), clay.SizingFit()},
				},
			},
			) {
				placeholder_str := "New rule..."
				tb_res, _ := ui.textbox(
					&ctx.ui_ctx,
					ctx.new_rule_buf[:],
					&ctx.new_rule_len,
					ctx.new_rule_len == 0 ? placeholder_str : string(ctx.new_rule_buf[:ctx.new_rule_len]),
					{
						layout = {
							sizing = {clay.SizingGrow(), clay.SizingFixed(32)},
							padding = clay.PaddingAll(5),
						},
						backgroundColor = SURFACE_1,
						cornerRadius = clay.CornerRadiusAll(5),
					},
					{color = MAUVE, width = {2, 2, 2, 2, 2}},
					{textColor = TEXT, fontSize = 16},
				)

				if .SUBMIT in tb_res {
					if ctx.new_rule_len > 0 {
						gui_update_daemon_rule(
							{kind = .Add, val = string(ctx.new_rule_buf[:ctx.new_rule_len])},
						)
						ctx.new_rule_len = 0
						ctx.statuses += {.Rules}
						res += {.SUBMIT}
					}
				}
			}

			if clay.UI()(
			{
				layout = {
					childAlignment = {x = .Center},
					sizing = {clay.SizingGrow(), clay.SizingFit()},
				},
			},
			) {
				rules_to_add := len(ctx.selected_programs) + int(ctx.new_rule_len > 0)
				button_res, _ := ui.button(
					&ctx.ui_ctx,
					{
						ui.TextConfig {
							text = rules_to_add > 1 ? "Add Rules" : "Add Rule",
							size = 16,
							color = TEXT,
						},
					},
					{sizing = {clay.SizingFit(), clay.SizingFit()}},
					clay.CornerRadiusAll(32),
					SURFACE_2,
					SURFACE_1,
					SURFACE_0,
					12,
					rules_to_add > 0,
				)

				if .RELEASE in button_res {
					if ctx.new_rule_len > 0 {
						gui_update_daemon_rule(
							{kind = .Add, val = string(ctx.new_rule_buf[:ctx.new_rule_len])},
						)
						ctx.new_rule_len = 0
						ctx.statuses += {.Rules}
						res += {.SUBMIT}
					}
					if len(ctx.selected_programs) > 0 {
						for program in ctx.selected_programs {
							gui_update_daemon_rule({kind = .Add, val = program})
						}
						ctx.statuses += {.Rules}
						res += {.SUBMIT}
					}
				}
			}
		}
	}

	return
}

settings_menu :: proc(ctx: ^GUIContext) -> (res: ui.WidgetResults, id: clay.ElementId) {
	if clay.UI()(
	{
		layout = {sizing = {clay.SizingPercent(0.8), clay.SizingFit()}},
		backgroundColor = {10, 10, 10, 255},
		cornerRadius = clay.CornerRadiusAll(10),
		userData = transmute(rawptr)ui.Data_Flags{.SHADOW},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFit()},
				childAlignment = {x = .Left, y = .Center},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(16),
				childGap = 16,
			},
			backgroundColor = BASE,
			cornerRadius = clay.CornerRadiusAll(10),
		},
		) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
				ui.textlabel("Settings", {textColor = TEXT, fontSize = 20})
				ui.spacer(&ctx.ui_ctx)
				close_res, _ := ui.button(
					&ctx.ui_ctx,
					{ui.IconConfig{icons[.Close], 20, TEXT}},
					{},
					clay.CornerRadiusAll(max(f32)),
					SURFACE_2,
					SURFACE_1,
					SURFACE_0,
					2,
				)

				if .RELEASE in close_res {
					res += {.CANCEL}
				}
			}

			settings_change := false
			if clay.UI()(
			{
				layout = {
					sizing = {clay.SizingPercent(1), clay.SizingFit()},
					layoutDirection = .TopToBottom,
				},
				backgroundColor = SURFACE_0,
				cornerRadius = clay.CornerRadiusAll(10),
			},
			) {
				res, _ := switch_row(
					ctx,
					{text = "Minimize on Start", color = TEXT, size = 16},
					&ctx.state.settings.start_minimized,
				)
				if .RELEASE in res {
					settings_change = true
				}

				list_separator(SURFACE_1)

				remember_res, _ := switch_row(
					ctx,
					{text = "Remember Volume", color = TEXT, size = 16},
					&ctx.state.settings.remember_volume,
				)
				if .RELEASE in remember_res {
					settings_change = true
				}

				list_separator(SURFACE_1)

				autostart_res, _ := switch_row(
					ctx,
					{text = "Autostart", color = TEXT, size = 16},
					&ctx.state.settings.autostart,
				)
				if .RELEASE in autostart_res {
					settings_change = true
				}

				list_separator(SURFACE_1)

				volume_mode := transmute(^int)&ctx.state.settings.volume_falloff
				dropdown_res, _ := dropdown_row(
					ctx,
					{text = "Volume Falloff Curve", color = TEXT, size = 16},
					{"Linear", "Quadratic", "Power", "Cubic"},
					volume_mode,
				)
				if .CHANGE in dropdown_res {
					settings_change = true
				}

				if settings_change {
					gui_update_daemon_settings(ctx.state.settings)
				}
			}
		}
	}
	return
}

switch_row :: proc(
	ctx: ^GUIContext,
	label: ui.TextConfig,
	state: ^bool,
) -> (
	res: ui.WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			padding = clay.PaddingAll(16),
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		ui.textlabel(label.text, {textColor = label.color, fontSize = label.size})
		ui.spacer(&ctx.ui_ctx)
		res, _ = ui.tswitch(
			&ctx.ui_ctx,
			state,
			{sizing = {clay.SizingFixed(48), clay.SizingFixed(24)}},
			TEXT,
			MANTLE,
			MAUVE * {0.8, 0.8, 0.8, 1},
		)
	}
	return
}

dropdown_row :: proc(
	ctx: ^GUIContext,
	label: ui.TextConfig,
	options: []string,
	selected: ^int,
) -> (
	res: ui.WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			padding = clay.PaddingAll(16),
			childGap = 8,
		},
	},
	) {
		ui.textlabel(label.text, {textColor = label.color, fontSize = label.size})
		ui.spacer(&ctx.ui_ctx)

		res, _ = ui.dropdown(
			&ctx.ui_ctx,
			options,
			selected,
			TEXT,
			SURFACE_0,
			16,
			icons[.Dropdown],
			5,
		)
	}
	return
}

gui_update_daemon_volume :: proc(volume: f32) {
	gui.state.volume = volume
	chan.send(shared_state.gui_chan, Volume{kind = .Set, val = volume})
	eventfd_write(shared_state.state_eventfd)
}

gui_update_daemon_rule :: proc(rule: ListString) {
	rule := rule
	switch rule.kind {
	case .Add, .Remove:
		if len(rule.val) == 0 do return
	case .Update:
		if len(rule.mod.curr) == 0 {
			rule.val = rule.mod.prev
			rule.kind = .Remove
		}
	}
	chan.send(shared_state.gui_chan, Rule(list_string_clone(rule)))
	eventfd_write(shared_state.state_eventfd)
	list_string_modify(&gui.state.rules, rule, false)
}

gui_update_daemon_settings :: proc(settings: Settings) {
	gui.state.settings = settings
	chan.send(shared_state.gui_chan, settings)
	eventfd_write(shared_state.state_eventfd)
}

gui_demand_daemon_exit :: proc() {
	eventfd_write(shared_state.quit_eventfd)
}
