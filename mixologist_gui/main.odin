package mixologist_gui

import "./clay"
import "base:runtime"
import "core:c"
import "core:fmt"
import sdl "vendor:sdl2"
import "vendor:sdl2/ttf"

clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	context = runtime.default_context()
	fmt.println(
		"clay error detected of type: %v: %s",
		errordata.errorType,
		errordata.errorText.chars[:errordata.errorText.length],
	)
}

main :: proc() {
	sdl.Init({.VIDEO})
	defer sdl.Quit()

	ttf.Init()
	defer ttf.Quit()

	font := ttf.OpenFont("resources/Roboto-Regular.ttf", 16)
	defer ttf.CloseFont(font)
	register_font(font)

	window: ^sdl.Window
	renderer: ^sdl.Renderer
	sdl.CreateWindowAndRenderer(800, 600, {.RESIZABLE}, &window, &renderer)
	defer {
		sdl.DestroyRenderer(renderer)
		sdl.DestroyWindow(window)
	}

	min_mem := clay.MinMemorySize()
	memory := make([]u8, min_mem)
	defer delete(memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(memory))
	clay.SetMeasureTextFunction(measure_text_temp_alloc)

	window_size: [2]c.int
	sdl.GetWindowSize(window, &window_size.x, &window_size.y)
	clay.Initialize(
		arena,
		{c.float(window_size.x), c.float(window_size.y)},
		{handler = clay_error_handler},
	)

	dt: c.float
	last: u64
	now := sdl.GetPerformanceCounter()
	mainloop: for !sdl.QuitRequested() {
		event: sdl.Event
		scroll_delta: clay.Vector2
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				break mainloop
			case .MOUSEWHEEL:
				scroll_delta += {c.float(event.wheel.x), c.float(event.wheel.y)}
			}
		}
		last = now
		now = sdl.GetPerformanceCounter()
		dt = c.float(now - last) * 1000 / c.float(sdl.GetPerformanceFrequency())

		mouse_pos_sdl: [2]c.int
		mouse_state := sdl.GetMouseState(&mouse_pos_sdl.x, &mouse_pos_sdl.y)

		mouse_pos := clay.Vector2{c.float(mouse_pos_sdl.x), c.float(mouse_pos_sdl.y)}
		clay.SetPointerState(mouse_pos, (mouse_state & sdl.BUTTON_LMASK) == 1)

		clay.UpdateScrollContainers(true, scroll_delta, dt)

		sdl.GetWindowSize(window, &window_size.x, &window_size.y)
		clay.SetLayoutDimensions({c.float(window_size.x), c.float(window_size.y)})

		render_cmds := create_layout()

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
		sdl.RenderClear(renderer)
		clay_render(renderer, &render_cmds)

		sdl.RenderPresent(renderer)

		free_all(context.temp_allocator)
	}
}

create_layout :: proc() -> clay.ClayArray(clay.RenderCommand) {
	clay.BeginLayout()

	if clay.UI(
		clay.Layout(
			{
				layoutDirection = .TOP_TO_BOTTOM,
				padding = {100, 100},
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			},
		),
		clay.Rectangle({color = {244, 235, 230, 255}, cornerRadius = {10, 10, 10, 10}}),
	) {
		if clay.UI(
			clay.Layout({sizing = {clay.SizingFixed(100), clay.SizingFixed(100)}}),
			clay.Rectangle({color = {10, 24, 12, 255}, cornerRadius = {10, 10, 10, 10}}),
		) {}
	}

	return clay.EndLayout()
}
