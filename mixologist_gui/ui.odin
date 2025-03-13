package mixologist_gui

import "./clay"
import rl "./raylib"
import "base:intrinsics"
import "core:c"
import sa "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:text/edit"

UI_Context :: struct {
	textbox_input:   strings.Builder,
	textbox_state:   edit.State,
	textbox_offset:  int,
	active_widgets:  sa.Small_Array(16, clay.ElementId),
	// input handling
	_text_store:     [1024]u8, // global text input per frame
	click_count:     int,
	prev_click_time: f64,
	click_debounce:  f64,
	statuses:        UI_Context_Statuses,
	// allocated
	memory:          []u8,
	font_allocator:  virtual.Arena,
}

UI_Scrollbar_Data :: struct {
	click_origin: clay.Vector2,
	pos_origin:   clay.Vector2,
}

UI_DOUBLE_CLICK_INTERVAL_MS :: 300

UI_Context_Status :: enum {
	TEXTBOX_SELECTED,
	TEXTBOX_HOVERING,
	BUTTON_HOVERING,
	BUTTON_HELD,
	DOUBLE_CLICKED,
	TRIPLE_CLICKED,
}
UI_Context_Statuses :: bit_set[UI_Context_Status]

UI_WidgetResult :: enum {
	CHANGE,
	CANCEL,
	SUBMIT,
	PRESS,
	FOCUS,
	DOUBLE_PRESS,
	TRIPLE_PRESS,
	RELEASE,
	HOVER,
}
UI_WidgetResults :: bit_set[UI_WidgetResult]

UI_init :: proc(ctx: ^UI_Context) {
	arena_init_err := virtual.arena_init_growing(&ctx.font_allocator)
	if arena_init_err != nil do panic("font allocator initialization failed")

	ctx.textbox_state.set_clipboard = UI__set_clipboard
	ctx.textbox_state.get_clipboard = UI__get_clipboard
	ctx.textbox_input = strings.builder_from_bytes(ctx._text_store[:])

	min_mem := c.size_t(clay.MinMemorySize())
	ctx.memory = make([]u8, min_mem)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(ctx.memory))
	window_size := [2]c.int{rl.GetScreenWidth(), rl.GetScreenWidth()}
	clay.Initialize(
		arena,
		{c.float(window_size.x), c.float(window_size.y)},
		{handler = UI__clay_error_handler},
	)

	clay.SetMeasureTextFunction(measureText, nil)

	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(800, 600, "Mixologist")
	rl.SetExitKey(.KEY_NULL)
}

UI_deinit :: proc(ctx: ^UI_Context) {
	virtual.arena_destroy(&ctx.font_allocator)
	delete(ctx.memory)
	rl.CloseWindow()
}

UI_get_time :: proc() -> f64 {
	return rl.GetTime()
}

