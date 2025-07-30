package mixologist

import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "ui"
import "ui/clay"

GUI_Context_Status :: enum u8 {
	ADDING_NEW,
	ADDING,
	SETTINGS,
	RULES,
	VOLUME,
	DEBUGGING,
}
GUI_Context_Statuses :: bit_set[GUI_Context_Status]

gui: GUI_Context

GUI_Context :: struct {
	ui_ctx:            ui.Context,
	events:            chan.Chan(Event),
	// rule modification
	active_line_buf:   [1024]u8,
	active_line_len:   int,
	active_line:       int,
	// rule addition
	programs:          [dynamic]string,
	selected_programs: [dynamic]string,
	// custom rule creation
	new_rule_buf:      [1024]u8,
	new_rule_len:      int,
	rule_scrollbar:    ui.Scrollbar_Data,
	program_scrollbar: ui.Scrollbar_Data,
	// config state
	statuses:          GUI_Context_Statuses,
}

gui_init :: proc(ctx: ^GUI_Context, minimized: bool) {
	ctx.events, _ = chan.create(chan.Chan(Event), 128, context.allocator)
	ui.init(&ctx.ui_ctx, minimized)
	ui.set_tray_icon(&ctx.ui_ctx, #load("../data/mixologist.svg"))
	ui.load_font_mem(&ctx.ui_ctx, #load("resources/fonts/Roboto-Regular.ttf"), 16)
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/gamepad2-symbolic.svg"), {64, 64}) // GAME = 0
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/music-note-symbolic.svg"), {64, 64}) // MUSIC = 1
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/edit-symbolic.svg"), {64, 64}) // EDIT = 2
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/cancel-symbolic.svg"), {64, 64}) // CANCEL = 3
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/trash-symbolic.svg"), {64, 64}) // DELETE = 4
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/check-plain-symbolic.svg"), {64, 64}) // APPLY = 5
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/plus-symbolic.svg"), {64, 64}) // PLUS = 6
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/settings-symbolic.svg"), {64, 64}) // SETTINGS = 7
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/dropdown-symbolic.svg"), {64, 64}) // DROPDOWN = 8
	ui.load_image_mem(&ctx.ui_ctx, #load("resources/images/close-symbolic.svg"), {64, 64}) // CLOSE = 9
}

gui_tick :: proc(ctx: ^GUI_Context) {
	ui.tick(&ctx.ui_ctx, gui_create_layout, ctx)
	gui_event_process(ctx)

	if !ui.window_closed(&ctx.ui_ctx) {
		if .VOLUME in ctx.statuses {
			ctx.statuses -= {.VOLUME}
		}
		if .RULES in ctx.statuses {
			ctx.statuses -= {.RULES}
			ctx.active_line = 0
			ui.unfocus_all(&ctx.ui_ctx)
		}
	}
}

gui_deinit :: proc(ctx: ^GUI_Context) {
	gui_event_process(ctx)
	ui.deinit(&ctx.ui_ctx)
	for program in ctx.selected_programs {
		delete(program)
	}
	delete(ctx.selected_programs)
	for program in ctx.programs {
		delete(program)
	}
	delete(ctx.programs)
	chan.destroy(ctx.events)
}

gui_event_send :: proc(event: Event, allocator := context.allocator) {
	if .Gui not_in mixologist.features do return

	log.debugf("gui sending event: %v", event)
	if !chan.send(gui.events, event) {
		#partial switch event in event {
		case Program_Add:
			delete(string(event), allocator)
		case Program_Remove:
			delete(string(event), allocator)
		}
	}
}

gui_event_process :: proc(ctx: ^GUI_Context) {
	for event in chan.try_recv(ctx.events) {
		ctx.ui_ctx.statuses += {.DIRTY}
		#partial switch event in event {
		case Program_Add:
			log.infof("gui adding program %s", event)
			append(&ctx.programs, string(event))
		case Program_Remove:
			log.infof("gui removing program %s", event)
			node_idx, found := slice.linear_search(ctx.programs[:], string(event))
			if found {
				delete(ctx.programs[node_idx])
				unordered_remove(&ctx.programs, node_idx)
			}
			delete(string(event))
		case Open:
			ui.open_window(&ctx.ui_ctx)
		}
	}
}

gui_create_layout :: proc(
	ctx: ^ui.Context,
	userdata: rawptr,
) -> clay.ClayArray(clay.RenderCommand) {
	mgst_ctx := cast(^GUI_Context)userdata
	layout := create_layout(mgst_ctx)
	mixologist_event_process(&mixologist)
	return layout
}

create_layout :: proc(ctx: ^GUI_Context) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI()(
	{id = clay.ID("root"), layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}},
	) {
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
				if clay.UI()(
				{
					id = clay.ID("rules"),
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
								for rule, i in mixologist.config.rules do rule_line(ctx, rule, i + 1, len(mixologist.config.rules))
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

	return clay.EndLayout()
}

volume_slider :: proc(ctx: ^GUI_Context) {
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
			{ui.IconConfig{id = 7, size = 32, color = TEXT}},
			{sizing = {clay.SizingFixed(48), clay.SizingFixed(48)}},
			clay.CornerRadiusAll(0),
			OVERLAY_0,
			SURFACE_2,
			SURFACE_1,
			0,
		)

		if .RELEASE in res {
			ctx.statuses += {.SETTINGS}
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
			ui.icon(&ctx.ui_ctx, 0, {32, 32}, TEXT)

			vol := mixologist.volume
			slider_res, _ := ui.slider(
				&ctx.ui_ctx,
				&vol,
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
				mixologist_event_send(vol)
				ctx.statuses += {.VOLUME}
			}

			ui.icon(&ctx.ui_ctx, 1, {32, 32}, TEXT)
		}
	}
}

