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