UI_tick :: proc(
	ctx: ^UI_Context,
	ui_create_layout: proc(
		ctx: ^UI_Context,
		userdata: rawptr,
	) -> clay.ClayArray(clay.RenderCommand),
	userdata: rawptr,
) {
	// mouse multi-click
	{
		current_time := rl.GetTime()
		if rl.IsMouseButtonPressed(.LEFT) {
			if (current_time - ctx.prev_click_time) <= UI_DOUBLE_CLICK_INTERVAL_MS / 1000. {
				ctx.click_count += 1
			} else {
				ctx.click_count = 1
			}

			ctx.prev_click_time = current_time

			if ctx.click_count == 2 {
				ctx.statuses += {.DOUBLE_CLICKED}
			} else if ctx.click_count == 3 {
				ctx.statuses -= {.DOUBLE_CLICKED}
				ctx.statuses += {.TRIPLE_CLICKED}
			}
		} else if current_time - ctx.prev_click_time >= UI_DOUBLE_CLICK_INTERVAL_MS / 1000. {
			ctx.statuses -= {.DOUBLE_CLICKED, .TRIPLE_CLICKED}
		}
	}

	// get global text input
	{
		strings.builder_reset(&ctx.textbox_input)
		for char := rl.GetCharPressed(); char != 0; char = rl.GetCharPressed() {
			strings.write_rune(&ctx.textbox_input, char)
		}
	}

	when ODIN_DEBUG {
		if rl.IsKeyPressed(.D) && rl.IsKeyDown(.LEFT_CONTROL) {
			clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		}
	}

	clay.SetPointerState(transmute(clay.Vector2)rl.GetMousePosition(), rl.IsMouseButtonDown(.LEFT))
	clay.UpdateScrollContainers(
		false,
		transmute(clay.Vector2)rl.GetMouseWheelMoveV() * 5,
		rl.GetFrameTime(),
	)
	clay.SetLayoutDimensions({cast(f32)rl.GetScreenWidth(), cast(f32)rl.GetScreenHeight()})

	renderCommands := ui_create_layout(ctx, userdata)
	rl.BeginDrawing()
	clayRaylibRender(&renderCommands)
	rl.EndDrawing()

	if ctx.statuses >= {.TEXTBOX_HOVERING, .TEXTBOX_SELECTED} {
		rl.SetMouseCursor(.IBEAM)
	} else if .BUTTON_HOVERING in ctx.statuses || .TEXTBOX_HOVERING in ctx.statuses {
		rl.SetMouseCursor(.POINTING_HAND)
	} else {
		rl.SetMouseCursor(.ARROW)
	}

	if .BUTTON_HOVERING not_in ctx.statuses do ctx.statuses -= {.BUTTON_HELD}
	ctx.statuses -= {.TEXTBOX_HOVERING, .BUTTON_HOVERING}
}

UI_widget_active :: proc(ctx: ^UI_Context, id: clay.ElementId) -> bool {
	return slice.contains(sa.slice(&ctx.active_widgets), id)
}

UI_widget_focus :: proc(ctx: ^UI_Context, id: clay.ElementId) {
	if !slice.contains(sa.slice(&ctx.active_widgets), id) do sa.append(&ctx.active_widgets, id)
}

UI_status_add :: proc(ctx: ^UI_Context, statuses: UI_Context_Statuses) {
	ctx.statuses += statuses
}

UI_textbox_reset :: proc(ctx: ^UI_Context, textlen: int) {
	ctx.textbox_state.selection = {textlen, textlen}
}

UI_unfocus :: proc(ctx: ^UI_Context, id: clay.ElementId) {
	idx, found := slice.linear_search(sa.slice(&ctx.active_widgets), id)
	if found do sa.unordered_remove(&ctx.active_widgets, idx)
}

UI_unfocus_all :: proc(ctx: ^UI_Context) {
	sa.clear(&ctx.active_widgets)
}

UI_should_exit :: proc(ctx: ^UI_Context) -> bool {
	return rl.WindowShouldClose()
}

UI_load_font_mem :: proc(ctx: ^UI_Context, fontsize: u16, data: []u8, extension: cstring) -> u16 {
	font := rl.LoadFontFromMemory(
		extension,
		raw_data(data),
		c.int(len(data)),
		c.int(fontsize * 2),
		nil,
		0,
	)
	rl.SetTextureFilter(font.texture, .TRILINEAR)

	font_map := make(map[u16]rl.Font, 16, virtual.arena_allocator(&ctx.font_allocator))
	font_map[fontsize] = font
	raylib_font := RaylibFont {
		font      = font_map,
		bytes     = data,
		extension = extension,
	}

	sa.append(&raylibFonts, raylib_font)
	return u16(sa.len(raylibFonts) - 1)
}

UI_load_font :: proc(ctx: ^UI_Context, fontsize: u16, path: cstring) -> u16 {
	unimplemented()
}

UI__set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text)
	rl.SetClipboardText(text_cstr)
	delete(text_cstr)
	return true
}

UI__get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	text_cstr := rl.GetClipboardText()
	if text_cstr != nil {
		text = string(text_cstr)
		ok = true
	}
	return
}

UI__clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	// [TODO] find out why `ID_LOCAL` is producing duplicate id errors
	// context = runtime.default_context()
	// fmt.printfln("clay error detected: %s", errordata.errorText.chars[:errordata.errorText.length])
}

