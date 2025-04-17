package mixologist

import "./clay"
import "base:intrinsics"
import "base:runtime"
import "core:c"
import sa "core:container/small_array"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:text/edit"
import "core:time"
import ttf "sdl3_ttf"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

odin_context: runtime.Context

UI_Context :: struct {
	textbox_input:       strings.Builder,
	textbox_state:       edit.State,
	textbox_offset:      int,
	active_widgets:      sa.Small_Array(16, clay.ElementId),
	hovered_widget:      clay.ElementId,
	prev_hovered_widget: clay.ElementId,
	statuses:            UI_Context_Statuses,
	// input handling
	_text_store:         [1024]u8, // global text input per frame
	click_count:         int,
	// mouse
	prev_click_time:     time.Time,
	click_debounce:      time.Time,
	mouse_pressed:       UI_Mouse_Buttons,
	mouse_down:          UI_Mouse_Buttons,
	mouse_released:      UI_Mouse_Buttons,
	mouse_pos:           [2]c.float,
	mouse_prev_pos:      [2]c.float,
	mouse_delta:         [2]c.float,
	scroll_delta:        [2]c.float,
	// keyboard
	keys_pressed:        UI_Control_Keys,
	keys_down:           UI_Control_Keys,
	// allocated
	clay_memory:         []u8,
	font_allocator:      virtual.Arena,
	fonts:               sa.Small_Array(16, UI_Font),
	// sdl3
	window:              ^sdl.Window,
	start_time:          time.Time,
	prev_frame_time:     time.Time,
	prev_event_time:     time.Time,
	scaling:             c.float,
	tray:                ^sdl.Tray,
	tray_menu:           ^sdl.TrayMenu,
	tray_icon:           ^sdl.Surface,
	toggle_entry:        ^sdl.TrayEntry,
	exit_entry:          ^sdl.TrayEntry,
	// renderer
	device:              ^sdl.GPUDevice,
}

UI_Scrollbar_Data :: struct {
	click_origin: clay.Vector2,
	pos_origin:   clay.Vector2,
}

UI_Mouse_Button :: enum {
	LEFT,
	MIDDLE,
	RIGHT,
	SIDE_1,
	SIDE_2,
}
UI_Mouse_Buttons :: bit_set[UI_Mouse_Button]

UI_Control_Key :: enum {
	SHIFT,
	CTRL,
	ALT,
	BACKSPACE,
	DELETE,
	RETURN,
	ESCAPE,
	LEFT,
	RIGHT,
	HOME,
	END,
	A,
	X,
	C,
	V,
	D,
}
UI_Control_Keys :: bit_set[UI_Control_Key]

UI_DOUBLE_CLICK_INTERVAL :: 300 * time.Millisecond
UI_EVENT_DELAY :: 33 * time.Millisecond
DEBUG_LAYOUT_TIMER_INTERVAL :: time.Second
UI_DEBUG_PREV_TIME: time.Time

UI_Context_Status :: enum {
	DIRTY,
	EVENT,
	TEXTBOX_SELECTED,
	TEXTBOX_HOVERING,
	BUTTON_HOVERING,
	DOUBLE_CLICKED,
	TRIPLE_CLICKED,
	WINDOW_CLOSED,
	APP_EXIT,
}
UI_Context_Statuses :: bit_set[UI_Context_Status]

UI_WidgetResult :: enum {
	CHANGE,
	CANCEL,
	SUBMIT,
	PRESS,
	FOCUS,
	DOUBLE_PRESS,
	TRIPLE_PRESS,
	RELEASE,
	HOVER,
}
UI_WidgetResults :: bit_set[UI_WidgetResult]

UI_Font :: struct {
	font: map[u16]^ttf.Font,
	data: []u8,
}

UI_retrieve_font :: proc(ctx: ^UI_Context, id, size: u16) -> ^ttf.Font {
	sdl_font := sa.get_ptr(&ctx.fonts, int(id))
	_, font, just_inserted, _ := map_entry(&sdl_font.font, size)
	if just_inserted {
		font_stream := sdl.IOFromConstMem(raw_data(sdl_font.data), len(sdl_font.data))
		font^ = ttf.OpenFontIO(font_stream, true, c.float(size))
		ttf.SetFontSizeDPI(font^, f32(size), 72 * c.int(ctx.scaling), 72 * c.int(ctx.scaling))
	}
	return font^
}

TEXT_CURSOR: ^sdl.Cursor
HAND_CURSOR: ^sdl.Cursor
DEFAULT_CURSOR: ^sdl.Cursor

