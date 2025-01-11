package mixologist_gui

import "./clay"
import rl "./raylib"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:text/edit"

TextEditOperation :: enum u8 {
	CHANGE,
	SUBMIT,
}
TextEditOperations :: bit_set[TextEditOperation]

CustomElements :: union {}

textbox :: proc(
	ctx: ^Context,
	buf: []u8,
	textlen: ^int,
	text_config: ^clay.TextElementConfig,
	rect_configs: []clay.TypedConfig,
) -> (
	res: TextEditOperations,
) {
	if clay.UI(..rect_configs) {
		if ctx.active_row == ctx.active_row {
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

			if rl.IsKeyPressedRepeat(.LEFT) {
				move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Left : .Left
				if rl.IsKeyDown(.LEFT_SHIFT) {
					edit.select_to(&ctx.textbox_state, move)
				} else {
					edit.move_to(&ctx.textbox_state, move)
				}
			}

			if rl.IsKeyPressedRepeat(.RIGHT) {
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

			if rl.IsKeyPressedRepeat(.BACKSPACE) && textlen^ > 0 {
				move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Left : .Left
				edit.delete_to(&ctx.textbox_state, move)
				textlen^ = strings.builder_len(builder)
				res += {.CHANGE}
			}

			if rl.IsKeyPressedRepeat(.DELETE) && textlen^ > 0 {
				move: edit.Translation = rl.IsKeyDown(.LEFT_CONTROL) ? .Word_Right : .Right
				edit.delete_to(&ctx.textbox_state, move)
				textlen^ = strings.builder_len(builder)
				res += {.CHANGE}
			}

			if rl.IsKeyPressed(.ENTER) {
				res += {.SUBMIT}
			}

			// if rl.IsMouseButtonDown(.LEFT) {
			// 	idx := textlen^
			// 	for i in 0 ..< textlen^ {
			// 		if buf[i] > 0x80 && buf[i] < 0xC0 do continue

			// 		// if rl.GetMouseX() 
			// 		clay_str := clay.String{c.int(i), raw_data(buf)}
			// 		text_size := measureText(&clay_str, text_config)
			// 	}
			// }

			text_str := string(buf[:textlen^])
			clay.Text(text_str, clay.TextConfig({textColor = TEXT, fontSize = 16}))
		}
	}

	return
}

button :: proc(
	ctx: ^Context,
	color, hover_color: clay.Color,
	corner_radius: clay.CornerRadius,
	rect_configs: clay.TypedConfig,
	click_on_release := true,
) -> (
	res: bool,
) {
	if clay.UI() {
		if clay.UI(
			clay.Rectangle({color = clay.Hovered() ? RED : MAUVE, cornerRadius = corner_radius}),
		) {
			if clay.UI(rect_configs) {
				if clay.Hovered() do ctx.statuses += {.HOVERING}
				if !click_on_release && clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res = true
				if click_on_release && clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res = true
			}
		}
	}
	return
}