UI_scrollbar :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^UI_Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__scrollbar(
		ctx,
		scroll_container_data,
		scrollbar_data,
		bar_width,
		bar_color,
		target_color,
		hover_color,
		press_color,
	)

	active := UI_widget_active(ctx, id)
	if .PRESS in res {
		UI_widget_focus(ctx, id)
		if !active do res += {.FOCUS}
	}
	if active && rl.IsMouseButtonDown(.LEFT) {
		res += {.CHANGE}
		target_height := int(
			(scroll_container_data.scrollContainerDimensions.height /
				scroll_container_data.contentDimensions.height) *
			scroll_container_data.scrollContainerDimensions.height,
		)

		ratio := clay.Vector2 {
			scroll_container_data.contentDimensions.width /
			scroll_container_data.scrollContainerDimensions.width,
			scroll_container_data.contentDimensions.height /
			scroll_container_data.scrollContainerDimensions.height,
		}
		scroll_pos := (scrollbar_data.click_origin - rl.GetMousePosition()) * ratio
		scroll_pos.x += c.float(target_height) / 2

		scroll_pos.x = clamp(
			scroll_pos.x,
			-(scroll_container_data.contentDimensions.width -
				scroll_container_data.scrollContainerDimensions.width),
			0,
		)
		scroll_pos.y = clamp(
			scroll_pos.y,
			-(scroll_container_data.contentDimensions.height -
				scroll_container_data.scrollContainerDimensions.height),
			0,
		)

		scroll_container_data.scrollPosition^ = scroll_pos
	}
	if rl.IsMouseButtonReleased(.LEFT) do UI_unfocus(ctx, id)

	return
}

UI_textbox :: proc(
	ctx: ^UI_Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
	enabled: bool,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__textbox(ctx, buf, textlen, placeholder_text, config, border_config, text_config)

	if enabled {
		active := UI_widget_active(ctx, id)
		if .PRESS in res {
			UI_widget_focus(ctx, id)
			ctx.statuses += {.TEXTBOX_SELECTED}
			if !active {
				res += {.FOCUS}
			}
		}

		if .HOVER in res do ctx.statuses += {.TEXTBOX_HOVERING}

		if active {
			if .CANCEL in res do UI_unfocus(ctx, id)
			if .SUBMIT in res && textlen^ > 0 do UI_unfocus(ctx, id)
		}
	}
	if .HOVER not_in res && rl.IsMouseButtonPressed(.LEFT) do UI_unfocus(ctx, id)
	return
}

UI_slider :: proc(
	ctx: ^UI_Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	snap_threshhold: T,
	notches: ..T,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	res, id = UI__slider(
		ctx,
		pos,
		default_val,
		min_val,
		max_val,
		color,
		hover_color,
		press_color,
		line_color,
		line_highlight,
		{sizing = {clay.SizingGrow({}), clay.SizingFixed(16)}},
		..notches,
	)

	active := UI_widget_active(ctx, id)
	if .PRESS in res {
		UI_widget_focus(ctx, id)
		if !active do res += {.FOCUS}
	}
	if active && rl.IsMouseButtonDown(.LEFT) do res += {.CHANGE}

	if .HOVER not_in res && rl.IsMouseButtonPressed(.LEFT) do UI_unfocus(ctx, id)
	if rl.IsMouseButtonReleased(.LEFT) do UI_unfocus(ctx, id)

	for notch in notches {
		if abs(pos^ - notch) < snap_threshhold {
			pos^ = notch
			break
		}
	}
	return
}

UI_text_button :: proc(
	ctx: ^UI_Context,
	text: string,
	layout: clay.LayoutConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color, text_color: clay.Color,
	text_size: u16,
	text_padding: u16,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__text_button(
		ctx,
		text,
		layout,
		corner_radius,
		color,
		hover_color,
		press_color,
		text_color,
		text_size,
		text_padding,
	)

	if .HOVER in res do ctx.statuses += {.BUTTON_HOVERING}
	else do UI_unfocus(ctx, id)

	if .PRESS in res {
		ctx.statuses += {.BUTTON_HELD}
		UI_widget_focus(ctx, id)
	}
	if .RELEASE in res {
		ctx.statuses -= {.BUTTON_HELD}
		UI_unfocus(ctx, id)
	}
	return
}