UI_init :: proc(ctx: ^UI_Context, minimized: bool) {
	odin_context = context
	arena_init_err := virtual.arena_init_growing(&ctx.font_allocator)
	if arena_init_err != nil do panic("font allocator initialization failed")

	ctx.textbox_state.set_clipboard = UI__set_clipboard
	ctx.textbox_state.get_clipboard = UI__get_clipboard
	ctx.textbox_input = strings.builder_from_bytes(ctx._text_store[:])
	ctx.start_time = time.now()

	min_mem := c.size_t(clay.MinMemorySize())
	ctx.clay_memory = make([]u8, min_mem)
	arena := clay.CreateArenaWithCapacityAndMemory(min_mem, raw_data(ctx.clay_memory))

	sdl.SetLogPriorities(.VERBOSE)
	sdl.SetLogOutputFunction(
		proc "c" (
			userdata: rawptr,
			category: sdl.LogCategory,
			priority: sdl.LogPriority,
			message: cstring,
		) {
			context = odin_context
			log.debugf("SDL {} [{}]: {}", category, priority, message)
		},
		nil,
	)
	_ = sdl.Init({.VIDEO})
	_ = ttf.Init()
	ctx.window = sdl.CreateWindow(
		"Mixologist",
		800,
		600,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY} + (minimized ? {.HIDDEN} : {}),
	)
	if minimized {
		ctx.statuses += {.WINDOW_CLOSED}
	}
	ctx.scaling = sdl.GetWindowDisplayScale(ctx.window)
	ctx.device = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil)
	_ = sdl.ClaimWindowForGPUDevice(ctx.device, ctx.window)
	Renderer_init(ctx)

	{
		ICON :: #load("../data/mixologist.svg")
		icon_io := sdl.IOFromConstMem(raw_data(ICON), len(ICON))
		ctx.tray_icon = img.Load_IO(icon_io, true)
		ctx.tray = sdl.CreateTray(ctx.tray_icon, "Mixologist")
		ctx.tray_menu = sdl.CreateTrayMenu(ctx.tray)

		ctx.toggle_entry = sdl.InsertTrayEntryAt(
			ctx.tray_menu,
			-1,
			(minimized ? "Open" : "Close"),
			{.BUTTON},
		)
		sdl.SetTrayEntryCallback(ctx.toggle_entry, UI_toggle_window, ctx)

		ctx.exit_entry = sdl.InsertTrayEntryAt(ctx.tray_menu, -1, "Quit Mixologist", {.BUTTON})
		sdl.SetTrayEntryCallback(ctx.exit_entry, UI__quit_application, ctx)
	}

	TEXT_CURSOR = sdl.CreateSystemCursor(.TEXT)
	HAND_CURSOR = sdl.CreateSystemCursor(.POINTER)
	DEFAULT_CURSOR = sdl.GetDefaultCursor()

	_ = sdl.StartTextInput(ctx.window)

	window_size: [2]c.int
	sdl.GetWindowSize(ctx.window, &window_size.x, &window_size.y)
	clay.Initialize(
		arena,
		{c.float(window_size.x), c.float(window_size.y)},
		{handler = UI__clay_error_handler},
	)

	clay.SetMeasureTextFunction(UI__measure_text, ctx)
	ctx.prev_event_time = time.now()
	ctx.prev_frame_time = time.now()
}

UI_deinit :: proc(ctx: ^UI_Context) {
	virtual.arena_destroy(&ctx.font_allocator)
	delete(ctx.clay_memory)

	sdl.DestroyTray(ctx.tray)

	Renderer_destroy(ctx)
	sdl.DestroyWindow(ctx.window)
}

