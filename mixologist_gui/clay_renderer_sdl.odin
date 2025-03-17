package mixologist_gui

import "base:runtime"
import "clay"
import "core:c"
import sa "core:container/small_array"
import "core:math"
import "core:math/linalg"
import ttf "sdl3_ttf"
import sdl "vendor:sdl3"

clay_sdl_renderer :: proc(
	ctx: ^UI_Context,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	for i in 0 ..< render_commands.length {
		cmd := clay.RenderCommandArray_Get(render_commands, c.int(i))
		bounding_box := cmd.boundingBox
		rect := sdl.FRect{bounding_box.x, bounding_box.y, bounding_box.width, bounding_box.height}

		switch cmd.commandType {
		case .None:
		case .Text:
			config := cmd.renderData.text
			font := UI_retrieve_font(ctx, config.fontId, config.fontSize)
			surface := ttf.RenderText_Blended(
				font,
				cstring(config.stringContents.chars),
				c.size_t(config.stringContents.length),
				{
					u8(config.textColor.r),
					u8(config.textColor.g),
					u8(config.textColor.b),
					u8(config.textColor.a),
				},
			)
			texture := sdl.CreateTextureFromSurface(ctx.renderer, surface)
			sdl.DestroySurface(surface)
			sdl.RenderTexture(
				ctx.renderer,
				texture,
				nil,
				&sdl.FRect{rect.x, rect.y, c.float(texture.w), c.float(texture.h)},
			)
			sdl.DestroyTexture(texture)
		case .Rectangle:
			config := cmd.renderData.rectangle
			sdl.SetRenderDrawBlendMode(ctx.renderer, {.BLEND})
			sdl.SetRenderDrawColor(
				ctx.renderer,
				u8(config.backgroundColor.r),
				u8(config.backgroundColor.g),
				u8(config.backgroundColor.b),
				u8(config.backgroundColor.a),
			)
			if config.cornerRadius.topLeft > 0 {
				clay_sdl_renderfillfoundedrect(
					ctx,
					rect,
					config.cornerRadius.topLeft,
					config.backgroundColor,
				)
			} else {
				sdl.RenderFillRect(ctx.renderer, &rect)
			}
		case .Border:
		case .ScissorStart:
		case .ScissorEnd:
		case .Image:
		case .Custom:
		}
	}
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	context = runtime.default_context()
	ctx := cast(^UI_Context)userData
	font := UI_retrieve_font(ctx, config.fontId, config.fontSize)

	size: [2]c.int
	ttf.GetStringSize(font, cstring(text.chars), c.size_t(text.length), &size.x, &size.y)
	return {c.float(size.x), c.float(size.y)}
}

NUM_CIRCLE_SEGMENTS :: 16

clay_color_to_sdl_fcolor :: proc(color: clay.Color) -> sdl.FColor {
	return {color.r / 255, color.g / 255, color.b / 255, color.a / 255}
}