UI__scrollbar :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^UI_Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	bar_width := bar_width
	if scroll_container_data.contentDimensions.height <= scroll_container_data.scrollContainerDimensions.height do bar_width = 0

	if clay.UI()(
	{
		layout = {sizing = {clay.SizingFixed(c.float(bar_width)), clay.SizingGrow({})}},
		floating = {attachment = {element = .RightTop, parent = .RightTop}, attachTo = .Parent},
		backgroundColor = bar_color,
	},
	) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		scroll_res, scroll_id := UI__scroll_target(
			ctx,
			scroll_container_data,
			bar_width,
			target_color,
			hover_color,
			press_color,
		)

		scroll_active := UI_widget_active(ctx, scroll_id)
		if .PRESS in scroll_res {
			UI_widget_focus(ctx, scroll_id)
			if !scroll_active {
				res += {.FOCUS}
				scrollbar_data.click_origin = rl.GetMousePosition()
				scrollbar_data.pos_origin = scroll_container_data.scrollPosition^
			}
		}
		if scroll_active {
			scroll_res += {.CHANGE}

			ratio := clay.Vector2 {
				scroll_container_data.contentDimensions.width /
				scroll_container_data.scrollContainerDimensions.width,
				scroll_container_data.contentDimensions.height /
				scroll_container_data.scrollContainerDimensions.height,
			}

			scroll_pos :=
				scrollbar_data.pos_origin +
				(scrollbar_data.click_origin - rl.GetMousePosition()) * ratio
			scroll_pos.x = clamp(
				scroll_pos.x,
				-(scroll_container_data.contentDimensions.width -
					scroll_container_data.scrollContainerDimensions.width),
				0,
			)
			scroll_pos.y = clamp(
				scroll_pos.y,
				-(scroll_container_data.contentDimensions.height -
					scroll_container_data.scrollContainerDimensions.height),
				0,
			)

			scroll_container_data.scrollPosition^ = scroll_pos
		}
		if rl.IsMouseButtonReleased(.LEFT) do UI_unfocus(ctx, scroll_id)

		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
		if rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
	}
	return
}

UI__scroll_target :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	width: int,
	color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	target_height := int(
		(scroll_container_data.scrollContainerDimensions.height /
			scroll_container_data.contentDimensions.height) *
		scroll_container_data.scrollContainerDimensions.height,
	)
	size := [2]int{width, target_height}

	if clay.UI()(
	{
		floating = {
			offset = {
				0,
				-(scroll_container_data.scrollPosition.y /
					scroll_container_data.contentDimensions.height) *
				scroll_container_data.scrollContainerDimensions.height,
			},
			attachment = {element = .RightTop, parent = .RightTop},
			attachTo = .Parent,
		},
	},
	) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingFixed(c.float(size.x)), clay.SizingFixed(c.float(size.y))},
			},
		},
		) {
			active := UI_widget_active(ctx, local_id)
			selected_color := color
			if active do selected_color = press_color
			else if clay.Hovered() do selected_color = hover_color

			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
			if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}

			if clay.UI()(
			{
				layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}},
				backgroundColor = selected_color,
				cornerRadius = clay.CornerRadiusAll(c.float(size.x) / 2),
			},
			) {
			}
		}
	}
	return
}

