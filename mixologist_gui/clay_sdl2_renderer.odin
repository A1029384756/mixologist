package mixologist_gui

import "./clay"
import "base:runtime"
import "core:c"
import "core:container/small_array"
import "core:fmt"
import "core:math"
import "core:strings"
import "vendor:sdl2"
import "vendor:sdl2/ttf"

Font :: struct {
	sizes:     map[u16]^ttf.Font,
	ttf_bytes: []u8,
}

Font_System :: struct {
	fonts:     small_array.Small_Array(int(max(u16)), Font),
	allocator: runtime.Allocator,
}

font_system: Font_System

font_system_init :: proc(allocator := context.allocator) {
	font_system.allocator = allocator
}

font_system_deinit :: proc() {
	for font in small_array.slice(&font_system.fonts) {
		for _, sized_font in font.sizes {
			ttf.CloseFont(sized_font)
		}
		delete(font.sizes)
	}
}

font_system_register :: proc(font_bytes: []u8, font_size: u16 = 16) -> int {
	ttf_font := ttf.OpenFontRW(
		sdl2.RWFromMem(raw_data(font_bytes), c.int(len(font_bytes))),
		true,
		c.int(font_size),
	)
	font := Font {
		sizes     = make(map[u16]^ttf.Font, font_system.allocator),
		ttf_bytes = font_bytes,
	}
	font.sizes[u16(font_size)] = ttf_font

	small_array.append(&font_system.fonts, font)
	return small_array.len(font_system.fonts) - 1
}

font_system_retrieve :: proc(font_id, font_size: u16) -> ^ttf.Font {
	font, font_id_get_err := small_array.get_ptr_safe(&font_system.fonts, int(font_id))
	if !font_id_get_err do return nil

	ttf_font, ttf_exists := font.sizes[font_size]
	if !ttf_exists {
		ttf_font = ttf.OpenFontRW(
			sdl2.RWFromMem(raw_data(font.ttf_bytes), c.int(len(font.ttf_bytes))),
			true,
			c.int(font_size),
		)
		font.sizes[font_size] = ttf_font
	}
	return ttf_font
}

clay_bb_to_sdl2_rect :: proc(bb: clay.BoundingBox) -> sdl2.Rect {
	return sdl2.Rect{c.int(bb.x), c.int(bb.y), c.int(bb.width), c.int(bb.height)}
}

clay_color_to_sdl2_color :: proc(color: clay.Color) -> sdl2.Color {
	return sdl2.Color{u8(color.r), u8(color.g), u8(color.b), u8(color.a)}
}

sdl2_RenderDrawCircleF :: proc(renderer: ^sdl2.Renderer, pos: [2]c.float, r: c.float) {
	x, y := r, c.float(0)
	t := 1 - x

	for x >= y {
		intensity := 1 - (t - math.floor(t))
		next_intensity := t - math.floor(t)

		color: [4]u8
		sdl2.GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a)

		sdl2.SetRenderDrawColor(
			renderer,
			color.r,
			color.g,
			color.b,
			u8(c.float(color.a) * intensity),
		)
		sdl2.RenderDrawPointF(renderer, pos.x + x, pos.y + y)
		sdl2.RenderDrawPointF(renderer, pos.x - x, pos.y + y)
		sdl2.RenderDrawPointF(renderer, pos.x + x, pos.y - y)
		sdl2.RenderDrawPointF(renderer, pos.x - x, pos.y - y)

		sdl2.SetRenderDrawColor(
			renderer,
			color.r,
			color.g,
			color.b,
			u8(c.float(color.a) * next_intensity),
		)
		sdl2.RenderDrawPointF(renderer, pos.x + y, pos.y + x)
		sdl2.RenderDrawPointF(renderer, pos.x - y, pos.y + x)
		sdl2.RenderDrawPointF(renderer, pos.x + y, pos.y - x)
		sdl2.RenderDrawPointF(renderer, pos.x - y, pos.y - x)

		y += 1
		if t < 0 {
			t += 2 * y + 1
		} else {
			x -= 1
			t += 2 * (y - x) + 1
		}

		sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
	}
}


