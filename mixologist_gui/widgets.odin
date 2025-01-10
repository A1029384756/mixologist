package mixologist_gui

import "./clay"
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
	configs: ..clay.TypedConfig,
	click_on_release := true,
) -> (
	res: bool,
) {
	if clay.UI() {
		if clay.UI(..configs) {
			if clay.Hovered() do ctx.hovering = true
			if !click_on_release && clay.Hovered() && .PRESSED in ctx.mouse[0] do res = true
			if click_on_release && clay.Hovered() && .RELEASED in ctx.mouse[0] do res = true
		}
	}
	return
}
