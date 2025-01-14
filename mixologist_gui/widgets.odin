package mixologist_gui

import "./clay"
import rl "./raylib"
import "core:c"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:text/edit"

WidgetResult :: enum u8 {
	CHANGE,
	CANCEL,
	SUBMIT,
	PRESS,
	RELEASE,
	HOVER,
}
WidgetResults :: bit_set[WidgetResult]

textbox :: proc(
	ctx: ^Context,
	buf: []u8,
	textlen: ^int,
	active: bool,
	text_config: ^clay.TextElementConfig,
	rect_configs: []clay.TypedConfig,
) -> (
	res: WidgetResults,
) {
	if clay.UI(..rect_configs) {
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
		if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}

		local_id := clay.ID_LOCAL(#procedure)
		if clay.UI(
			local_id,
			clay.Layout(
				{
					sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
					childAlignment = {y = .CENTER},
				},
			),
			clay.Scroll({horizontal = true}),
		) {
			elem_loc_data := clay.GetElementLocationData(local_id.id)
			boundingbox := elem_loc_data.elementLocation

			if active {
				builder := strings.builder_from_bytes(buf)
				non_zero_resize(&builder.buf, textlen^)
				ctx.textbox_state.builder = &builder
				if ctx.textbox_state.id != u64(ctx.active_row) {
					ctx.textbox_state.id = u64(ctx.active_row)
					ctx.textbox_state.selection = {}
					edit.move_to(&ctx.textbox_state, .End)
				}

				if ctx.textbox_state.selection[0] > textlen^ ||
				   ctx.textbox_state.selection[1] > textlen^ {
					ctx.textbox_state.selection = {}
				}

				if strings.builder_len(ctx.textbox_input) > 0 {
					if edit.input_text(&ctx.textbox_state, strings.to_string(ctx.textbox_input)) >
					   0 {
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}
				}

				if rl.IsKeyPressed(.A) && rl.IsKeyDown(.LEFT_CONTROL) && !rl.IsKeyDown(.LEFT_ALT) {
					ctx.textbox_state.selection = {textlen^, 0}
				}

				if rl.IsKeyPressed(.X) && rl.IsKeyDown(.LEFT_CONTROL) && !rl.IsKeyDown(.LEFT_ALT) {
					if edit.cut(&ctx.textbox_state) {
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}
				}

				if rl.IsKeyPressed(.C) && rl.IsKeyDown(.LEFT_CONTROL) && !rl.IsKeyDown(.LEFT_ALT) {
					edit.copy(&ctx.textbox_state)
				}

				if rl.IsKeyPressed(.V) && rl.IsKeyDown(.LEFT_CONTROL) && !rl.IsKeyDown(.LEFT_ALT) {
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

				if (rl.IsKeyPressed(.DELETE) || rl.IsKeyPressedRepeat(.DELETE)) && textlen^ > 0 {
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

				if rl.IsMouseButtonDown(.LEFT) {
					idx := textlen^
					for i in 0 ..< textlen^ {
						if buf[i] > 0x80 && buf[i] < 0xC0 do continue

						clay_str := clay.MakeString(string(buf[:i]))
						text_size := measureText(&clay_str, text_config)

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
			text_config.wrapMode = .None

			if active {
				text_clay_str := clay.MakeString(text_str)
				text_size := measureText(&text_clay_str, text_config)

				head_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[0]])
				head_size := measureText(&head_clay_str, text_config)
				tail_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[1]])
				tail_size := measureText(&tail_clay_str, text_config)

				PADDING :: 20
				sizing := elem_loc_data.elementLocation
				ofmin := max(PADDING - head_size.width, sizing.width - text_size.width - PADDING)
				ofmax := min(sizing.width - head_size.width - PADDING, PADDING)
				ctx.textbox_offset = clamp(ctx.textbox_offset, int(ofmin), int(ofmax))
				ctx.textbox_offset = clamp(ctx.textbox_offset, min(int), 0)

				// cursor
				{
					if clay.UI(
						clay.Floating(
							{
								attachment = {element = .LEFT_CENTER, parent = .LEFT_CENTER},
								offset = {head_size.width + c.float(ctx.textbox_offset), 0},
								pointerCaptureMode = .PASSTHROUGH,
							},
						),
						clay.Layout(
							{
								sizing = {
									clay.SizingFixed(2),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
						),
						clay.Rectangle(
							{color = TEXT * {1, 1, 1, abs(math.sin(c.float(rl.GetTime() * 2)))}},
						),
					) {}
				}

				// selection box
				{
					if clay.UI(
						clay.Floating(
							{
								attachment = {element = .LEFT_CENTER, parent = .LEFT_CENTER},
								offset = {
									min(head_size.width, tail_size.width) +
									c.float(ctx.textbox_offset),
									0,
								},
								pointerCaptureMode = .PASSTHROUGH,
							},
						),
						clay.Layout(
							{
								sizing = {
									clay.SizingFixed(abs(head_size.width - tail_size.width)),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
						),
						clay.Rectangle({color = TEXT * {1, 1, 1, 0.25}}),
					) {}
				}

				scroll_data := clay.GetScrollContainerData(local_id.id)
				scroll_data.scrollPosition^ = {c.float(ctx.textbox_offset), 0}

				clay.Text(text_str, text_config)
			} else {
				clay.Text(text_str, text_config)
			}
		}
	}

	return
}

button :: proc(
	ctx: ^Context,
	color, hover_color: clay.Color,
	corner_radius: clay.CornerRadius,
	rect_configs: clay.TypedConfig,
) -> (
	res: WidgetResults,
) {
	if clay.UI() {
		if clay.UI(
			clay.Rectangle({color = clay.Hovered() ? RED : MAUVE, cornerRadius = corner_radius}),
		) {
			if clay.UI(rect_configs) {
				if clay.Hovered() do res += {.HOVER}
				if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
				if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
			}
		}
	}
	return
}

spacer :: proc() -> (res: WidgetResults) {
	if clay.UI(clay.Layout({sizing = {clay.SizingGrow({}), clay.SizingGrow({})}})) {
		if clay.UI() {
			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res += {.PRESS}
			if clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res += {.RELEASE}
		}
	}
	return
}