UI_tick :: proc(
	ctx: ^UI_Context,
	ui_create_layout: proc(
		ctx: ^UI_Context,
		userdata: rawptr,
	) -> clay.ClayArray(clay.RenderCommand),
	userdata: rawptr,
) {
	// input reset
	{
		strings.builder_reset(&ctx.textbox_input)
		ctx.mouse_pressed = {}
		ctx.mouse_released = {}
		ctx.scroll_delta = {}
		ctx.keys_pressed = {}
		ctx.mouse_prev_pos = ctx.mouse_pos
		ctx.prev_hovered_widget, ctx.hovered_widget = ctx.hovered_widget, {}
		ctx.statuses -= {.EVENT, .TEXTBOX_HOVERING, .BUTTON_HOVERING}
	}

	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			ctx.statuses += {.APP_EXIT}
		case .WINDOW_CLOSE_REQUESTED:
			ctx.statuses += {.WINDOW_CLOSED}
			sdl.SetTrayEntryLabel(ctx.toggle_entry, "Open")
			sdl.HideWindow(ctx.window)
		case .WINDOW_DISPLAY_SCALE_CHANGED:
			ctx.statuses += {.EVENT}
			ctx.scaling = sdl.GetWindowDisplayScale(ctx.window)
		case .WINDOW_RESIZED:
			ctx.statuses += {.EVENT}
		case .MOUSE_MOTION:
			ctx.mouse_pos = {event.motion.x, event.motion.y}
		case .MOUSE_WHEEL:
			ctx.scroll_delta = {event.wheel.x, event.wheel.y}
		case .TEXT_INPUT:
			ctx.statuses += {.EVENT}
			strings.write_string(&ctx.textbox_input, string(event.text.text))
		case .MOUSE_BUTTON_UP, .MOUSE_BUTTON_DOWN:
			ctx.statuses += {.EVENT}
			fn := event.type == .MOUSE_BUTTON_UP ? UI__input_mouse_up : UI__input_mouse_down
			switch event.button.button {
			case 1:
				fn(ctx, .LEFT)
			case 2:
				fn(ctx, .MIDDLE)
			case 3:
				fn(ctx, .RIGHT)
			case 4:
				fn(ctx, .SIDE_1)
			case 5:
				fn(ctx, .SIDE_2)
			}
		case .KEY_UP, .KEY_DOWN:
			ctx.statuses += {.EVENT}
			fn := event.type == .KEY_UP ? UI__input_key_up : UI__input_key_down
			#partial switch event.key.scancode {
			case .LSHIFT, .RSHIFT:
				fn(ctx, .SHIFT)
			case .LCTRL, .RCTRL:
				fn(ctx, .CTRL)
			case .LALT, .RALT:
				fn(ctx, .ALT)
			case .RETURN, .KP_ENTER:
				fn(ctx, .RETURN)
			case .ESCAPE:
				fn(ctx, .ESCAPE)
			case .BACKSPACE:
				fn(ctx, .BACKSPACE)
			case .LEFT:
				fn(ctx, .LEFT)
			case .RIGHT:
				fn(ctx, .RIGHT)
			case .HOME:
				fn(ctx, .HOME)
			case .END:
				fn(ctx, .END)
			case .A:
				fn(ctx, .A)
			case .X:
				fn(ctx, .X)
			case .C:
				fn(ctx, .C)
			case .V:
				fn(ctx, .V)
			case .D:
				fn(ctx, .D)
			}
		}
	}

	// [INFO] sdl.WaitAndAcquireGPUSwapchainTexture will hang if
	// we do not return early
	if .WINDOW_CLOSED in ctx.statuses {
		return
	}

	if .LEFT in ctx.mouse_pressed {
		if time.since(ctx.prev_click_time) <= UI_DOUBLE_CLICK_INTERVAL {
			ctx.click_count += 1
		} else {
			ctx.click_count = 1
		}

		ctx.prev_click_time = time.now()

		if ctx.click_count == 2 {
			ctx.statuses += {.DOUBLE_CLICKED}
		} else if ctx.click_count == 3 {
			ctx.statuses -= {.DOUBLE_CLICKED}
			ctx.statuses += {.TRIPLE_CLICKED}
		}
	} else if time.since(ctx.prev_click_time) >= UI_DOUBLE_CLICK_INTERVAL {
		ctx.statuses -= {.DOUBLE_CLICKED, .TRIPLE_CLICKED}
	}

	when ODIN_DEBUG {
		if .D in ctx.keys_pressed && .CTRL in ctx.keys_down {
			clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
		}
	}

	clay.SetPointerState(ctx.mouse_pos, .LEFT in ctx.mouse_down)
	window_size: [2]c.int
	sdl.GetWindowSize(ctx.window, &window_size.x, &window_size.y)
	clay.SetLayoutDimensions({c.float(window_size.x), c.float(window_size.y)})

	when ODIN_DEBUG {
		layout_start := time.now()
	}

	// run layout twice to avoid 1-frame
	// delay of immediate mode
	renderCommands := ui_create_layout(ctx, userdata)
	{
		strings.builder_reset(&ctx.textbox_input)
		ctx.mouse_pressed = {}
		ctx.mouse_released = {}
		ctx.scroll_delta = {}
		ctx.keys_pressed = {}
		ctx.mouse_prev_pos = ctx.mouse_pos
	}

	// runs during second layout pass to prevent issues
	// with scroll container data from deleted rules
	clay.UpdateScrollContainers(
		false,
		ctx.scroll_delta * 5,
		c.float(time.since(ctx.prev_frame_time) / time.Second),
	)
	renderCommands = ui_create_layout(ctx, userdata)

	when ODIN_DEBUG {
		layout_time := time.since(layout_start)
		render_start := time.now()
	}

	if ctx.hovered_widget != ctx.prev_hovered_widget do ctx.statuses += {.EVENT}

	if ctx.statuses >= {.TEXTBOX_HOVERING, .TEXTBOX_SELECTED} {
		_ = sdl.SetCursor(TEXT_CURSOR)
	} else if .BUTTON_HOVERING in ctx.statuses || .TEXTBOX_HOVERING in ctx.statuses {
		_ = sdl.SetCursor(HAND_CURSOR)
	} else {
		_ = sdl.SetCursor(DEFAULT_CURSOR)
	}

	if .DIRTY in ctx.statuses {
		ctx.statuses -= {.DIRTY}
		ctx.statuses += {.EVENT}
	}
	if .EVENT in ctx.statuses {
		cmd_buffer := sdl.AcquireGPUCommandBuffer(ctx.device)
		Renderer_draw(ctx, cmd_buffer, &renderCommands)
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd_buffer)
		_ = sdl.WaitForGPUFences(ctx.device, true, &fence, 1)
		sdl.ReleaseGPUFence(ctx.device, fence)
		ctx.prev_event_time = time.now()
	}

	when ODIN_DEBUG {
		ctx.statuses += {.DIRTY}
		render_time := time.since(render_start)
		if clay.IsDebugModeEnabled() {
			if time.since(UI_DEBUG_PREV_TIME) > DEBUG_LAYOUT_TIMER_INTERVAL {
				fmt.printfln(
					"FPS: %.2f",
					1 / time.duration_seconds(time.since(ctx.prev_frame_time)),
				)
				fmt.println("Layout time:", layout_time)
				fmt.println("Render time:", render_time)
				fmt.println("Mouse pos:", ctx.mouse_pos)
				fmt.println("Mouse down:", ctx.mouse_down)
				fmt.println("Mouse scroll:", ctx.scroll_delta)
				fmt.println("Display scale:", ctx.scaling)
				fmt.println("Statuses:", ctx.statuses)
				UI_DEBUG_PREV_TIME = time.now()
			}
		}
	}

	ctx.prev_frame_time = time.now()
}

UI_open_window :: proc(ctx: ^UI_Context) {
	ctx.statuses -= {.WINDOW_CLOSED}
	ctx.statuses += {.DIRTY}
	sdl.SetTrayEntryLabel(ctx.toggle_entry, "Close")
	sdl.ShowWindow(ctx.window)
	sdl.RaiseWindow(ctx.window)
}