clay_sdl_renderfillfoundedrect :: proc(
	ctx: ^UI_Context,
	rect: sdl.FRect,
	corner_radius: c.float,
	color: clay.Color,
	allocator := context.temp_allocator,
) {
	color := clay_color_to_sdl_fcolor(color)

	min_radius := min(rect.w, rect.h) / 2
	clamped_radius := min(corner_radius, min_radius)
	num_circle_segments := max(NUM_CIRCLE_SEGMENTS, int(clamped_radius * 0.5))

	total_verts := int(4 + (4 * (num_circle_segments * 2)) + 2 * 4)
	total_indices := int(6 + (4 * (num_circle_segments * 3)) + 6 * 4)

	vertices := make([dynamic]sdl.Vertex, 0, total_verts, allocator)
	indices := make([dynamic]c.int, 0, total_indices, allocator)

	append(
		&vertices,
		sdl.Vertex{{rect.x + clamped_radius, rect.y + clamped_radius}, color, {0, 0}},
	)
	append(
		&vertices,
		sdl.Vertex{{rect.x + rect.w - clamped_radius, rect.y + clamped_radius}, color, {1, 0}},
	)
	append(
		&vertices,
		sdl.Vertex {
			{rect.x + rect.w - clamped_radius, rect.y + rect.h - clamped_radius},
			color,
			{1, 1},
		},
	)
	append(
		&vertices,
		sdl.Vertex{{rect.x + clamped_radius, rect.y + rect.h - clamped_radius}, color, {0, 1}},
	)

	append(&indices, 0)
	append(&indices, 1)
	append(&indices, 3)
	append(&indices, 1)
	append(&indices, 2)
	append(&indices, 3)

	step := math.PI / c.float(num_circle_segments)
	for i in 0 ..< num_circle_segments {
		i := c.float(i)
		angle_1 := i * step
		angle_2 := (i + 1) * step

		for j in 0 ..< 4 {
			cx, cy, signx, signy: c.float

			switch j {
			case 0:
				cx = rect.x + clamped_radius
				cy = rect.y + clamped_radius
				signx = -1
				signy = -1
			case 1:
				cx = rect.x + rect.w - clamped_radius
				cy = rect.y + clamped_radius
				signx = 1
				signy = -1
			case 2:
				cx = rect.x + rect.w - clamped_radius
				cy = rect.y + rect.h - clamped_radius
				signx = 1
				signy = 1
			case 3:
				cx = rect.x + clamped_radius
				cy = rect.y + rect.h - clamped_radius
				signx = -1
				signy = 1
			}

			append(
				&vertices,
				sdl.Vertex {
					{
						cx + math.cos(angle_1) * clamped_radius * signx,
						cy + math.sin(angle_1) * clamped_radius * signy,
					},
					color,
					{0, 0},
				},
			)
			append(
				&vertices,
				sdl.Vertex {
					{
						cx + math.cos(angle_2) * clamped_radius * signx,
						cy + math.sin(angle_2) * clamped_radius * signy,
					},
					color,
					{0, 0},
				},
			)

			append(&indices, c.int(j))
			append(&indices, c.int(len(vertices) - 2))
			append(&indices, c.int(len(vertices) - 1))
		}
	}

	append(&vertices, sdl.Vertex{{rect.x + clamped_radius, rect.y}, color, {0, 0}})
	append(&vertices, sdl.Vertex{{rect.x + rect.w - clamped_radius, rect.y}, color, {1, 0}})
	append(&indices, 0)
	append(&indices, c.int(len(vertices) - 2))
	append(&indices, c.int(len(vertices) - 1))
	append(&indices, 1)
	append(&indices, 0)
	append(&indices, c.int(len(vertices) - 1))

	append(&vertices, sdl.Vertex{{rect.x + rect.w, rect.y + clamped_radius}, color, {1, 0}})
	append(
		&vertices,
		sdl.Vertex{{rect.x + rect.w, rect.y + rect.h - clamped_radius}, color, {1, 1}},
	)
	append(&indices, 1)
	append(&indices, c.int(len(vertices) - 2))
	append(&indices, c.int(len(vertices) - 1))
	append(&indices, 2)
	append(&indices, 1)
	append(&indices, c.int(len(vertices) - 1))

	append(
		&vertices,
		sdl.Vertex{{rect.x + rect.w - clamped_radius, rect.y + rect.h}, color, {1, 1}},
	)
	append(&vertices, sdl.Vertex{{rect.x + clamped_radius, rect.y + rect.h}, color, {0, 1}})
	append(&indices, 2)
	append(&indices, c.int(len(vertices) - 2))
	append(&indices, c.int(len(vertices) - 1))
	append(&indices, 3)
	append(&indices, 2)
	append(&indices, c.int(len(vertices) - 1))

	append(&vertices, sdl.Vertex{{rect.x, rect.y + rect.h - clamped_radius}, color, {0, 1}})
	append(&vertices, sdl.Vertex{{rect.x, rect.y + clamped_radius}, color, {0, 0}})
	append(&indices, 3)
	append(&indices, c.int(len(vertices) - 2))
	append(&indices, c.int(len(vertices) - 1))
	append(&indices, 0)
	append(&indices, 3)
	append(&indices, c.int(len(vertices) - 1))

	sdl.RenderGeometry(
		ctx.renderer,
		nil,
		raw_data(vertices),
		c.int(len(vertices)),
		raw_data(indices),
		c.int(len(indices)),
	)
}

clay_sdl_renderarc :: proc(
	ctx: UI_Context,
	center: sdl.FPoint,
	radius, start_angle, end_angle, thickness: c.float,
	color: clay.Color,
	allocator := context.temp_allocator,
) {
	sdl.SetRenderDrawColor(ctx.renderer, u8(color.r), u8(color.g), u8(color.b), u8(color.a))

	rad_start := math.to_radians(start_angle)
	rad_end := math.to_radians(start_angle)

	num_circle_segments := max(NUM_CIRCLE_SEGMENTS, int(radius * 1.5))

	angle_step := (rad_end - rad_start) / c.float(num_circle_segments)
	thickness_step :: 0.4

	points := make([]sdl.FPoint, num_circle_segments + 1, allocator)
	for t: c.float = thickness_step; t < thickness - thickness_step; t += thickness_step {
		clamped_radius := max(radius - t, 1)
		for i in 0 ..< num_circle_segments {
			angle := rad_start + c.float(i) * angle_step
			points[i] = {
				math.round(center.x + math.cos(angle) * clamped_radius),
				math.round(center.y + math.sin(angle) * clamped_radius),
			}
		}

		sdl.RenderLines(ctx.renderer, raw_data(points), c.int(len(points)))
	}
}
