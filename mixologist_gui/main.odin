package mixologist_gui

import "./clay"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:text/edit"
import "vendor:sdl2"
import "vendor:sdl2/ttf"

ButtonState :: enum u8 {
	PRESSED,
	HELD,
	RELEASED,
}
ButtonStates :: bit_set[ButtonState]

Context :: struct {
	textbox_input:  strings.Builder,
	textbox_state:  edit.State,
	textbox_offset: int,
	keyboard:       map[sdl2.Keycode]ButtonStates,
	mouse:          [3]ButtonStates,
	mouse_pos:      [2]c.int,
	hovering:       bool,
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

cursors := [sdl2.SystemCursor]^sdl2.Cursor {
	.HAND               = nil,
	.ARROW              = nil,
	.NO                 = nil,
	.WAIT               = nil,
	.IBEAM              = nil,
	.SIZEWE             = nil,
	.SIZENS             = nil,
	.SIZEALL            = nil,
	.SIZENWSE           = nil,
	.SIZENESW           = nil,
	.CROSSHAIR          = nil,
	.WAITARROW          = nil,
	.NUM_SYSTEM_CURSORS = nil,
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

	for &cursor, system in cursors {
		cursor = sdl2.CreateSystemCursor(system)
	}
	defer {
		for cursor in cursors {
			sdl2.FreeCursor(cursor)
		}
	}

	dt: c.float
	last: u64
	now := sdl2.GetPerformanceCounter()
	mainloop: for !sdl2.QuitRequested() {
		ctx.hovering = false
		for _, &state in ctx.keyboard {
			if state == {.RELEASED} do state = {}
		}
		for &state in ctx.mouse {
			if .PRESSED in state do state -= {.PRESSED}
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
			case .MOUSEBUTTONDOWN:
				button := event.button.button
				switch button {
				case 1 ..= 3:
					ctx.mouse[button - 1] += {.PRESSED, .HELD}
				}
			case .MOUSEBUTTONUP:
				button := event.button.button
				switch button {
				case 1 ..= 3:
					ctx.mouse[button - 1] = {.RELEASED}
				}
			}
		}
		last = now
		now = sdl2.GetPerformanceCounter()
		dt = c.float(now - last) * 1000 / c.float(sdl2.GetPerformanceFrequency())

		sdl2.GetMouseState(&ctx.mouse_pos.x, &ctx.mouse_pos.y)

		mouse_pos := clay.Vector2{c.float(ctx.mouse_pos.x), c.float(ctx.mouse_pos.y)}
		clay.SetPointerState(mouse_pos, .PRESSED in ctx.mouse[0])
		clay.UpdateScrollContainers(false, scroll_delta, dt)

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
		if ctx.hovering do sdl2.SetCursor(cursors[.HAND])
		else do sdl2.SetCursor(cursors[.ARROW])

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
		str := fmt.tprintf("this is a test %d", idx)
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
				clay.Layout(
					{sizing = {clay.SizingFixed(16), clay.SizingFixed(16)}, padding = {16, 16}},
				),
				clay.Rectangle({color = clay.Hovered() ? RED : MAUVE}),
			) { fmt.println("clicked", idx) }
		}
	}
}
