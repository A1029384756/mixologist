package mixologist_gui

import "./clay"
import "base:runtime"
import "core:c"
import "core:container/small_array"
import "core:fmt"
import "core:strings"
import "vendor:sdl2"
import "vendor:sdl2/ttf"

@(private = "file")
fonts: small_array.Small_Array(int(max(u16)), ^ttf.Font)

register_font :: proc(font: ^ttf.Font) -> int {
	small_array.append(&fonts, font)
	return small_array.len(fonts) - 1
}

clay_bb_to_sdl2_rect :: proc(bb: clay.BoundingBox) -> sdl2.Rect {
	return sdl2.Rect{c.int(bb.x), c.int(bb.y), c.int(bb.width), c.int(bb.height)}
}

clay_color_to_sdl2_color :: proc(color: clay.Color) -> sdl2.Color {
	return sdl2.Color{u8(color.r), u8(color.g), u8(color.b), u8(color.a)}
}

sdl2_RenderFillCircle :: proc(renderer: ^sdl2.Renderer, pos: [2]c.int, r: c.int) {
	help_fill :: proc(renderer: ^sdl2.Renderer, pos, range: [2]c.int) {
		sdl2.RenderDrawLine(
			renderer,
			pos.x + range.x,
			pos.y + range.y,
			pos.x - range.x,
			pos.y + range.y,
		)
		sdl2.RenderDrawLine(
			renderer,
			pos.x + range.x,
			pos.y - range.y,
			pos.x - range.x,
			pos.y - range.y,
		)
		sdl2.RenderDrawLine(
			renderer,
			pos.x + range.y,
			pos.y + range.x,
			pos.x - range.y,
			pos.y + range.x,
		)
		sdl2.RenderDrawLine(
			renderer,
			pos.x + range.y,
			pos.y - range.x,
			pos.x - range.y,
			pos.y - range.x,
		)
	}


	x, y, d: c.int = 0, r, 3 - 2 * r
	help_fill(renderer, pos, {x, y})

	for y >= x {
		x += 1
		if d > 0 {
			y -= 1
			d = d + 4 * (x - y) + 10
		} else {
			d = d + 4 * x + 6
		}
		help_fill(renderer, pos, {x, y})
	}
}

sdl2_RenderFillFRectRounded :: proc(
	renderer: ^sdl2.Renderer,
	rect: ^sdl2.FRect,
	border_radius: c.float,
) -> (
	res: c.int,
) {
	if renderer == nil do return -1
	if border_radius < 0 do return -1
	if border_radius < 1 do return sdl2.RenderFillRectF(renderer, rect)

	if rect.w == 0 || rect.h == 0 {
		return sdl2.RenderDrawLine(
			renderer,
			c.int(rect.x),
			c.int(rect.y),
			c.int(rect.x + rect.w),
			c.int(rect.y + rect.h),
		)
	}

	corrected_radius: c.float
	if border_radius * 2 > rect.w {
		corrected_radius = rect.w / 2
	}
	if corrected_radius * 2 > rect.h {
		corrected_radius = rect.h / 2
	}

	top_left, top_right, bottom_left, bottom_right: [2]c.int
	top_left = {c.int(rect.x + border_radius), c.int(rect.y + border_radius)}
	top_right = {c.int(rect.x + rect.w - border_radius), c.int(rect.y + border_radius)}
	bottom_left = {c.int(rect.x + border_radius), c.int(rect.y + rect.h - border_radius)}
	bottom_right = {c.int(rect.x + rect.w - border_radius), c.int(rect.y + rect.h - border_radius)}

	sdl2_RenderFillCircle(renderer, top_left, c.int(border_radius))
	sdl2_RenderFillCircle(renderer, top_right, c.int(border_radius))
	sdl2_RenderFillCircle(renderer, bottom_left, c.int(border_radius))
	sdl2_RenderFillCircle(renderer, bottom_right, c.int(border_radius))

	sdl2.RenderFillRect(
		renderer,
		&sdl2.Rect {
			c.int(rect.x + border_radius),
			c.int(rect.y),
			c.int(rect.w - 2 * border_radius),
			c.int(rect.h),
		},
	)

	sdl2.RenderFillRect(
		renderer,
		&sdl2.Rect {
			c.int(rect.x),
			c.int(rect.y + border_radius),
			c.int(rect.w),
			c.int(rect.h - 2 * border_radius),
		},
	)

	return
}

measure_text_temp_alloc :: proc "c" (
	text: ^clay.String,
	config: ^clay.TextElementConfig,
) -> clay.Dimensions {
	context = runtime.default_context()

	font := small_array.get(fonts, int(config.fontId))
	text := transmute(string)text.chars[:text.length]
	text_cstr := strings.clone_to_cstring(text)
	defer delete(text_cstr)

	size: [2]i32
	if ttf.SizeUTF8(font, text_cstr, &size.x, &size.y) < 0 do fmt.panicf("could not measure text")
	return {f32(size.x), f32(size.y)}
}

@(private = "file")
current_clipping_rect: sdl2.Rect

clay_render :: proc(
	renderer: ^sdl2.Renderer,
	render_cmds: ^clay.ClayArray(clay.RenderCommand),
	temp_allocator := context.temp_allocator,
) {
	for i in 0 ..< render_cmds.length {
		cmd := clay.RenderCommandArray_Get(render_cmds, i)
		boundingbox := cmd.boundingBox
		#partial switch cmd.commandType {
		case .None:
		case .Text:
			config := cmd.config.textElementConfig
			text := cmd.text
			text_cstr := strings.clone_to_cstring(
				transmute(string)text.chars[:text.length],
				temp_allocator,
			)
			font := small_array.get(fonts, int(config.fontId))
			surface := ttf.RenderUTF8_Blended(
				font,
				text_cstr,
				clay_color_to_sdl2_color(config.textColor),
			)
			texture := sdl2.CreateTextureFromSurface(renderer, surface)

			dest := clay_bb_to_sdl2_rect(boundingbox)
			sdl2.RenderCopy(renderer, texture, nil, &dest)

			sdl2.DestroyTexture(texture)
			sdl2.FreeSurface(surface)
		case .Image:
			config := cmd.config.imageElementConfig
			dest := clay_bb_to_sdl2_rect(boundingbox)
			sdl2.RenderCopy(
				renderer,
				cast(^sdl2.Texture)config.imageData,
				&sdl2.Rect {
					0,
					0,
					i32(config.sourceDimensions.width),
					i32(config.sourceDimensions.height),
				},
				&dest,
			)
		case .Rectangle:
			config := cmd.config.rectangleElementConfig
			color := config.color
			sdl2.SetRenderDrawColor(renderer, u8(color.r), u8(color.g), u8(color.b), u8(color.a))
			sdl2_RenderFillFRectRounded(
				renderer,
				&sdl2.FRect{boundingbox.x, boundingbox.y, boundingbox.width, boundingbox.height},
				config.cornerRadius.topLeft,
			)
		case .ScissorStart:
			dest := clay_bb_to_sdl2_rect(boundingbox)
			sdl2.RenderSetClipRect(renderer, &dest)
		case .ScissorEnd:
			sdl2.RenderSetClipRect(renderer, nil)
		case:
			fmt.panicf("rendering for %v not implemented", cmd.commandType)
		}
	}
}