UI__textbox :: proc(
	ctx: ^UI_Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	config := config
	border_config := border_config
	text_config := clay.TextConfig(text_config)

	if clay.UI()({layout = {sizing = config.layout.sizing}}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, local_id)
		if !active do border_config.width = {}
		if !active do config.backgroundColor *= {0.8, 0.8, 0.8, 1}
		config.border = border_config
		config.layout.sizing = {clay.SizingGrow({}), clay.SizingGrow({})}


		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
		if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}

		if clay.UI()(config) {
			if clay.UI()(
			{
				id = local_id,
				layout = {
					sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
					childAlignment = {y = .Center},
				},
				scroll = {horizontal = active},
			},
			) {
				elem_loc_data := clay.GetElementData(local_id)
				boundingbox := elem_loc_data.boundingBox

				if active {
					builder := strings.builder_from_bytes(buf)
					non_zero_resize(&builder.buf, textlen^)
					ctx.textbox_state.builder = &builder

					textbox_selected: bool
					for widget in sa.slice(&ctx.active_widgets) {
						if ctx.textbox_state.id == u64(widget.id) {
							textbox_selected = true
							break
						}
					}

					if !textbox_selected {
						ctx.textbox_state.id = u64(local_id.id)
						ctx.textbox_state.selection = {}
						edit.move_to(&ctx.textbox_state, .End)
					}

					if ctx.textbox_state.selection[0] > textlen^ ||
					   ctx.textbox_state.selection[1] > textlen^ {
						ctx.textbox_state.selection = {}
					}

					if strings.builder_len(ctx.textbox_input) > 0 {
						if edit.input_text(
							   &ctx.textbox_state,
							   strings.to_string(ctx.textbox_input),
						   ) >
						   0 {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if rl.IsKeyPressed(.A) &&
					   rl.IsKeyDown(.LEFT_CONTROL) &&
					   !rl.IsKeyDown(.LEFT_ALT) {
						ctx.textbox_state.selection = {textlen^, 0}
					}

					if rl.IsKeyPressed(.X) &&
					   rl.IsKeyDown(.LEFT_CONTROL) &&
					   !rl.IsKeyDown(.LEFT_ALT) {
						if edit.cut(&ctx.textbox_state) {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if rl.IsKeyPressed(.C) &&
					   rl.IsKeyDown(.LEFT_CONTROL) &&
					   !rl.IsKeyDown(.LEFT_ALT) {
						edit.copy(&ctx.textbox_state)
					}

					if rl.IsKeyPressed(.V) &&
					   rl.IsKeyDown(.LEFT_CONTROL) &&
					   !rl.IsKeyDown(.LEFT_ALT) {
						if edit.paste(&ctx.textbox_state) {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if (rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT)) {
						move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Left : .Left
						if rl.IsKeyDown(.LEFT_SHIFT) {
							edit.select_to(&ctx.textbox_state, move)
						} else {
							edit.move_to(&ctx.textbox_state, move)
						}
					}

					if (rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT)) {
						move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Right : .Right
						if rl.IsKeyDown(.LEFT_SHIFT) {
							edit.select_to(&ctx.textbox_state, move)
						} else {
							edit.move_to(&ctx.textbox_state, move)
						}
					}

					if rl.IsKeyPressed(.HOME) {
						if rl.IsKeyDown(.LEFT_SHIFT) {
							edit.select_to(&ctx.textbox_state, .Start)
						} else {
							edit.move_to(&ctx.textbox_state, .Start)
						}
					}

					if rl.IsKeyPressed(.END) {
						if rl.IsKeyDown(.LEFT_SHIFT) {
							edit.select_to(&ctx.textbox_state, .End)
						} else {
							edit.move_to(&ctx.textbox_state, .End)
						}
					}

					if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) &&
					   textlen^ > 0 {
						move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Left : .Left
						edit.delete_to(&ctx.textbox_state, move)
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}

					if (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE)) &&
					   textlen^ > 0 {
						move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Right : .Right
						edit.delete_to(&ctx.textbox_state, move)
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}

					if rl.IsKeyPressed(.ENTER) {
						res += {.SUBMIT}
					}

					if rl.IsKeyPressed(.ESCAPE) {
						res += {.CANCEL}
					}

					// multi-click + click and drag
					{
						if .DOUBLE_CLICKED in ctx.statuses {
							edit.move_to(&ctx.textbox_state, .Word_Start)
							edit.select_to(&ctx.textbox_state, .Word_End)
						} else if .TRIPLE_CLICKED in ctx.statuses {
							ctx.textbox_state.selection = {textlen^, 0}
						} else if rl.IsMouseButtonDown(.LEFT) {
							idx := textlen^
							for i in 0 ..< textlen^ {
								if buf[i] > 0x80 && buf[i] < 0xC0 do continue

								clay_str := clay.MakeString(string(buf[:i]))
								text_size := measureText(
									clay.StringSlice {
										clay_str.length,
										clay_str.chars,
										clay_str.chars,
									},
									text_config,
									nil,
								)

								if c.float(rl.GetMouseX()) <
								   boundingbox.x + text_size.width + c.float(ctx.textbox_offset) {
									idx = i
									break
								}
							}

							ctx.textbox_state.selection[0] = idx
							if rl.IsMouseButtonPressed(.LEFT) && !rl.IsKeyDown(.LEFT_SHIFT) {
								ctx.textbox_state.selection[1] = idx
							}
						}
					}

					text_str := string(buf[:textlen^])
					text_clay_str := clay.MakeString(text_str)
					text_size := measureText(
						clay.StringSlice {
							text_clay_str.length,
							text_clay_str.chars,
							text_clay_str.chars,
						},
						text_config,
						nil,
					)

					head_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[0]])
					head_size := measureText(
						clay.StringSlice {
							head_clay_str.length,
							head_clay_str.chars,
							head_clay_str.chars,
						},
						text_config,
						nil,
					)
					tail_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[1]])
					tail_size := measureText(
						clay.StringSlice {
							tail_clay_str.length,
							tail_clay_str.chars,
							tail_clay_str.chars,
						},
						text_config,
						nil,
					)

					PADDING :: 20
					sizing := [2]c.float {
						elem_loc_data.boundingBox.width,
						elem_loc_data.boundingBox.height,
					}
					ofmin := max(PADDING - head_size.width, sizing.x - text_size.width - PADDING)
					ofmax := min(sizing.x - head_size.width - PADDING, PADDING)
					ctx.textbox_offset = clamp(ctx.textbox_offset, int(ofmin), int(ofmax))
					ctx.textbox_offset = clamp(ctx.textbox_offset, min(int), 0)

					// cursor
					{
						if clay.UI()(
						{
							floating = {
								attachment = {element = .LeftCenter, parent = .LeftCenter},
								offset = {head_size.width + c.float(ctx.textbox_offset), 0},
								pointerCaptureMode = .Passthrough,
								attachTo = .Parent,
							},
							layout = {
								sizing = {
									clay.SizingFixed(2),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
							backgroundColor = TEXT *
							{1, 1, 1, abs(math.sin(c.float(rl.GetTime() * 2)))},
						},
						) {
							if clay.Hovered() do res += {.HOVER}
							if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
							if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
						}
					}

					// selection box
					{
						if clay.UI()(
						{
							floating = {
								attachment = {element = .LeftCenter, parent = .LeftCenter},
								offset = {
									min(head_size.width, tail_size.width) +
									c.float(ctx.textbox_offset),
									0,
								},
								pointerCaptureMode = .Passthrough,
								attachTo = .Parent,
							},
							layout = {
								sizing = {
									clay.SizingFixed(abs(head_size.width - tail_size.width)),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
							backgroundColor = TEXT * {1, 1, 1, 0.25},
						},
						) {
							if clay.Hovered() do res += {.HOVER}
							if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
							if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
						}
					}

					// [TODO] fix nested scrolldata fetching
					scroll_data := clay.GetScrollContainerData(local_id)
					if scroll_data.found do scroll_data.scrollPosition^ = {c.float(ctx.textbox_offset), 0}
					else do fmt.eprintln("Could not get scroll data for:", local_id)

					clay.Text(text_str, text_config)
				} else {
					clay.Text(placeholder_text, text_config)
				}
			}
		}
	}
	return
}

