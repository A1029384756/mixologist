package mixologist

import "./clay"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"

GUI_Context_Status :: enum u8 {
	ADDING_NEW,
	ADDING,
	SETTINGS,
	RULES,
	VOLUME,
	DEBUGGING,
}
GUI_Context_Statuses :: bit_set[GUI_Context_Status]

GUI_Context :: struct {
	ui_ctx:            UI_Context,
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
	rule_scrollbar:    UI_Scrollbar_Data,
	program_scrollbar: UI_Scrollbar_Data,
	// config state
	statuses:          GUI_Context_Statuses,
}

gui_proc :: proc(ctx: ^GUI_Context) {
	log.info("gui starting")
	gui_init(&mixologist.gui, mixologist.config.settings.start_minimized)
	for !(UI_should_exit(&mixologist.gui.ui_ctx) || mixologist_should_exit()) {
		gui_tick(&mixologist.gui)
		free_all(context.temp_allocator)
	}
	gui_deinit(&mixologist.gui)
	log.info("gui exiting")
	mixologist_signal_exit()
}

gui_init :: proc(ctx: ^GUI_Context, minimized: bool) {
	UI_init(&ctx.ui_ctx, minimized)
	UI_load_font_mem(&ctx.ui_ctx, 16, #load("resources/fonts/Roboto-Regular.ttf"))
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/gamepad2-symbolic.svg"), {64, 64}) // GAME = 0
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/music-note-symbolic.svg"), {64, 64}) // MUSIC = 1
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/edit-symbolic.svg"), {24, 24}) // EDIT = 2
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/cancel-symbolic.svg"), {24, 24}) // CANCEL = 3
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/trash-symbolic.svg"), {24, 24}) // DELETE = 4
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/check-plain-symbolic.svg"), {24, 24}) // APPLY = 5
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/plus-symbolic.svg"), {24, 24}) // PLUS = 6
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/settings-symbolic.svg"), {24, 24}) // SETTINGS = 7
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/dropdown-symbolic.svg"), {24, 24}) // DROPDOWN = 8
	UI_load_image_mem(&ctx.ui_ctx, #load("resources/images/close-symbolic.svg"), {24, 24}) // CLOSE = 9
}

gui_tick :: proc(ctx: ^GUI_Context) {
	UI_tick(&ctx.ui_ctx, UI_create_layout, ctx)
	gui_event_process(ctx)

	if !UI_window_closed(&ctx.ui_ctx) {
		if .VOLUME in ctx.statuses {
			ctx.statuses -= {.VOLUME}
		}
		if .RULES in ctx.statuses {
			ctx.statuses -= {.RULES}
			ctx.active_line = 0
			UI_unfocus_all(&ctx.ui_ctx)
		}
	}
}

gui_deinit :: proc(ctx: ^GUI_Context) {
	UI_deinit(&ctx.ui_ctx)
	for program in ctx.selected_programs {
		delete(program)
	}
	delete(ctx.selected_programs)
	for program in ctx.programs {
		delete(program)
	}
	delete(ctx.programs)
	chan.close(ctx.events)
	chan.destroy(ctx.events)
}

gui_event_send :: proc(event: Event, allocator := context.allocator) {
	event_clone: Event
	#partial switch event in event {
	case Program_Add:
		event_clone = Program_Add(strings.clone(string(event), allocator))
	case Program_Remove:
		event_clone = Program_Remove(strings.clone(string(event), allocator))
	}
	log.debugf("gui event sending: %v", event_clone)
	if !chan.send(mixologist.gui.events, event_clone) {
		#partial switch event_clone in event_clone {
		case Program_Add:
			delete(string(event_clone))
		case Program_Remove:
			delete(string(event_clone))
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
			UI_open_window(&ctx.ui_ctx)
		}
	}
}

UI_create_layout :: proc(
	ctx: ^UI_Context,
	userdata: rawptr,
) -> clay.ClayArray(clay.RenderCommand) {
	mgst_ctx := cast(^GUI_Context)userdata
	layout := create_layout(mgst_ctx)
	return layout
}

create_layout :: proc(ctx: ^GUI_Context) -> clay.ClayArray(clay.RenderCommand) {
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
					clip = {vertical = true, childOffset = clay.GetScrollOffset()},
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
								if sync.mutex_guard(&mixologist.config_mutex) {
									for rule, i in mixologist.config.rules do rule_line(ctx, rule, i + 1, len(mixologist.config.rules))
								}
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
		UI_memory_debug(&ctx.ui_ctx, track)
	}

	return clay.EndLayout()
}