UI_close_window :: proc(ctx: ^UI_Context) {
	ctx.statuses += {.WINDOW_CLOSED}
	sdl.HideWindow(ctx.window)
}

UI_toggle_window :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	ctx := cast(^UI_Context)userdata
	context = odin_context
	if .WINDOW_CLOSED in ctx.statuses {
		sdl.SetTrayEntryLabel(entry, "Close")
		UI_open_window(ctx)
	} else {
		sdl.SetTrayEntryLabel(entry, "Open")
		UI_close_window(ctx)
	}
}

UI__quit_application :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	ctx := cast(^UI_Context)userdata
	ctx.statuses += {.APP_EXIT}
}

UI__measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	if text.length == 0 do return {0, 0}

	context = odin_context
	ctx := cast(^UI_Context)userData
	font := UI_retrieve_font(ctx, config.fontId, u16(c.float(config.fontSize) * ctx.scaling))

	size: [2]c.int
	ttf.GetStringSize(font, cstring(text.chars), c.size_t(text.length), &size.x, &size.y)
	return {c.float(size.x) / ctx.scaling, c.float(size.y) / ctx.scaling}
}

UI__input_key_down :: proc(ctx: ^UI_Context, key: UI_Control_Key) {
	ctx.keys_down += {key}
	ctx.keys_pressed += {key}
}

UI__input_key_up :: proc(ctx: ^UI_Context, key: UI_Control_Key) {
	ctx.keys_down -= {key}
}

UI__input_mouse_down :: proc(ctx: ^UI_Context, button: UI_Mouse_Button) {
	ctx.mouse_down += {button}
	ctx.mouse_pressed += {button}
}

UI__input_mouse_up :: proc(ctx: ^UI_Context, button: UI_Mouse_Button) {
	ctx.mouse_down -= {button}
	ctx.mouse_released += {button}
}

UI_widget_active :: proc(ctx: ^UI_Context, id: clay.ElementId) -> bool {
	return slice.contains(sa.slice(&ctx.active_widgets), id)
}

UI_widget_focus :: proc(ctx: ^UI_Context, id: clay.ElementId) {
	if !slice.contains(sa.slice(&ctx.active_widgets), id) do sa.append(&ctx.active_widgets, id)
}

UI_status_add :: proc(ctx: ^UI_Context, statuses: UI_Context_Statuses) {
	ctx.statuses += statuses
}

UI_textbox_reset :: proc(ctx: ^UI_Context, textlen: int) {
	ctx.textbox_state.selection = {textlen, textlen}
}

UI_unfocus :: proc(ctx: ^UI_Context, id: clay.ElementId) {
	idx, found := slice.linear_search(sa.slice(&ctx.active_widgets), id)
	if found do sa.unordered_remove(&ctx.active_widgets, idx)
}

UI_unfocus_all :: proc(ctx: ^UI_Context) {
	sa.clear(&ctx.active_widgets)
}

UI_window_closed :: proc(ctx: ^UI_Context) -> bool {
	return .WINDOW_CLOSED in ctx.statuses
}

UI_should_exit :: proc(ctx: ^UI_Context) -> bool {
	return .APP_EXIT in ctx.statuses
}

UI_exit :: proc(ctx: ^UI_Context) {
	ctx.statuses += {.APP_EXIT}
}

UI_load_font_mem :: proc(ctx: ^UI_Context, fontsize: u16, data: []u8) -> u16 {
	font_stream := sdl.IOFromConstMem(raw_data(data), len(data))
	font := ttf.OpenFontIO(font_stream, true, c.float(fontsize))
	assert(font != nil)

	font_map := make(map[u16]^ttf.Font, 16, virtual.arena_allocator(&ctx.font_allocator))
	font_map[fontsize] = font
	ui_font := UI_Font {
		font = font_map,
		data = data,
	}

	sa.append(&ctx.fonts, ui_font)
	return u16(sa.len(ctx.fonts) - 1)
}

UI_load_font :: proc(ctx: ^UI_Context, fontsize: u16, path: cstring) -> u16 {
	unimplemented()
}

UI__set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text)
	sdl.SetClipboardText(text_cstr)
	delete(text_cstr)
	return true
}

UI__get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	text_cstr := cstring(sdl.GetClipboardText())
	if text_cstr != nil {
		text = string(text_cstr)
		ok = true
	}
	return
}

UI__clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	// [TODO] find out why `ID_LOCAL` is producing duplicate id errors
	// context = runtime.default_context()
	// fmt.printfln("clay error detected: %s", errordata.errorText.chars[:errordata.errorText.length])
}

