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

	font_system_init()
	font_system_register(#load("resources/Roboto-Regular.ttf"))
	defer font_system_deinit()

	window := sdl.CreateWindow(
		"Mixologist",
		sdl.WINDOWPOS_UNDEFINED,
		sdl.WINDOWPOS_UNDEFINED,
		800,
		600,
		{.RESIZABLE},
	)
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(window, 0, {.ACCELERATED, .PRESENTVSYNC})
	defer sdl.DestroyRenderer(renderer)
	sdl.SetWindowTitle(window, "Mixologist")

	min_mem := clay.MinMemorySize()
	memory := make([]u8, min_mem)
	defer delete(memory)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(memory))
	clay.SetMeasureTextFunction(clay_measure_text_sdl2)

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
