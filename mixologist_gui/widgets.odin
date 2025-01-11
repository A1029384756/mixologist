package mixologist_gui

import "./clay"
import rl "./raylib"
import "core:strings"

textbox :: proc(ctx: ^Context, buf: []u8, len: ^int, configs: ..clay.TypedConfig) {
	if clay.UI(..configs) {
		builder := strings.builder_from_bytes(buf)
		non_zero_resize(&builder.buf, len^)
		ctx.textbox_state.builder = &builder
	}
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
				if clay.Hovered() do ctx.hovering = true
				if !click_on_release && clay.Hovered() && rl.IsMouseButtonPressed(.LEFT) do res = true
				if click_on_release && clay.Hovered() && rl.IsMouseButtonReleased(.LEFT) do res = true
			}
		}
	}
	return
}
