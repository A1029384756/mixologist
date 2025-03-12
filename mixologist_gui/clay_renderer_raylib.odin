package mixologist_gui

import clay "./clay"
import "./raylib"
import "base:runtime"
import "core:c"
import sa "core:container/small_array"
import "core:math"
import "core:strings"

RaylibFont :: struct {
	font:      map[u16]raylib.Font,
	bytes:     []u8,
	extension: cstring,
}

clayColorToRaylibColor :: proc(color: clay.Color) -> raylib.Color {
	return raylib.Color{cast(u8)color.r, cast(u8)color.g, cast(u8)color.b, cast(u8)color.a}
}

raylibFonts: sa.Small_Array(16, RaylibFont)

retrieve_font :: proc(id, size: u16) -> raylib.Font {
	rlfont := sa.get_ptr(&raylibFonts, int(id))
	font_size, font, just_inserted, err := map_entry(&rlfont.font, size)
	if just_inserted {
		font^ = raylib.LoadFontFromMemory(
			rlfont.extension,
			raw_data(rlfont.bytes),
			c.int(len(rlfont.bytes)),
			c.int(size * 2),
			nil,
			0,
		)
		raylib.SetTextureFilter(font.texture, .TRILINEAR)
	}
	return font^
}

measureText :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userdata: rawptr,
) -> (
	textSize: clay.Dimensions,
) {
	context = runtime.default_context()
	maxTextWidth: f32 = 0
	lineTextWidth: f32 = 0

	textHeight := cast(f32)config.fontSize
	fontToUse := retrieve_font(config.fontId, config.fontSize)

	for i in 0 ..< int(text.length) {
		if (text.chars[i] == '\n') {
			maxTextWidth = max(maxTextWidth, lineTextWidth)
			lineTextWidth = 0
			continue
		}
		index := cast(i32)text.chars[i] - 32
		if (fontToUse.glyphs[index].advanceX != 0) {
			lineTextWidth += cast(f32)fontToUse.glyphs[index].advanceX
		} else {
			lineTextWidth +=
				(fontToUse.recs[index].width + cast(f32)fontToUse.glyphs[index].offsetX)
		}
	}

	maxTextWidth = max(maxTextWidth, lineTextWidth)

	textSize.width = maxTextWidth / 2
	textSize.height = textHeight

	return textSize
}