UI_scrollbar :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^UI_Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__scrollbar(
		ctx,
		scroll_container_data,
		scrollbar_data,
		bar_width,
		bar_color,
		target_color,
		hover_color,
		press_color,
	)

	active := UI_widget_active(ctx, id)
	if .PRESS in res {
		UI_widget_focus(ctx, id)
		if !active {
			res += {.FOCUS}
			scrollbar_data.click_origin = ctx.mouse_pos
			scrollbar_data.pos_origin = scroll_container_data.scrollPosition^
		}
		active = true
	}
	if active && .LEFT in ctx.mouse_down {
		if time.since(ctx.prev_event_time) > UI_EVENT_DELAY do ctx.statuses += {.EVENT}
		res += {.CHANGE}

		data := clay.GetElementData(id)
		element_pos := [2]c.float{data.boundingBox.x, data.boundingBox.y}

		target_height := int(
			(scroll_container_data.scrollContainerDimensions.height /
				scroll_container_data.contentDimensions.height) *
			scroll_container_data.scrollContainerDimensions.height,
		)

		ratio := clay.Vector2 {
			scroll_container_data.contentDimensions.width /
			scroll_container_data.scrollContainerDimensions.width,
			scroll_container_data.contentDimensions.height /
			scroll_container_data.scrollContainerDimensions.height,
		}
		scroll_pos := (element_pos - ctx.mouse_pos) * ratio
		scroll_pos.y += (c.float(target_height) * ratio.y) / 2

		scroll_pos.x = clamp(
			scroll_pos.x,
			-(scroll_container_data.contentDimensions.width -
				scroll_container_data.scrollContainerDimensions.width),
			0,
		)
		scroll_pos.y = clamp(
			scroll_pos.y,
			-(scroll_container_data.contentDimensions.height -
				scroll_container_data.scrollContainerDimensions.height),
			0,
		)

		scroll_container_data.scrollPosition^ = scroll_pos
	} else if .LEFT not_in ctx.mouse_down do UI_unfocus(ctx, id)

	return
}

UI_textbox :: proc(
	ctx: ^UI_Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
	enabled := true,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__textbox(ctx, buf, textlen, placeholder_text, config, border_config, text_config)

	if enabled {
		active := UI_widget_active(ctx, id)
		if .PRESS in res {
			UI_widget_focus(ctx, id)
			ctx.statuses += {.TEXTBOX_SELECTED}
			if !active {
				res += {.FOCUS}
			}
		}

		if .HOVER in res do ctx.statuses += {.TEXTBOX_HOVERING}

		if active {
			if .CANCEL in res do UI_unfocus(ctx, id)
			if .SUBMIT in res && textlen^ > 0 do UI_unfocus(ctx, id)
		}
	}
	if .HOVER not_in res && .LEFT in ctx.mouse_pressed do UI_unfocus(ctx, id)
	return
}

UI_slider :: proc(
	ctx: ^UI_Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	snap_threshhold: T,
	notches: ..T,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	res, id = UI__slider(
		ctx,
		pos,
		default_val,
		min_val,
		max_val,
		color,
		hover_color,
		press_color,
		line_color,
		line_highlight,
		{sizing = {clay.SizingGrow({}), clay.SizingFixed(16)}},
		..notches,
	)

	active := UI_widget_active(ctx, id)
	if .PRESS in res {
		UI_widget_focus(ctx, id)
		if !active do res += {.FOCUS}
	}
	if active && .LEFT in ctx.mouse_down do res += {.CHANGE}

	if .HOVER not_in res && .LEFT in ctx.mouse_pressed do UI_unfocus(ctx, id)
	if .LEFT in ctx.mouse_released do UI_unfocus(ctx, id)

	for notch in notches {
		if abs(pos^ - notch) < snap_threshhold {
			pos^ = notch
			break
		}
	}

	if .CHANGE in res && time.since(ctx.prev_event_time) > UI_EVENT_DELAY do ctx.statuses += {.EVENT}
	return
}

UI_text_button :: proc(
	ctx: ^UI_Context,
	text: string,
	layout: clay.LayoutConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color, text_color: clay.Color,
	text_size: u16,
	text_padding: u16,
	enabled := true,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	res, id = UI__text_button(
		ctx,
		text,
		layout,
		corner_radius,
		enabled ? color : color * {0.65, 0.65, 0.65, 1},
		enabled ? hover_color : color * {0.65, 0.65, 0.65, 1},
		enabled ? press_color : color * {0.65, 0.65, 0.65, 1},
		text_color,
		text_size,
		text_padding,
	)

	if enabled {
		if .HOVER in res do ctx.statuses += {.BUTTON_HOVERING}
		else do UI_unfocus(ctx, id)

		if .PRESS in res do UI_widget_focus(ctx, id)
		else if .RELEASE in res do UI_unfocus(ctx, id)
	}
	return
}

UI__scrollbar :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^UI_Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	local_id := clay.ID_LOCAL(#procedure)
	id = local_id

	bar_width := bar_width
	if scroll_container_data.contentDimensions.height <= scroll_container_data.scrollContainerDimensions.height do bar_width = 0
	if clay.UI()(
	{
		layout = {sizing = {clay.SizingFixed(c.float(bar_width)), clay.SizingGrow({})}},
		floating = {attachment = {element = .RightTop, parent = .RightTop}, attachTo = .Parent},
		backgroundColor = bar_color,
		id = local_id,
	},
	) {
		scroll_res, scroll_id := UI__scroll_target(
			ctx,
			scroll_container_data,
			bar_width,
			target_color,
			hover_color,
			press_color,
		)

		scroll_active := UI_widget_active(ctx, scroll_id)
		if .PRESS in scroll_res {
			UI_widget_focus(ctx, scroll_id)
			if !scroll_active {
				res += {.FOCUS}
				scrollbar_data.click_origin = ctx.mouse_pos
				scrollbar_data.pos_origin = scroll_container_data.scrollPosition^
			}
			scroll_active = true
		}
		if scroll_active {
			if time.since(ctx.prev_event_time) > UI_EVENT_DELAY do ctx.statuses += {.EVENT}
			scroll_res += {.CHANGE}

			ratio := clay.Vector2 {
				scroll_container_data.contentDimensions.width /
				scroll_container_data.scrollContainerDimensions.width,
				scroll_container_data.contentDimensions.height /
				scroll_container_data.scrollContainerDimensions.height,
			}

			scroll_pos :=
				scrollbar_data.pos_origin + (scrollbar_data.click_origin - ctx.mouse_pos) * ratio
			scroll_pos.x = clamp(
				scroll_pos.x,
				-(scroll_container_data.contentDimensions.width -
					scroll_container_data.scrollContainerDimensions.width),
				0,
			)
			scroll_pos.y = clamp(
				scroll_pos.y,
				-(scroll_container_data.contentDimensions.height -
					scroll_container_data.scrollContainerDimensions.height),
				0,
			)

			scroll_container_data.scrollPosition^ = scroll_pos
		}
		if .LEFT in ctx.mouse_released do UI_unfocus(ctx, scroll_id)

		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if .LEFT in ctx.mouse_released do res += {.RELEASE}
	}
	return
}

