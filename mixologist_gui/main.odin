package mixologist_gui

import "./clay"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:text/edit"
import "vendor:sdl2"
import "vendor:sdl2/ttf"

KeyState :: enum u8 {
	PRESSED,
	HELD,
	RELEASED,
}

KeyStates :: bit_set[KeyState]

Context :: struct {
	textbox_input:  strings.Builder,
	textbox_state:  edit.State,
	textbox_offset: int,
	keyboard:       map[sdl2.Keycode]KeyStates,
	debug_mode:     bool,
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
	defer delete(ctx.keyboard)

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

	dt: c.float
	last: u64
	now := sdl2.GetPerformanceCounter()
	mainloop: for !sdl2.QuitRequested() {
		for _, &state in ctx.keyboard {
			if state == {.RELEASED} do state = {}
		}

		event: sdl2.Event
		scroll_delta: clay.Vector2
		for sdl2.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				break mainloop
			case .MOUSEWHEEL:
				scroll_delta += {c.float(event.wheel.x), c.float(event.wheel.y)} * 5
			case .KEYDOWN:
				key := event.key.keysym.sym
				if .HELD in ctx.keyboard[key] {
					ctx.keyboard[key] -= {.PRESSED}
				} else {
					ctx.keyboard[key] += {.PRESSED, .HELD}
				}
			case .KEYUP:
				key := event.key.keysym.sym
				ctx.keyboard[key] = {.RELEASED}
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

		when ODIN_DEBUG {
			if .HELD in ctx.keyboard[sdl2.Keycode.LCTRL] &&
			   .RELEASED in ctx.keyboard[sdl2.Keycode.d] {
				ctx.debug_mode = !ctx.debug_mode
				clay.SetDebugModeEnabled(ctx.debug_mode)
			}
		}

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
					layoutDirection = .TOP_TO_BOTTOM,
					sizing = {clay.SizingPercent(0.8), clay.SizingGrow({})},
				},
			),
			clay.Scroll({vertical = true}),
			clay.Rectangle({color = BASE, cornerRadius = clay.CornerRadiusAll(5)}),
		) {
			for i in 0 ..< 100 {
				str := fmt.tprintf("this is a test %d", i)
				clay.Text(str, clay.TextConfig({textColor = TEXT, fontSize = 32}))
			}
		}
	}

	return clay.EndLayout()
}
