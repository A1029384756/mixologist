package mixologist_gui

import "./clay"
import "core:c"
import "core:strings"
import "core:text/edit"
import "vendor:sdl2"
import "vendor:sdl2/ttf"

Context :: struct {
	textbox_input:  strings.Builder,
	textbox_state:  edit.State,
	textbox_offset: int,
}

sdl2_set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text)
	sdl2.SetClipboardText(text_cstr)
	delete(text_cstr)
	return true
}

sdl2_get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	if sdl2.HasClipboardText() {
		text = string(sdl2.GetClipboardText())
		ok = true
	}
	return
}

main :: proc() {
	sdl2.Init({.VIDEO})
	defer sdl2.Quit()

	ttf.Init()
	defer ttf.Quit()

	font_system_init()
	font_system_register(#load("resources/Roboto-Regular.ttf"))
	defer font_system_deinit()

	ctx: Context
	ctx.textbox_state.set_clipboard = sdl2_set_clipboard
	ctx.textbox_state.get_clipboard = sdl2_get_clipboard

	window := sdl2.CreateWindow(
		"Mixologist",
		sdl2.WINDOWPOS_UNDEFINED,
		sdl2.WINDOWPOS_UNDEFINED,
		800,
		600,
		{.RESIZABLE},
	)
	defer sdl2.DestroyWindow(window)

	renderer := sdl2.CreateRenderer(window, 0, {.ACCELERATED, .PRESENTVSYNC, .TARGETTEXTURE})
	defer sdl2.DestroyRenderer(renderer)
	sdl2.SetWindowTitle(window, "Mixologist")
	sdl2.SetRenderDrawBlendMode(renderer, .BLEND)

	min_mem := clay.MinMemorySize()
	memory := make([]u8, min_mem)
	defer delete(memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(memory))
	clay.SetMeasureTextFunction(clay_measure_text_sdl2)

	window_size: [2]c.int
	sdl2.GetWindowSize(window, &window_size.x, &window_size.y)
	clay.Initialize(
		arena,
		{c.float(window_size.x), c.float(window_size.y)},
		{handler = clay_error_handler},
	)
	when ODIN_DEBUG do clay.SetDebugModeEnabled(true)

	dt: c.float
	last: u64
	now := sdl2.GetPerformanceCounter()
	mainloop: for !sdl2.QuitRequested() {
		event: sdl2.Event
		scroll_delta: clay.Vector2
		for sdl2.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				break mainloop
			case .MOUSEWHEEL:
				scroll_delta += {c.float(event.wheel.x), c.float(event.wheel.y)}
			}
		}
		last = now
		now = sdl2.GetPerformanceCounter()
		dt = c.float(now - last) * 1000 / c.float(sdl2.GetPerformanceFrequency())

		mouse_pos_sdl: [2]c.int
		mouse_state := sdl2.GetMouseState(&mouse_pos_sdl.x, &mouse_pos_sdl.y)

		mouse_pos := clay.Vector2{c.float(mouse_pos_sdl.x), c.float(mouse_pos_sdl.y)}
		clay.SetPointerState(mouse_pos, (mouse_state & sdl2.BUTTON_LMASK) == 1)

		clay.UpdateScrollContainers(true, scroll_delta, dt)

		sdl2.GetWindowSize(window, &window_size.x, &window_size.y)
		clay.SetLayoutDimensions({c.float(window_size.x), c.float(window_size.y)})

		render_cmds := create_layout(&ctx)

		sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 0)
		sdl2.RenderClear(renderer)
		clay_render(renderer, &render_cmds)

		sdl2.RenderPresent(renderer)

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
		clay.Rectangle({color = CRUST}),
	) {
		if clay.UI(
			clay.Layout(
				{
					sizing = {clay.SizingPercent(1), clay.SizingPercent(1)},
					childAlignment = {x = .CENTER, y = .CENTER},
				},
			),
			clay.Rectangle({color = BASE, cornerRadius = clay.CornerRadiusAll(5)}),
		) {
			clay.Text("this is a test", clay.TextConfig({textColor = TEXT, fontSize = 32}))
		}
	}

	return clay.EndLayout()
}