UI__scroll_target :: proc(
	ctx: ^UI_Context,
	scroll_container_data: clay.ScrollContainerData,
	width: int,
	color, hover_color, press_color: clay.Color,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	target_height := int(
		(scroll_container_data.scrollContainerDimensions.height /
			scroll_container_data.contentDimensions.height) *
		scroll_container_data.scrollContainerDimensions.height,
	)
	size := [2]int{width, target_height}

	if clay.UI()(
	{
		floating = {
			offset = {
				0,
				-(scroll_container_data.scrollPosition.y /
					scroll_container_data.contentDimensions.height) *
				scroll_container_data.scrollContainerDimensions.height,
			},
			attachment = {element = .RightTop, parent = .RightTop},
			attachTo = .Parent,
		},
	},
	) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingFixed(c.float(size.x)), clay.SizingFixed(c.float(size.y))},
			},
		},
		) {
			active := UI_widget_active(ctx, local_id)
			selected_color := color
			if active do selected_color = press_color
			else if clay.Hovered() do selected_color = hover_color

			if clay.Hovered() do ctx.hovered_widget = id
			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
			if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

			if clay.UI()(
			{
				layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}},
				backgroundColor = selected_color,
				cornerRadius = clay.CornerRadiusAll(c.float(size.x) / 2),
			},
			) {
			}
		}
	}
	return
}