volume_slider :: proc(ctx: ^GUI_Context) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFixed(48)},
			childAlignment = {.Center, .Center},
			layoutDirection = .LeftToRight,
		},
		backgroundColor = SURFACE_0,
	},
	) {
		res, _ := UI_button(
			&ctx.ui_ctx,
			{UI_IconConfig{id = 7, size = 32, color = TEXT}},
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
				sizing = {clay.SizingGrow({}), clay.SizingFixed(48)},
				padding = clay.PaddingAll(16),
				childGap = 12,
				childAlignment = {.Center, .Center},
				layoutDirection = .LeftToRight,
			},
			backgroundColor = SURFACE_0,
		},
		) {
			UI_icon(&ctx.ui_ctx, 0, {32, 32}, TEXT)

			vol := mixologist.volume
			slider_res, _ := UI_slider(
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
				{sizing = {clay.SizingGrow({}), clay.SizingFixed(16)}},
				0.025,
				0,
			)

			if .CHANGE in slider_res {
				mixologist_event_send(vol)
				ctx.statuses += {.VOLUME}
			}

			UI_icon(&ctx.ui_ctx, 1, {32, 32}, TEXT)
		}
	}
}

scrollbar :: proc(ctx: ^GUI_Context) {
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

rules_label :: proc(ctx: ^GUI_Context) {
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

		res, _ := UI_button(
			&ctx.ui_ctx,
			{
				UI_IconConfig{id = 6, size = 16, color = TEXT},
				UI_HorzSpacerConfig{size = 4},
				UI_TextConfig{text = "Add Rule", size = 16, color = TEXT},
			},
			{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
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

		tb_res, tb_id := UI_textbox(
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

		UI_spacer(&ctx.ui_ctx)

		if row_selected {
			if clay.UI()({layout = {childGap = 5}}) {
				if clay.UI()({}) {
					delete_res, _ := UI_button(
						&ctx.ui_ctx,
						{UI_IconConfig{id = 4, size = 16, color = CRUST}},
						{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
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
					cancel_res, _ := UI_button(
						&ctx.ui_ctx,
						{UI_IconConfig{id = 3, size = 16, color = TEXT}},
						{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
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
					apply_res, _ := UI_button(
						&ctx.ui_ctx,
						{UI_IconConfig{id = 5, size = 16, color = CRUST}},
						{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
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
			button_res, _ := UI_button(
				&ctx.ui_ctx,
				{UI_IconConfig{id = 2, size = 16, color = TEXT}},
				{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
				clay.CornerRadiusAll(5),
				SURFACE_2,
				SURFACE_1,
				SURFACE_0,
				5,
			)

			if .RELEASE in button_res {
				UI_widget_focus(&ctx.ui_ctx, tb_id)
				UI_status_add(&ctx.ui_ctx, {.TEXTBOX_SELECTED})
				UI_textbox_reset(&ctx.ui_ctx, len(rule))
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
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFit({})},
			padding = {left = 6, right = 6},
		},
	},
	) {
		if clay.UI()(
		{layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(1)}}, backgroundColor = color},
		) {
		}
	}
}

rule_add_modal :: proc(ctx: ^GUI_Context) {
	if .ADDING in ctx.statuses {
		res, _ := UI_modal_escapable(&ctx.ui_ctx, CRUST * {1, 1, 1, 0.75}, rule_add_menu, ctx)
		if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.ADDING}
	}
}

settings_modal :: proc(ctx: ^GUI_Context) {
	if .SETTINGS in ctx.statuses {
		res, _ := UI_modal_escapable(&ctx.ui_ctx, CRUST * {1, 1, 1, 0.75}, settings_menu, ctx)
		if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.SETTINGS}
	}
}

rule_add_menu :: proc(
	ui_ctx: ^UI_Context,
	ctx: rawptr,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
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
			sizing = {clay.SizingPercent(0.7), clay.SizingFit({})},
		},
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingFit({})},
				childAlignment = {y = .Center},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(16),
				childGap = 16,
			},
			backgroundColor = BASE,
			cornerRadius = clay.CornerRadiusAll(10),
		},
		) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingFit({})}}}) {
				UI_textlabel("Add Rule", {textColor = TEXT, fontSize = 20})
				UI_spacer(&ctx.ui_ctx, {min = 24})
				close_res, _ := UI_button(
					&ctx.ui_ctx,
					{UI_IconConfig{9, 20, TEXT}},
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
				if sync.mutex_guard(&mixologist.config_mutex) {
					if slice.contains(mixologist.config.rules[:], program) {
						found_count += 1
					}
				}
			}

			if len(ctx.programs) > 0 && found_count != len(ctx.programs) {
				UI_textlabel("Open Programs", {textColor = TEXT, fontSize = 16})
				if clay.UI()(
				{
					layout = {
						sizing = {clay.SizingGrow({}), clay.SizingFit({})},
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
							sizing = {clay.SizingGrow({}), clay.SizingFit({})},
						},
						clip = {vertical = true, childOffset = clay.GetScrollOffset()},
					},
					) {
						for program, idx in ctx.programs {
							if sync.mutex_guard(&mixologist.config_mutex) {
								if slice.contains(mixologist.config.rules[:], program) {
									continue
								}
							}

							selection_idx, selected := slice.linear_search(
								ctx.selected_programs[:],
								program,
							)

							if clay.UI()(
							{
								layout = {
									sizing = {clay.SizingGrow({}), clay.SizingFit({})},
									padding = clay.PaddingAll(8),
									childAlignment = {x = .Left, y = .Center},
								},
							},
							) {
								add_program_res, _ := UI_button(
									&ctx.ui_ctx,
									selected ? {UI_IconConfig{5, 16, TEXT}} : {},
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
								UI_horz_spacer(&ctx.ui_ctx, 24)
								UI_textlabel(program, {textColor = TEXT, fontSize = 16})

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

					UI_horz_spacer(&ctx.ui_ctx, 8)

					if clay.UI()({layout = {sizing = {clay.SizingFit({}), clay.SizingGrow({})}}}) {
						UI_scrollbar(
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

			UI_textlabel("Custom Rule", {textColor = TEXT, fontSize = 16})
			if clay.UI()(
			{
				layout = {
					childAlignment = {x = .Center},
					sizing = {clay.SizingGrow({}), clay.SizingFit({})},
				},
			},
			) {
				placeholder_str := "New rule..."
				tb_res, _ := UI_textbox(
					&ctx.ui_ctx,
					ctx.new_rule_buf[:],
					&ctx.new_rule_len,
					ctx.new_rule_len == 0 ? placeholder_str : string(ctx.new_rule_buf[:ctx.new_rule_len]),
					{
						layout = {
							sizing = {clay.SizingGrow({}), clay.SizingFixed(32)},
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
					sizing = {clay.SizingGrow({}), clay.SizingFit({})},
				},
			},
			) {
				rules_to_add := len(ctx.selected_programs) + int(ctx.new_rule_len > 0)
				button_res, _ := UI_button(
					&ctx.ui_ctx,
					{
						UI_TextConfig {
							text = rules_to_add > 1 ? "Add Rules" : "Add Rule",
							size = 16,
							color = TEXT,
						},
					},
					{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
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

settings_menu :: proc(
	ui_ctx: ^UI_Context,
	ctx: rawptr,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	ctx := cast(^GUI_Context)ctx

	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingPercent(0.8), clay.SizingFit({})},
			childAlignment = {x = .Left, y = .Center},
			layoutDirection = .TopToBottom,
			padding = clay.PaddingAll(16),
			childGap = 16,
		},
		backgroundColor = BASE,
		cornerRadius = clay.CornerRadiusAll(10),
	},
	) {
		if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingFit({})}}}) {
			UI_textlabel("Settings", {textColor = TEXT, fontSize = 20})
			UI_spacer(&ctx.ui_ctx)
			close_res, _ := UI_button(
				&ctx.ui_ctx,
				{UI_IconConfig{9, 20, TEXT}},
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
				sizing = {clay.SizingPercent(1), clay.SizingFit({})},
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
	label: UI_TextConfig,
	state: ^bool,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			padding = clay.PaddingAll(16),
			childGap = 8,
			childAlignment = {y = .Center},
		},
	},
	) {
		UI_textlabel(label.text, {textColor = label.color, fontSize = label.size})
		UI_spacer(&ctx.ui_ctx)
		res, _ = UI_switch(
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
	label: UI_TextConfig,
	options: []string,
	selected: ^int,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			padding = clay.PaddingAll(16),
			childGap = 8,
		},
	},
	) {
		UI_textlabel(label.text, {textColor = label.color, fontSize = label.size})
		UI_spacer(&ctx.ui_ctx)

		res, _ = UI_dropdown(&ctx.ui_ctx, options, selected, TEXT, SURFACE_0, 16, 8, 5)
	}
	return
}