clayRaylibRender :: proc(
	renderCommands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	for i in 0 ..< int(renderCommands.length) {
		renderCommand := clay.RenderCommandArray_Get(renderCommands, cast(i32)i)
		boundingBox := renderCommand.boundingBox
		switch (renderCommand.commandType) {
		case clay.RenderCommandType.None:
			{}
		case clay.RenderCommandType.Text:
			// Raylib uses standard C strings so isn't compatible with cheap slices, we need to clone the string to append null terminator
			config := renderCommand.renderData.text
			text := string(config.stringContents.chars[:config.stringContents.length])
			cloned := strings.clone_to_cstring(text, allocator)
			fontToUse := retrieve_font(config.fontId, config.fontSize)
			raylib.DrawTextEx(
				fontToUse,
				cloned,
				raylib.Vector2{boundingBox.x, boundingBox.y},
				cast(f32)config.fontSize,
				cast(f32)config.letterSpacing,
				clayColorToRaylibColor(config.textColor),
			)
		case clay.RenderCommandType.Image:
			config := renderCommand.renderData.image
			tintColor := config.backgroundColor
			if (tintColor.rgba == 0) {
				tintColor = {255, 255, 255, 255}
			}
			imageTexture := cast(^raylib.Texture2D)config.imageData
			raylib.DrawTextureEx(
				imageTexture^,
				raylib.Vector2{boundingBox.x, boundingBox.y},
				0,
				boundingBox.width / cast(f32)imageTexture.width,
				clayColorToRaylibColor(tintColor),
			)
		case clay.RenderCommandType.ScissorStart:
			raylib.BeginScissorMode(
				cast(i32)math.round(boundingBox.x),
				cast(i32)math.round(boundingBox.y),
				cast(i32)math.round(boundingBox.width),
				cast(i32)math.round(boundingBox.height),
			)
		case clay.RenderCommandType.ScissorEnd:
			raylib.EndScissorMode()
		case clay.RenderCommandType.Rectangle:
			config := renderCommand.renderData.rectangle
			if (config.cornerRadius.topLeft > 0) {
				radius: f32 =
					(config.cornerRadius.topLeft * 2) / min(boundingBox.width, boundingBox.height)
				raylib.DrawRectangleRounded(
					raylib.Rectangle {
						boundingBox.x,
						boundingBox.y,
						boundingBox.width,
						boundingBox.height,
					},
					radius,
					8,
					clayColorToRaylibColor(config.backgroundColor),
				)
			} else {
				raylib.DrawRectangle(
					cast(i32)boundingBox.x,
					cast(i32)boundingBox.y,
					cast(i32)boundingBox.width,
					cast(i32)boundingBox.height,
					clayColorToRaylibColor(config.backgroundColor),
				)
			}
		case clay.RenderCommandType.Border:
			config := renderCommand.renderData.border
			// Left border
			if (config.width.left > 0) {
				raylib.DrawRectangle(
					cast(i32)math.round(boundingBox.x),
					cast(i32)math.round(boundingBox.y + config.cornerRadius.topLeft),
					cast(i32)config.width.left,
					cast(i32)math.round(
						boundingBox.height -
						config.cornerRadius.topLeft -
						config.cornerRadius.bottomLeft,
					),
					clayColorToRaylibColor(config.color),
				)
			}
			// Right border
			if (config.width.right > 0) {
				raylib.DrawRectangle(
					cast(i32)math.round(
						boundingBox.x + boundingBox.width - cast(f32)config.width.right,
					),
					cast(i32)math.round(boundingBox.y + config.cornerRadius.topRight),
					cast(i32)config.width.right,
					cast(i32)math.round(
						boundingBox.height -
						config.cornerRadius.topRight -
						config.cornerRadius.bottomRight,
					),
					clayColorToRaylibColor(config.color),
				)
			}
			// Top border
			if (config.width.top > 0) {
				raylib.DrawRectangle(
					cast(i32)math.round(boundingBox.x + config.cornerRadius.topLeft),
					cast(i32)math.round(boundingBox.y),
					cast(i32)math.round(
						boundingBox.width -
						config.cornerRadius.topLeft -
						config.cornerRadius.topRight,
					),
					cast(i32)config.width.top,
					clayColorToRaylibColor(config.color),
				)
			}
			// Bottom border
			if (config.width.bottom > 0) {
				raylib.DrawRectangle(
					cast(i32)math.round(boundingBox.x + config.cornerRadius.bottomLeft),
					cast(i32)math.round(
						boundingBox.y + boundingBox.height - cast(f32)config.width.bottom,
					),
					cast(i32)math.round(
						boundingBox.width -
						config.cornerRadius.bottomLeft -
						config.cornerRadius.bottomRight,
					),
					cast(i32)config.width.bottom,
					clayColorToRaylibColor(config.color),
				)
			}
			if (config.cornerRadius.topLeft > 0) {
				raylib.DrawRing(
					raylib.Vector2 {
						math.round(boundingBox.x + config.cornerRadius.topLeft),
						math.round(boundingBox.y + config.cornerRadius.topLeft),
					},
					math.round(config.cornerRadius.topLeft - cast(f32)config.width.top),
					config.cornerRadius.topLeft,
					180,
					270,
					10,
					clayColorToRaylibColor(config.color),
				)
			}
			if (config.cornerRadius.topRight > 0) {
				raylib.DrawRing(
					raylib.Vector2 {
						math.round(
							boundingBox.x + boundingBox.width - config.cornerRadius.topRight,
						),
						math.round(boundingBox.y + config.cornerRadius.topRight),
					},
					math.round(config.cornerRadius.topRight - cast(f32)config.width.top),
					config.cornerRadius.topRight,
					270,
					360,
					10,
					clayColorToRaylibColor(config.color),
				)
			}
			if (config.cornerRadius.bottomLeft > 0) {
				raylib.DrawRing(
					raylib.Vector2 {
						math.round(boundingBox.x + config.cornerRadius.bottomLeft),
						math.round(
							boundingBox.y + boundingBox.height - config.cornerRadius.bottomLeft,
						),
					},
					math.round(config.cornerRadius.bottomLeft - cast(f32)config.width.top),
					config.cornerRadius.bottomLeft,
					90,
					180,
					10,
					clayColorToRaylibColor(config.color),
				)
			}
			if (config.cornerRadius.bottomRight > 0) {
				raylib.DrawRing(
					raylib.Vector2 {
						math.round(
							boundingBox.x + boundingBox.width - config.cornerRadius.bottomRight,
						),
						math.round(
							boundingBox.y + boundingBox.height - config.cornerRadius.bottomRight,
						),
					},
					math.round(config.cornerRadius.bottomRight - cast(f32)config.width.bottom),
					config.cornerRadius.bottomRight,
					0.1,
					90,
					10,
					clayColorToRaylibColor(config.color),
				)
			}
		case clay.RenderCommandType.Custom:
		// Implement custom element rendering here
		}
	}
}