UI__slider :: proc(
	ctx: ^UI_Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	notches: ..T,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, local_id)
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
		if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				childAlignment = {y = .Center},
			},
		},
		) {
			boundingbox := clay.GetElementData(id).boundingBox
			minor_dimension := min(boundingbox.width, boundingbox.height)
			major_dimension := max(boundingbox.width, boundingbox.height)

			scroll := rl.GetMouseWheelMove()
			if active && (!rl.IsMouseButtonPressed(.LEFT) && rl.IsMouseButtonDown(.LEFT)) {
				relative_x := T(rl.GetMouseX()) - T(boundingbox.x)
				slope := T(max_val - min_val) / T(boundingbox.width)
				pos^ = min_val + slope * (relative_x)
				pos^ = clamp(pos^, min_val, max_val)
			} else if scroll != 0 {
				pos^ -= scroll / 10
			}

			selected_color := color
			if active do selected_color = press_color
			else if clay.Hovered() do selected_color = hover_color

			val_to_pos :: proc(
				val, min_val, max_val, major, minor: $T,
			) -> T where intrinsics.type_is_float(T) {
				return abs(val - min_val) / abs(max_val - min_val) * major
			}

			slider_pos := val_to_pos(pos^, min_val, max_val, major_dimension, minor_dimension)
			default_mark := val_to_pos(
				default_val,
				min_val,
				max_val,
				major_dimension,
				minor_dimension,
			)

			LINE_THICKNESS :: 0.25
			if clay.UI()(
			{
				layout = {
					sizing = {
						clay.SizingPercent(1),
						clay.SizingFixed(minor_dimension * LINE_THICKNESS),
					},
				},
				backgroundColor = line_color,
			},
			) {
				if clay.UI()(
				{
					floating = {
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						offset = {min(slider_pos, default_mark), 0},
						attachTo = .Parent,
					},
					layout = {
						sizing = {
							clay.SizingFixed(
								major_dimension *
								(abs(pos^ - default_val) / abs(max_val - min_val)),
							),
							clay.SizingFixed(minor_dimension * LINE_THICKNESS),
						},
					},
					backgroundColor = line_highlight,
				},
				) {}
			}

			NOTCH_WIDTH :: 2
			for notch in notches {
				if clay.UI()(
				{
					floating = {
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						offset = {
							val_to_pos(notch, min_val, max_val, major_dimension, minor_dimension) -
							NOTCH_WIDTH / 2,
							0,
						},
						pointerCaptureMode = .Passthrough,
						attachTo = .Parent,
					},
					layout = {
						sizing = {
							clay.SizingFixed(NOTCH_WIDTH),
							clay.SizingFixed(minor_dimension),
						},
					},
					backgroundColor = line_color,
					cornerRadius = clay.CornerRadiusAll(minor_dimension / 2),
				},
				) {}
			}
			if clay.UI()(
			{
				floating = {
					attachment = {element = .LeftCenter, parent = .LeftCenter},
					offset = {slider_pos - minor_dimension / 2, 0},
					pointerCaptureMode = .Passthrough,
					attachTo = .Parent,
				},
				layout = {
					sizing = {
						clay.SizingFixed(minor_dimension),
						clay.SizingFixed(minor_dimension),
					},
				},
				backgroundColor = selected_color,
				cornerRadius = clay.CornerRadiusAll(minor_dimension / 2),
			},
			) {}
		}
	}
	return
}


UI__text_button :: proc(
	ctx: ^UI_Context,
	text: string,
	layout: clay.LayoutConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color, text_color: clay.Color,
	text_size: u16,
	text_padding: u16,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	text_config := clay.TextConfig({textColor = text_color, fontSize = text_size})

	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, id)
		selected_color := color
		if active do selected_color = press_color
		else if clay.Hovered() do selected_color = hover_color

		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
		if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				padding = clay.PaddingAll(text_padding),
			},
			backgroundColor = selected_color,
			cornerRadius = corner_radius,
		},
		) {
			clay.Text(text, text_config)
		}
	}
	return
}

UI_spacer :: proc() -> (res: UI_WidgetResults, id: clay.ElementId) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id
		if clay.UI()({id = local_id}) {
			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
			if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
		}
	}
	return
}