scrollbar :: proc(ctx: ^GUI_Context) {
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

rules_label :: proc(ctx: ^GUI_Context) {
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
				ui.IconConfig{id = 6, size = 16, color = TEXT},
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
			ctx.statuses += {.ADDING, .ADDING_NEW}
		}
	}
}

rule_line :: proc(ctx: ^GUI_Context, rule: string, idx, rule_count: int) {
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
			mixologist_event_send(
				Rule_Update {
					rule,
					strings.clone(string(ctx.active_line_buf[:ctx.active_line_len])),
				},
			)
			ctx.statuses += {.RULES}
			ctx.active_line = 0
			row_selected = false
		}

		ui.spacer(&ctx.ui_ctx)

		if row_selected {
			if clay.UI()({layout = {childGap = 5}}) {
				if clay.UI()({}) {
					delete_res, _ := ui.button(
						&ctx.ui_ctx,
						{ui.IconConfig{id = 4, size = 16, color = CRUST}},
						{sizing = {clay.SizingFit(), clay.SizingFit()}},
						clay.CornerRadiusAll(5),
						RED,
						RED * {0.9, 0.9, 0.9, 1},
						RED * {0.8, 0.8, 0.8, 1},
						5,
					)
					if .RELEASE in delete_res {
						mixologist_event_send(Rule_Remove(rule))
						ctx.statuses += {.RULES}
					}
				}

				if clay.UI()({}) {
					cancel_res, _ := ui.button(
						&ctx.ui_ctx,
						{ui.IconConfig{id = 3, size = 16, color = TEXT}},
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
						{ui.IconConfig{id = 5, size = 16, color = CRUST}},
						{sizing = {clay.SizingFit(), clay.SizingFit()}},
						clay.CornerRadiusAll(5),
						MAUVE,
						MAUVE * {0.9, 0.9, 0.9, 1},
						MAUVE * {0.8, 0.8, 0.8, 1},
						5,
					)

					if .RELEASE in apply_res {
						mixologist_event_send(
							Rule_Update {
								rule,
								strings.clone(string(ctx.active_line_buf[:ctx.active_line_len])),
							},
						)
						ctx.statuses += {.RULES}
						ctx.active_line = 0
					}
				}
			}
		} else {
			button_res, _ := ui.button(
				&ctx.ui_ctx,
				{ui.IconConfig{id = 2, size = 16, color = TEXT}},
				{sizing = {clay.SizingFit(), clay.SizingFit()}},
				clay.CornerRadiusAll(5),
				SURFACE_2,
				SURFACE_1,
				SURFACE_0,
				5,
			)

			if .RELEASE in button_res {
				ui.widget_focus(&ctx.ui_ctx, tb_id)
				ui.status_add(&ctx.ui_ctx, {.TEXTBOX_SELECTED})
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

rule_add_modal :: proc(ctx: ^GUI_Context) {
	if .ADDING in ctx.statuses {
		if ui.modal()({CRUST * {1, 1, 1, 0.75}, .Root, nil}) {
			res, _ := rule_add_menu(ctx)
			if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.ADDING}
		}
	}
}

settings_modal :: proc(ctx: ^GUI_Context) {
	if .SETTINGS in ctx.statuses {
		if ui.modal()({CRUST * {1, 1, 1, 0.75}, .Root, nil}) {
			res, _ := settings_menu(ctx)
			if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.SETTINGS}
		}
	}
}

