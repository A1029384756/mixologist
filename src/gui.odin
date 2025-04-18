package mixologist

import "./clay"
import "core:strings"

GUI_Context_Status :: enum u8 {
	ADDING_NEW,
	ADDING,
	RULES,
	VOLUME,
}
GUI_Context_Statuses :: bit_set[GUI_Context_Status]

GUI_Context :: struct {
	ui_ctx:          UI_Context,
	// rule modification
	active_line_buf: [1024]u8,
	active_line_len: int,
	active_line:     int,
	// rule creation
	new_rule_buf:    [1024]u8,
	new_rule_len:    int,
	rule_scrollbar:  UI_Scrollbar_Data,
	// config state
	statuses:        GUI_Context_Statuses,
}

gui_init :: proc(ctx: ^GUI_Context, minimized: bool) {
	UI_init(&ctx.ui_ctx, minimized)
	UI_load_font_mem(&ctx.ui_ctx, 16, #load("resources/fonts/Roboto-Regular.ttf"))
}

gui_tick :: proc(ctx: ^GUI_Context) {
	UI_tick(&ctx.ui_ctx, UI_create_layout, ctx)

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
}

UI_create_layout :: proc(
	ctx: ^UI_Context,
	userdata: rawptr,
) -> clay.ClayArray(clay.RenderCommand) {
	mgst_ctx := cast(^GUI_Context)userdata
	return create_layout(mgst_ctx)
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

	return clay.EndLayout()
}

volume_slider :: proc(ctx: ^GUI_Context) {
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
			append(&mixologist.events, Volume(vol))
			ctx.statuses += {.VOLUME}
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
			append(
				&mixologist.events,
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
					if .RELEASE in delete_res {
						append(&mixologist.events, Rule_Remove(rule))
						ctx.statuses += {.RULES}
					}
				}

				if clay.UI()({}) {
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

					if .RELEASE in cancel_res {
						ctx.active_line = 0
						UI_unfocus(&ctx.ui_ctx, tb_id)
					}
				}

				if clay.UI()({}) {
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

					if .RELEASE in apply_res {
						append(
							&mixologist.events,
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

rule_add_modal :: proc(ctx: ^GUI_Context) {
	if .ADDING in ctx.statuses {
		res, _ := UI_modal_escapable(&ctx.ui_ctx, CRUST * {1, 1, 1, 0.75}, rule_add_line, ctx)
		if .CANCEL in res || .SUBMIT in res do ctx.statuses -= {.ADDING}
	}
}

rule_add_line :: proc(
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
		if .ESCAPE in ctx.ui_ctx.keys_pressed do res += {.CANCEL}
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
				append(
					&mixologist.events,
					Rule_Add(strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len]))),
				)
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
						&mixologist.events,
						Rule_Add(strings.clone(string(ctx.new_rule_buf[:ctx.new_rule_len]))),
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
