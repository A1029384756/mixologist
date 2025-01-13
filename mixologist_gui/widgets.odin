package mixologist_gui

import "./clay"
import rl "./raylib"
import "core:c"
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

CustomElements :: union {}

textbox :: proc(
	ctx: ^Context,
	id: string,
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

		if active {
			id := clay.GetElementId(clay.MakeString(id))
			elem_loc_data := clay.GetElementLocationData(id)

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
				if edit.input_text(&ctx.textbox_state, strings.to_string(ctx.textbox_input)) > 0 {
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

			if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && textlen^ > 0 {
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

			if elem_loc_data.found {
				boundingbox := elem_loc_data.elementLocation
				if rl.IsMouseButtonDown(.LEFT) {
					idx := textlen^
					for i in 0 ..< textlen^ {
						if buf[i] > 0x80 && buf[i] < 0xC0 do continue

						clay_str := clay.MakeString(string(buf[:i]))
						text_size := measureText(&clay_str, text_config)

						if c.float(rl.GetMouseX()) < boundingbox.x + text_size.width {
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


			// cursor
			if clay.UI() {
				_, end := edit.sorted_selection(&ctx.textbox_state)
				clay_str := clay.String{c.int(end), raw_data(buf)}
				if clay.UI(
					clay.Floating(
						{
							attachment = {element = .LEFT_CENTER, parent = .LEFT_CENTER},
							offset = {measureText(&clay_str, text_config).width, 0},
						},
					),
				) {
					if clay.UI(
						clay.Layout({sizing = {clay.SizingFixed(2), clay.SizingFixed(16)}}),
						clay.Rectangle(
							{color = TEXT * {1, 1, 1, abs(math.sin(c.float(rl.GetTime() * 2)))}},
						),
					) {}
				}
			}

			// selection box
			if clay.UI() {
				start_str := clay.String{c.int(ctx.textbox_state.selection[0]), raw_data(buf)}
				end_str := clay.String{c.int(ctx.textbox_state.selection[1]), raw_data(buf)}
				start := measureText(&start_str, text_config).width
				end := measureText(&end_str, text_config).width
				if clay.UI(
					clay.Floating(
						{
							attachment = {element = .LEFT_CENTER, parent = .LEFT_CENTER},
							offset = {min(start, end), 0},
						},
					),
				) {
					if clay.UI(
						clay.Layout(
							{sizing = {clay.SizingFixed(abs(start - end)), clay.SizingFixed(16)}},
						),
						clay.Rectangle({color = TEXT * {1, 1, 1, 0.25}}),
					) {}
				}
			}
		}

		text_str := string(buf[:textlen^])
		clay.Text(text_str, clay.TextConfig({textColor = TEXT, fontSize = 16}))
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
