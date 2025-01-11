package mixologist_gui

import "./clay"
import rl "./raylib"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:text/edit"

Context :: struct {
	textbox_input:  strings.Builder,
	textbox_state:  edit.State,
	textbox_offset: int,
	active_row:     Maybe(int),
	hovering:       bool,
	debug_mode:     bool,
}

rl_set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text)
	rl.SetClipboardText(text_cstr)
	delete(text_cstr)
	return true
}

rl_get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	text_cstr := rl.GetClipboardText()
	if text_cstr != nil {
		text = string(text_cstr)
		ok = true
	}
	return
}

load_font :: proc(fontId: u16, fontSize: u16, path: cstring) {
	raylibFonts[fontId] = RaylibFont {
		font   = rl.LoadFontEx(path, cast(i32)fontSize * 2, nil, 0),
		fontId = cast(u16)fontId,
	}
	rl.SetTextureFilter(raylibFonts[fontId].font.texture, rl.TextureFilter.TRILINEAR)
}

clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	context = runtime.default_context()
	fmt.println(
		"clay error detected of type: %v: %s",
		errordata.errorType,
		errordata.errorText.chars[:errordata.errorText.length],
	)
}

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(800, 600, "Mixologist")
	defer rl.CloseWindow()

	ctx: Context
	ctx.textbox_state.set_clipboard = rl_set_clipboard
	ctx.textbox_state.get_clipboard = rl_get_clipboard

	min_mem := clay.MinMemorySize()
	memory := make([]u8, min_mem)
	defer delete(memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(memory))
	clay.SetMeasureTextFunction(measureText)

	load_font(0, 16, "mixologist_gui/resources/Roboto-Regular.ttf")

	window_size := [2]c.int{rl.GetScreenWidth(), rl.GetScreenWidth()}
	clay.Initialize(
		arena,
		{c.float(window_size.x), c.float(window_size.y)},
		{handler = clay_error_handler},
	)

	mainloop: for !rl.WindowShouldClose() {
		ctx.hovering = false

		when ODIN_DEBUG {
			if rl.IsKeyPressed(.D) && rl.IsKeyDown(.LEFT_CONTROL) {
				ctx.debug_mode = !ctx.debug_mode
				clay.SetDebugModeEnabled(ctx.debug_mode)
			}
		}

		window_size = {rl.GetScreenWidth(), rl.GetScreenHeight()}
		clay.SetPointerState(
			transmute(clay.Vector2)rl.GetMousePosition(),
			rl.IsMouseButtonDown(.LEFT),
		)
		clay.UpdateScrollContainers(
			false,
			transmute(clay.Vector2)rl.GetMouseWheelMoveV() * 5,
			rl.GetFrameTime(),
		)
		clay.SetLayoutDimensions({cast(f32)rl.GetScreenWidth(), cast(f32)rl.GetScreenHeight()})
		renderCommands: clay.ClayArray(clay.RenderCommand) = create_layout(&ctx)
		rl.BeginDrawing()
		clayRaylibRender(&renderCommands)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}

create_layout :: proc(ctx: ^Context) -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI(
		clay.Layout(
			{
				layoutDirection = .TOP_TO_BOTTOM,
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				padding = {16, 16},
				childAlignment = {x = .CENTER, y = .CENTER},
			},
		),
		clay.Rectangle({color = BASE}),
	) {
		if clay.UI(
			clay.Layout(
				{
					layoutDirection = .TOP_TO_BOTTOM,
					sizing = {clay.SizingPercent(0.8), clay.SizingGrow({})},
				},
			),
			clay.Scroll({vertical = true}),
			clay.Rectangle({color = MANTLE, cornerRadius = clay.CornerRadiusAll(5)}),
		) {
			for i in 0 ..< 100 do rule_line(ctx, i)
		}
	}

	return clay.EndLayout()
}

rule_line :: proc(ctx: ^Context, idx: int) {
	if clay.UI(
		clay.Layout(
			{
				layoutDirection = .LEFT_TO_RIGHT,
				sizing = {clay.SizingPercent(1), clay.SizingFit({})},
				padding = {16, 16},
			},
		),
		clay.Rectangle({color = idx % 2 == 0 ? MANTLE : CRUST}),
	) {
		str: string
		if ctx.active_row != idx {
			str = fmt.tprintf("this is a test %d", idx)
		} else {
			str = fmt.tprintf("[active] this is a test %d", idx)
		}
		clay.Text(str, clay.TextConfig({textColor = TEXT, fontSize = 16}))

		if clay.UI(
			clay.Layout(
				{
					layoutDirection = .LEFT_TO_RIGHT,
					childAlignment = {x = .RIGHT, y = .CENTER},
					sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				},
			),
		) {
			if button(
				ctx,
				MAUVE,
				RED,
				clay.CornerRadiusAll(5),
				clay.Layout(
					{sizing = {clay.SizingFixed(16), clay.SizingFixed(16)}, padding = {16, 16}},
				),
			) {
				ctx.active_row = idx
			}
		}
	}
}