UI__textbox :: proc(
	ctx: ^UI_Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	config := config
	border_config := border_config
	text_config := clay.TextConfig(text_config)

	if clay.UI()({layout = {sizing = config.layout.sizing}}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, local_id)
		if !active do border_config.width = {}
		if !active do config.backgroundColor *= {0.8, 0.8, 0.8, 1}
		config.border = border_config
		config.layout.sizing = {clay.SizingGrow({}), clay.SizingGrow({})}


		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

		if clay.UI()(config) {
			if clay.UI()(
			{
				id = local_id,
				layout = {
					sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
					childAlignment = {y = .Center},
				},
				scroll = {horizontal = active},
			},
			) {
				elem_loc_data := clay.GetElementData(local_id)
				boundingbox := elem_loc_data.boundingBox

				if active {
					builder := strings.builder_from_bytes(buf)
					non_zero_resize(&builder.buf, textlen^)
					ctx.textbox_state.builder = &builder

					textbox_selected: bool
					for widget in sa.slice(&ctx.active_widgets) {
						if ctx.textbox_state.id == u64(widget.id) {
							textbox_selected = true
							break
						}
					}

					if !textbox_selected {
						ctx.textbox_state.id = u64(local_id.id)
						ctx.textbox_state.selection = {}
						edit.move_to(&ctx.textbox_state, .End)
					}

					if ctx.textbox_state.selection[0] > textlen^ ||
					   ctx.textbox_state.selection[1] > textlen^ {
						ctx.textbox_state.selection = {}
					}

					if strings.builder_len(ctx.textbox_input) > 0 {
						if edit.input_text(
							   &ctx.textbox_state,
							   strings.to_string(ctx.textbox_input),
						   ) >
						   0 {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if .A in ctx.keys_pressed &&
					   .CTRL in ctx.keys_down &&
					   .ALT not_in ctx.keys_down {
						ctx.textbox_state.selection = {textlen^, 0}
					}

					if .X in ctx.keys_pressed &&
					   .CTRL in ctx.keys_down &&
					   .ALT not_in ctx.keys_down {
						if edit.cut(&ctx.textbox_state) {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if .C in ctx.keys_pressed &&
					   .CTRL in ctx.keys_down &&
					   .ALT not_in ctx.keys_down {
						edit.copy(&ctx.textbox_state)
					}

					if .V in ctx.keys_pressed &&
					   .CTRL in ctx.keys_down &&
					   .ALT not_in ctx.keys_down {
						if edit.paste(&ctx.textbox_state) {
							textlen^ = strings.builder_len(builder)
							res += {.CHANGE}
						}
					}

					if .LEFT in ctx.keys_pressed {
						move: edit.Translation = .CTRL in ctx.keys_down ? .Word_Left : .Left
						if .SHIFT in ctx.keys_down {
							edit.select_to(&ctx.textbox_state, move)
						} else {
							edit.move_to(&ctx.textbox_state, move)
						}
					}

					if .RIGHT in ctx.keys_pressed {
						move: edit.Translation = .CTRL in ctx.keys_down ? .Word_Right : .Right
						if .SHIFT in ctx.keys_down {
							edit.select_to(&ctx.textbox_state, move)
						} else {
							edit.move_to(&ctx.textbox_state, move)
						}
					}

					if .HOME in ctx.keys_pressed {
						if .SHIFT in ctx.keys_down {
							edit.select_to(&ctx.textbox_state, .Start)
						} else {
							edit.move_to(&ctx.textbox_state, .Start)
						}
					}

					if .END in ctx.keys_pressed {
						if .SHIFT in ctx.keys_down {
							edit.select_to(&ctx.textbox_state, .End)
						} else {
							edit.move_to(&ctx.textbox_state, .End)
						}
					}

					if .BACKSPACE in ctx.keys_pressed && textlen^ > 0 {
						move: edit.Translation = .CTRL in ctx.keys_down ? .Word_Left : .Left
						edit.delete_to(&ctx.textbox_state, move)
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}

					if .DELETE in ctx.keys_pressed && textlen^ > 0 {
						move: edit.Translation = .CTRL in ctx.keys_down ? .Word_Right : .Right
						edit.delete_to(&ctx.textbox_state, move)
						textlen^ = strings.builder_len(builder)
						res += {.CHANGE}
					}

					if .RETURN in ctx.keys_pressed {
						res += {.SUBMIT}
					}

					if .ESCAPE in ctx.keys_pressed {
						res += {.CANCEL}
					}

					// multi-click + click and drag
					{
						if .DOUBLE_CLICKED in ctx.statuses {
							edit.move_to(&ctx.textbox_state, .Word_Start)
							edit.select_to(&ctx.textbox_state, .Word_End)
						} else if .TRIPLE_CLICKED in ctx.statuses {
							ctx.textbox_state.selection = {textlen^, 0}
						} else if .LEFT in ctx.mouse_down {
							idx := textlen^
							for i in 0 ..= textlen^ {
								if buf[i] > 0x80 && buf[i] < 0xC0 do continue

								clay_str := clay.MakeString(string(buf[:i]))
								text_size := UI__measure_text(
									clay.StringSlice {
										clay_str.length,
										clay_str.chars,
										clay_str.chars,
									},
									text_config,
									ctx,
								)

								if ctx.mouse_pos.x <
								   boundingbox.x + text_size.width + c.float(ctx.textbox_offset) {
									idx = max(i - 1, 0)
									break
								}
							}

							ctx.textbox_state.selection[0] = idx
							if .LEFT in ctx.mouse_pressed && .SHIFT not_in ctx.keys_down {
								ctx.textbox_state.selection[1] = idx
							}
						}
					}

					text_str := string(buf[:textlen^])
					text_clay_str := clay.MakeString(text_str)
					text_size := UI__measure_text(
						clay.StringSlice {
							text_clay_str.length,
							text_clay_str.chars,
							text_clay_str.chars,
						},
						text_config,
						ctx,
					)

					head_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[0]])
					head_size := UI__measure_text(
						clay.StringSlice {
							head_clay_str.length,
							head_clay_str.chars,
							head_clay_str.chars,
						},
						text_config,
						ctx,
					)
					tail_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[1]])
					tail_size := UI__measure_text(
						clay.StringSlice {
							tail_clay_str.length,
							tail_clay_str.chars,
							tail_clay_str.chars,
						},
						text_config,
						ctx,
					)

					PADDING :: 5
					sizing := [2]c.float {
						elem_loc_data.boundingBox.width,
						elem_loc_data.boundingBox.height,
					}
					ofmin := max(PADDING - head_size.width, sizing.x - text_size.width - PADDING)
					ofmax := min(sizing.x - head_size.width - PADDING, PADDING)
					ctx.textbox_offset = clamp(ctx.textbox_offset, int(ofmin), int(ofmax))
					ctx.textbox_offset = clamp(ctx.textbox_offset, min(int), 0)

					// cursor
					if head_size.width - tail_size.width == 0 {
						if clay.UI()(
						{
							floating = {
								attachment = {element = .LeftCenter, parent = .LeftCenter},
								offset = {head_size.width + c.float(ctx.textbox_offset), 0},
								pointerCaptureMode = .Passthrough,
								attachTo = .Parent,
							},
							layout = {
								sizing = {
									clay.SizingFixed(2),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
							backgroundColor = TEXT *
							{
									1,
									1,
									1,
									((math.sin(
												c.float(time.since(ctx.start_time)) /
												c.float(250 * time.Millisecond),
											)) +
										1) /
									2,
								},
						},
						) {
							if time.since(ctx.prev_event_time) > UI_EVENT_DELAY do ctx.statuses += {.EVENT}
						}
					} else { 	// selection box
						if clay.UI()(
						{
							floating = {
								attachment = {element = .LeftCenter, parent = .LeftCenter},
								offset = {
									min(head_size.width, tail_size.width) +
									c.float(ctx.textbox_offset),
									0,
								},
								pointerCaptureMode = .Passthrough,
								attachTo = .Parent,
							},
							layout = {
								sizing = {
									clay.SizingFixed(abs(head_size.width - tail_size.width)),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
							backgroundColor = TEXT * {1, 1, 1, 0.25},
						},
						) {
							if time.since(ctx.prev_event_time) > UI_EVENT_DELAY do ctx.statuses += {.EVENT}
						}
					}

					// [TODO] fix nested scrolldata fetching
					scroll_data := clay.GetScrollContainerData(local_id)
					if scroll_data.found do scroll_data.scrollPosition^ = {c.float(ctx.textbox_offset), 0}
					else do fmt.eprintln("Could not get scroll data for:", local_id)

					clay.TextDynamic(text_str, text_config)
				} else {
					clay.TextDynamic(placeholder_text, text_config)
				}
			}
		}
	}
	return
}

UI__slider :: proc(
	ctx: ^UI_Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	notches: ..T,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, local_id)
		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				childAlignment = {y = .Center},
			},
		},
		) {
			boundingbox := clay.GetElementData(id).boundingBox
			minor_dimension := min(boundingbox.width, boundingbox.height)
			major_dimension := max(boundingbox.width, boundingbox.height)

			scroll := ctx.scroll_delta.y
			if active && (.LEFT not_in ctx.mouse_pressed && .LEFT in ctx.mouse_down) {
				relative_x := T(ctx.mouse_pos.x) - T(boundingbox.x)
				slope := T(max_val - min_val) / T(boundingbox.width)
				pos^ = min_val + slope * (relative_x)
				pos^ = clamp(pos^, min_val, max_val)
			} else if clay.Hovered() && scroll != 0 {
				pos^ -= scroll / 10
				pos^ = clamp(pos^, min_val, max_val)
				res += {.CHANGE}
			}

			selected_color := color
			if active do selected_color = press_color
			else if clay.Hovered() do selected_color = hover_color

			val_to_pos :: proc(
				val, min_val, max_val, major, minor: $T,
			) -> T where intrinsics.type_is_float(T) {
				return abs(val - min_val) / abs(max_val - min_val) * major
			}

			slider_pos := val_to_pos(pos^, min_val, max_val, major_dimension, minor_dimension)
			default_mark := val_to_pos(
				default_val,
				min_val,
				max_val,
				major_dimension,
				minor_dimension,
			)

			LINE_THICKNESS :: 0.25
			if clay.UI()(
			{
				layout = {
					sizing = {
						clay.SizingPercent(1),
						clay.SizingFixed(minor_dimension * LINE_THICKNESS),
					},
				},
				backgroundColor = line_color,
			},
			) {
				if clay.UI()(
				{
					floating = {
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						offset = {min(slider_pos, default_mark), 0},
						pointerCaptureMode = .Passthrough,
						attachTo = .Parent,
					},
					layout = {
						sizing = {
							clay.SizingFixed(
								major_dimension *
								(abs(pos^ - default_val) / abs(max_val - min_val)),
							),
							clay.SizingFixed(minor_dimension * LINE_THICKNESS),
						},
					},
					backgroundColor = line_highlight,
				},
				) {}
			}

			NOTCH_WIDTH :: 4
			for notch in notches {
				if clay.UI()(
				{
					floating = {
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						offset = {
							val_to_pos(notch, min_val, max_val, major_dimension, minor_dimension) -
							NOTCH_WIDTH / 2,
							0,
						},
						pointerCaptureMode = .Passthrough,
						attachTo = .Parent,
					},
					layout = {
						sizing = {
							clay.SizingFixed(NOTCH_WIDTH),
							clay.SizingFixed(minor_dimension),
						},
					},
					backgroundColor = line_color,
					cornerRadius = clay.CornerRadiusAll(minor_dimension / 2),
				},
				) {}
			}
			if clay.UI()(
			{
				floating = {
					attachment = {element = .LeftCenter, parent = .LeftCenter},
					offset = {slider_pos - minor_dimension / 2, 0},
					pointerCaptureMode = .Passthrough,
					attachTo = .Parent,
				},
				layout = {
					sizing = {
						clay.SizingFixed(minor_dimension),
						clay.SizingFixed(minor_dimension),
					},
				},
				backgroundColor = selected_color,
				cornerRadius = clay.CornerRadiusAll(minor_dimension / 2),
			},
			) {}
		}
	}
	return
}