rule_add_menu :: proc(ctx: ^GUI_Context) -> (res: ui.WidgetResults, id: clay.ElementId) {
	ctx := cast(^GUI_Context)ctx
	if .ADDING_NEW in ctx.statuses {
		ctx.statuses -= {.ADDING_NEW}
		ctx.new_rule_len = 0
		for program in ctx.selected_programs {
			delete(program)
		}
		clear(&ctx.selected_programs)
	}

	if clay.UI()(
	{
		layout = {
			padding = clay.PaddingAll(16),
			sizing = {clay.SizingPercent(0.7), clay.SizingFit()},
		},
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
					{ui.IconConfig{9, 20, TEXT}},
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
			for program in ctx.programs {
				if slice.contains(mixologist.config.rules[:], program) {
					found_count += 1
				}
			}

			if len(ctx.programs) > 0 && found_count != len(ctx.programs) {
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
					if clay.UI()(
					{
						id = clay.ID("open_programs"),
						layout = {
							layoutDirection = .TopToBottom,
							sizing = {clay.SizingGrow(), clay.SizingFit()},
						},
						clip = {vertical = true, childOffset = clay.GetScrollOffset()},
					},
					) {
						for program, idx in ctx.programs {
							if slice.contains(mixologist.config.rules[:], program) {
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
								add_program_res, _ := ui.button(
									&ctx.ui_ctx,
									selected ? {ui.IconConfig{5, 16, TEXT}} : {},
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

								if .RELEASE in add_program_res {
									if selected {
										delete(ctx.selected_programs[selection_idx])
										unordered_remove(&ctx.selected_programs, selection_idx)
									} else {
										append(&ctx.selected_programs, strings.clone(program))
									}
								}
							}
							if idx < len(ctx.programs) - 1 - found_count {
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
						mixologist_event_send(
							Rule_Add(strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len]))),
						)
						ctx.new_rule_len = 0
						ctx.statuses += {.RULES}
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
						mixologist_event_send(
							Rule_Add(strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len]))),
						)
						ctx.new_rule_len = 0
						ctx.statuses += {.RULES}
						res += {.SUBMIT}
					}
					if len(ctx.selected_programs) > 0 {
						for program in ctx.selected_programs {
							mixologist_event_send(Rule_Add(strings.clone(string(program))))
						}
						ctx.statuses += {.RULES}
						res += {.SUBMIT}
					}
				}
			}
		}
	}

	return
}

settings_menu :: proc(ctx: ^GUI_Context) -> (res: ui.WidgetResults, id: clay.ElementId) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingPercent(0.8), clay.SizingFit()},
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
				{ui.IconConfig{9, 20, TEXT}},
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
			settings := mixologist.config.settings
			res, _ := switch_row(
				ctx,
				{text = "Minimize on Start", color = TEXT, size = 16},
				&settings.start_minimized,
			)
			if .RELEASE in res {
				mixologist_event_send(settings)
			}

			list_separator(SURFACE_1)

			remember_res, _ := switch_row(
				ctx,
				{text = "Remember Volume", color = TEXT, size = 16},
				&settings.remember_volume,
			)
			if .RELEASE in remember_res {
				mixologist_event_send(settings)
			}

			list_separator(SURFACE_1)

			volume_mode := transmute(^int)&settings.volume_falloff
			dropdown_res, _ := dropdown_row(
				ctx,
				{text = "Volume Falloff Curve", color = TEXT, size = 16},
				{"Linear", "Quadratic", "Power", "Cubic"},
				volume_mode,
			)

			if .CHANGE in dropdown_res {
				mixologist_event_send(settings)
				mixologist_event_send(mixologist.volume)
			}
		}
	}
	return
}

switch_row :: proc(
	ctx: ^GUI_Context,
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
	ctx: ^GUI_Context,
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

		res, _ = ui.dropdown(&ctx.ui_ctx, options, selected, TEXT, SURFACE_0, 16, 8, 5)
	}
	return
}