sdl2_RenderFillCircleF :: proc(renderer: ^sdl2.Renderer, pos: [2]c.float, r: c.float) {
	x, y := r, c.float(0)
	t := 1 - x

	for x >= y {
		sdl2.RenderDrawLineF(renderer, pos.x - x, pos.y + y, pos.x + x, pos.y + y)
		sdl2.RenderDrawLineF(renderer, pos.x - x, pos.y - y, pos.x + x, pos.y - y)
		sdl2.RenderDrawLineF(renderer, pos.x - y, pos.y + x, pos.x + y, pos.y + x)
		sdl2.RenderDrawLineF(renderer, pos.x - y, pos.y - x, pos.x + y, pos.y - x)

		intensity := 1 - (t - math.floor(t))
		next_intensity := t - math.floor(t)

		color: [4]u8
		sdl2.GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a)

		sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, u8(255 * intensity))
		sdl2.RenderDrawPointF(renderer, pos.x + x, pos.y + y)
		sdl2.RenderDrawPointF(renderer, pos.x - x, pos.y + y)
		sdl2.RenderDrawPointF(renderer, pos.x + x, pos.y - y)
		sdl2.RenderDrawPointF(renderer, pos.x - x, pos.y - y)

		sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, u8(255 * next_intensity))
		sdl2.RenderDrawPointF(renderer, pos.x + y, pos.y + x)
		sdl2.RenderDrawPointF(renderer, pos.x - y, pos.y + x)
		sdl2.RenderDrawPointF(renderer, pos.x + y, pos.y - x)
		sdl2.RenderDrawPointF(renderer, pos.x - y, pos.y - x)

		y += 1
		if t < 0 {
			t += 2 * y + 1
		} else {
			x -= 1
			t += 2 * (y - x) + 1
		}

		sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
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

	border_radius := border_radius
	if border_radius > rect.w / 2 do border_radius = rect.w / 2
	if border_radius > rect.h / 2 do border_radius = rect.h / 2

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

	target := sdl2.CreateTexture(renderer, .RGBA8888, .TARGET, c.int(rect.w), c.int(rect.h))
	defer sdl2.DestroyTexture(target)

	sdl2.SetTextureBlendMode(target, .BLEND)
	sdl2.SetRenderTarget(renderer, target)

	color: [4]u8
	sdl2.GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a)

	sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 0)
	sdl2.RenderClear(renderer)

	sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, 255)

	sdl2_RenderFillCircleF(renderer, {border_radius, border_radius}, border_radius)
	sdl2_RenderFillCircleF(renderer, {rect.w - border_radius - 1, border_radius}, border_radius)
	sdl2_RenderFillCircleF(renderer, {border_radius, rect.h - border_radius - 1}, border_radius)
	sdl2_RenderFillCircleF(
		renderer,
		{rect.w - border_radius - 1, rect.h - border_radius - 1},
		border_radius,
	)

	sdl2.RenderFillRectF(
		renderer,
		&sdl2.FRect{border_radius, 0, rect.w - 2 * border_radius, border_radius},
	)
	sdl2.RenderFillRectF(
		renderer,
		&sdl2.FRect {
			border_radius,
			rect.h - border_radius,
			rect.w - 2 * border_radius,
			border_radius,
		},
	)
	sdl2.RenderFillRectF(
		renderer,
		&sdl2.FRect{0, border_radius, border_radius, rect.h - 2 * border_radius},
	)
	sdl2.RenderFillRectF(
		renderer,
		&sdl2.FRect {
			rect.w - border_radius,
			border_radius,
			border_radius,
			rect.h - 2 * border_radius,
		},
	)
	sdl2.RenderFillRectF(
		renderer,
		&sdl2.FRect {
			border_radius,
			border_radius,
			rect.w - 2 * border_radius,
			rect.h - 2 * border_radius,
		},
	)

	sdl2.SetRenderTarget(renderer, nil)
	sdl2.SetTextureAlphaMod(target, color.a)
	sdl2.RenderCopyF(renderer, target, nil, rect)
	sdl2.SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a)
	return
}

clay_measure_text_sdl2 :: proc "c" (
	text: ^clay.String,
	config: ^clay.TextElementConfig,
) -> clay.Dimensions {
	context = runtime.default_context()

	font := font_system_retrieve(config.fontId, config.fontSize)
	text := transmute(string)text.chars[:text.length]
	text_cstr := strings.clone_to_cstring(text)
	defer delete(text_cstr)

	size: [2]i32
	if ttf.SizeUTF8(font, text_cstr, &size.x, &size.y) < 0 do fmt.panicf("could not measure text %s", ttf.GetError())
	return {c.float(size.x), c.float(size.y)}
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
			font := font_system_retrieve(config.fontId, config.fontSize)
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
		case .Border:
			config := cmd.config.borderElementConfig
			if config.left.width > 0 {
				color := config.left.color
				sdl2.SetRenderDrawColor(
					renderer,
					u8(color.r),
					u8(color.g),
					u8(color.b),
					u8(color.a),
				)
				sdl2.RenderFillRectF(
					renderer,
					&sdl2.FRect {
						boundingbox.x,
						boundingbox.y + config.cornerRadius.topLeft,
						f32(config.left.width),
						boundingbox.height -
						config.cornerRadius.topLeft -
						config.cornerRadius.bottomLeft,
					},
				)
			}
			if config.right.width > 0 {
				color := config.right.color
				sdl2.SetRenderDrawColor(
					renderer,
					u8(color.r),
					u8(color.g),
					u8(color.b),
					u8(color.a),
				)
				sdl2.RenderFillRectF(
					renderer,
					&sdl2.FRect {
						boundingbox.x + boundingbox.width - f32(config.right.width),
						boundingbox.y + config.cornerRadius.topRight,
						f32(config.right.width),
						boundingbox.height -
						config.cornerRadius.topRight -
						config.cornerRadius.bottomRight,
					},
				)
			}
			if config.top.width > 0 {
				color := config.top.color
				sdl2.SetRenderDrawColor(
					renderer,
					u8(color.r),
					u8(color.g),
					u8(color.b),
					u8(color.a),
				)
				sdl2.RenderFillRectF(
					renderer,
					&sdl2.FRect {
						boundingbox.x + config.cornerRadius.topLeft,
						boundingbox.y,
						boundingbox.width -
						config.cornerRadius.topLeft -
						config.cornerRadius.topRight,
						f32(config.top.width),
					},
				)
			}
			if config.bottom.width > 0 {
				color := config.bottom.color
				sdl2.SetRenderDrawColor(
					renderer,
					u8(color.r),
					u8(color.g),
					u8(color.b),
					u8(color.a),
				)
				sdl2.RenderFillRectF(
					renderer,
					&sdl2.FRect {
						boundingbox.x + config.cornerRadius.bottomLeft,
						boundingbox.y + boundingbox.height - f32(config.bottom.width),
						boundingbox.width -
						config.cornerRadius.bottomLeft -
						config.cornerRadius.bottomRight,
						f32(config.bottom.width),
					},
				)
			}
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

clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	context = runtime.default_context()
	fmt.println(
		"clay error detected of type: %v: %s",
		errordata.errorType,
		errordata.errorText.chars[:errordata.errorText.length],
	)
}