UI__text_button :: proc(
	ctx: ^UI_Context,
	text: string,
	layout: clay.LayoutConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color, text_color: clay.Color,
	text_size: u16,
	text_padding: u16,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	text_config := clay.TextConfig({textColor = text_color, fontSize = text_size})

	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := UI_widget_active(ctx, id)
		selected_color := color
		if active do selected_color = press_color
		else if clay.Hovered() do selected_color = hover_color

		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
				padding = clay.PaddingAll(text_padding),
			},
			backgroundColor = selected_color,
			cornerRadius = corner_radius,
		},
		) {
			clay.TextDynamic(text, text_config)
		}
	}
	return
}

UI_spacer :: proc(ctx: ^UI_Context) -> (res: UI_WidgetResults, id: clay.ElementId) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id
		if clay.UI()({id = local_id}) {
			if clay.Hovered() do ctx.hovered_widget = id
			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
			if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}
		}
	}
	return
}

UI_textlabel :: proc(text: string, config: clay.TextElementConfig) {
	textlabel := clay.TextConfig(config)
	clay.TextDynamic(text, textlabel)
}

UI_modal_escapable :: proc(
	ctx: ^UI_Context,
	bg_color: clay.Color,
	widget: proc(
		ctx: ^UI_Context,
		user_data: rawptr,
	) -> (
		res: UI_WidgetResults,
		id: clay.ElementId,
	),
	user_data: rawptr = nil,
	attachment: clay.FloatingAttachToElement = .Root,
) -> (
	res: UI_WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		floating = {
			attachment = {element = .CenterCenter, parent = .CenterCenter},
			attachTo = attachment,
		},
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = bg_color,
	},
	) {
		res, id = widget(ctx, user_data)
	}
	return
}
