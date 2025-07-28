package ui

import "base:intrinsics"
import "base:runtime"
import "clay"
import "core:c"
import sa "core:container/small_array"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:text/edit"
import "core:time"
import sdl "vendor:sdl3"
import img "vendor:sdl3/image"
import ttf "vendor:sdl3/ttf"

odin_context: runtime.Context

Context :: struct {
	textbox_input:       strings.Builder,
	textbox_state:       edit.State,
	textbox_offset:      int,
	active_widgets:      sa.Small_Array(16, clay.ElementId),
	hovered_widget:      clay.ElementId,
	prev_hovered_widget: clay.ElementId,
	statuses:            Context_Statuses,
	// input handling
	_text_store:         [1024]u8, // global text input per frame
	click_count:         int,
	// mouse
	prev_click_time:     time.Time,
	click_debounce:      time.Time,
	mouse_pressed:       Mouse_Buttons,
	mouse_down:          Mouse_Buttons,
	mouse_released:      Mouse_Buttons,
	mouse_pos:           [2]c.float,
	scroll_delta:        [2]c.float,
	// keyboard
	keys_pressed:        Control_Keys,
	keys_down:           Control_Keys,
	// allocated
	clay_memory:         []u8,
	font_allocator:      virtual.Arena,
	fonts:               sa.Small_Array(16, Font),
	images:              sa.Small_Array(16, Image),
	// sdl3
	window:              ^sdl.Window,
	window_size:         [2]c.float,
	start_time:          time.Tick,
	prev_frame_time:     time.Tick,
	prev_frametime:      time.Duration,
	prev_event_time:     time.Tick,
	scaling:             c.float,
	tray:                ^sdl.Tray,
	tray_menu:           ^sdl.TrayMenu,
	tray_icon:           ^sdl.Surface,
	toggle_entry:        ^sdl.TrayEntry,
	exit_entry:          ^sdl.TrayEntry,
	// renderer
	renderer:            Renderer,
	device:              ^sdl.GPUDevice,
	memory_debug:        Memory_Debug_Data,
}

when ODIN_DEBUG {
	MemEntry :: struct {
		log_size: f32,
		color:    clay.Color,
	}

	Memory_Debug_Data :: struct {
		memory: map[rawptr]MemEntry,
	}
} else {
	Memory_Debug_Data :: struct {}
}

Scrollbar_Data :: struct {
	click_origin: clay.Vector2,
	pos_origin:   clay.Vector2,
}

Mouse_Button :: enum {
	LEFT,
	MIDDLE,
	RIGHT,
	SIDE_1,
	SIDE_2,
}
Mouse_Buttons :: bit_set[Mouse_Button]

Control_Key :: enum {
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
	M,
}
Control_Keys :: bit_set[Control_Key]

Data_Flag :: enum {
	SHADOW,
}
Data_Flags :: bit_set[Data_Flag;uintptr]

DOUBLE_CLICK_INTERVAL :: 300 * time.Millisecond
EVENT_DELAY :: 33 * time.Millisecond
DEBUG_LAYOUT_TIMER_INTERVAL :: time.Second
DEBUG_PREV_TIME: time.Tick

Context_Status :: enum {
	DIRTY,
	EVENT,
	TEXTBOX_SELECTED,
	TEXTBOX_HOVERING,
	BUTTON_HOVERING,
	DOUBLE_CLICKED,
	TRIPLE_CLICKED,
	WINDOW_CLOSED,
	WINDOW_MINIMIZED,
	WINDOW_JUST_SHOWN,
	APP_EXIT,
	MEMORY_DEBUG,
}
Context_Statuses :: bit_set[Context_Status]

WidgetResult :: enum {
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
WidgetResults :: bit_set[WidgetResult]

Font :: struct {
	font: map[u16]^ttf.Font,
	data: []u8,
}

_Image :: struct {
	surface: ^sdl.Surface,
	texture: ^sdl.GPUTexture,
	size:    int,
}

Image :: struct {
	image:      _Image,
	dimensions: [2]int,
	data:       []u8,
}

retrieve_font :: proc(ctx: ^Context, id, size: u16) -> ^ttf.Font {
	sdl_font := sa.get_ptr(&ctx.fonts, int(id))
	_, font, just_inserted, _ := map_entry(&sdl_font.font, size)
	if just_inserted {
		font_stream := sdl.IOFromConstMem(raw_data(sdl_font.data), len(sdl_font.data))
		font^ = ttf.OpenFontIO(font_stream, true, c.float(size))
		_ = ttf.SetFontSizeDPI(font^, f32(size), 72 * c.int(ctx.scaling), 72 * c.int(ctx.scaling))
	}
	return font^
}

retrieve_image :: proc(ctx: ^Context, id: int, size: [2]int) -> ^_Image {
	ui_img := sa.get_ptr(&ctx.images, id)
	if ui_img.dimensions.x < size.x || ui_img.dimensions.y < size.y {
		log.infof("resizing image %v from %v to %v", id, ui_img.dimensions, size)
		sdl.ReleaseGPUTexture(ctx.device, ui_img.image.texture)
		sdl.DestroySurface(ui_img.image.surface)

		img_stream := sdl.IOFromConstMem(raw_data(ui_img.data), len(ui_img.data))
		defer sdl.CloseIO(img_stream)
		img_surface := img.LoadSizedSVG_IO(img_stream, c.int(size.x), c.int(size.y))
		img_texture := sdl.CreateGPUTexture(
			ctx.device,
			{
				format = .R8G8B8A8_UNORM,
				usage = {.SAMPLER},
				width = u32(img_surface.w),
				height = u32(img_surface.h),
				layer_count_or_depth = 1,
				num_levels = 1,
			},
		)
		texture_size := 4 * int(img_surface.w) * int(img_surface.h)
		ui_img.image = _Image{img_surface, img_texture, texture_size}
		ui_img.dimensions = size
		ctx.renderer.pipeline.status += {.TEXTURE_DIRTY}
	}
	return &ui_img.image
}

TEXT_CURSOR: ^sdl.Cursor
HAND_CURSOR: ^sdl.Cursor
DEFAULT_CURSOR: ^sdl.Cursor

init :: proc(ctx: ^Context, minimized: bool) {
	odin_context = context
	font_arena_init_err := virtual.arena_init_growing(&ctx.font_allocator)
	if font_arena_init_err != nil do panic("font allocator initialization failed")

	ctx.textbox_state.set_clipboard = _set_clipboard
	ctx.textbox_state.get_clipboard = _get_clipboard
	ctx.textbox_input = strings.builder_from_bytes(ctx._text_store[:])
	ctx.start_time = time.tick_now()

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
	sdl.SetHint(sdl.HINT_VIDEO_ALLOW_SCREENSAVER, "1")
	sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1")
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

	device_props := sdl.CreateProperties()
	defer sdl.DestroyProperties(device_props)
	sdl.SetBooleanProperty(device_props, sdl.PROP_GPU_DEVICE_CREATE_PREFERLOWPOWER_BOOLEAN, true)
	sdl.SetBooleanProperty(device_props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
	sdl.SetBooleanProperty(device_props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, ODIN_DEBUG)
	ctx.device = sdl.CreateGPUDeviceWithProperties(device_props)
	_ = sdl.ClaimWindowForGPUDevice(ctx.device, ctx.window)
	Renderer_init(ctx)

	{
		ctx.tray = sdl.CreateTray(nil, "Mixologist")
		ctx.tray_menu = sdl.CreateTrayMenu(ctx.tray)

		ctx.toggle_entry = sdl.InsertTrayEntryAt(
			ctx.tray_menu,
			-1,
			(minimized ? "Open" : "Close"),
			{.BUTTON},
		)
		sdl.SetTrayEntryCallback(ctx.toggle_entry, toggle_window, ctx)

		ctx.exit_entry = sdl.InsertTrayEntryAt(ctx.tray_menu, -1, "Quit Mixologist", {.BUTTON})
		sdl.SetTrayEntryCallback(ctx.exit_entry, _quit_application, ctx)
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
		{handler = _clay_error_handler},
	)

	clay.SetMeasureTextFunction(_measure_text, ctx)
	ctx.prev_event_time = time.tick_now()
	ctx.prev_frame_time = time.tick_now()

	// reasonable 60fps default for initial redraw rate
	ctx.prev_frametime = 16 * time.Millisecond
	ctx.statuses += {.WINDOW_JUST_SHOWN}

	when ODIN_DEBUG {
		ctx.memory_debug.memory = make(map[rawptr]MemEntry, 1e3)
	}
}

deinit :: proc(ctx: ^Context) {
	when ODIN_DEBUG {
		delete(ctx.memory_debug.memory)
	}

	virtual.arena_destroy(&ctx.font_allocator)
	delete(ctx.clay_memory)

	sdl.DestroyTray(ctx.tray)

	for img in sa.slice(&ctx.images) {
		sdl.ReleaseGPUTexture(ctx.device, img.image.texture)
		sdl.DestroySurface(img.image.surface)
	}

	Renderer_destroy(ctx)

	sdl.DestroyWindow(ctx.window)
}

set_tray_icon :: proc(ctx: ^Context, icon: []u8) {
	icon_io := sdl.IOFromConstMem(raw_data(icon), len(icon))
	ctx.tray_icon = img.Load_IO(icon_io, true)
	sdl.SetTrayIcon(ctx.tray, ctx.tray_icon)
}

tick :: proc(
	ctx: ^Context,
	ui_create_layout: proc(ctx: ^Context, userdata: rawptr) -> clay.ClayArray(clay.RenderCommand),
	userdata: rawptr,
) {
	frame_start := time.tick_now()
	// input reset
	{
		strings.builder_reset(&ctx.textbox_input)
		ctx.mouse_pressed = {}
		ctx.mouse_released = {}
		ctx.scroll_delta = {}
		ctx.keys_pressed = {}
		ctx.prev_hovered_widget, ctx.hovered_widget = ctx.hovered_widget, {}
		ctx.statuses -= {.EVENT, .TEXTBOX_HOVERING, .BUTTON_HOVERING}
	}

	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			ctx.statuses += {.APP_EXIT}
		case .WINDOW_MINIMIZED:
			ctx.statuses += {.WINDOW_MINIMIZED}
		case .WINDOW_RESTORED:
			ctx.statuses -= {.WINDOW_MINIMIZED}
		case .WINDOW_CLOSE_REQUESTED:
			toggle_window(ctx, ctx.toggle_entry)
		case .WINDOW_DISPLAY_SCALE_CHANGED:
			ctx.statuses += {.EVENT}
			ctx.scaling = sdl.GetWindowDisplayScale(ctx.window)
		case .WINDOW_RESIZED:
			ctx.statuses += {.EVENT}
		case .MOUSE_MOTION:
			ctx.mouse_pos = {event.motion.x, event.motion.y}
		case .MOUSE_WHEEL:
			ctx.statuses += {.EVENT}
			ctx.scroll_delta = {event.wheel.x, event.wheel.y}
		case .TEXT_INPUT:
			ctx.statuses += {.EVENT}
			strings.write_string(&ctx.textbox_input, string(event.text.text))
		case .MOUSE_BUTTON_UP, .MOUSE_BUTTON_DOWN:
			ctx.statuses += {.EVENT}
			fn := event.type == .MOUSE_BUTTON_UP ? _input_mouse_up : _input_mouse_down
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
			fn := event.type == .KEY_UP ? _input_key_up : _input_key_down
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
			case .DELETE:
				fn(ctx, .DELETE)
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
			case .M:
				fn(ctx, .M)
			}
		}
	}

	// [INFO] sdl.WaitAndAcquireGPUSwapchainTexture will hang if
	// we do not return early
	if .WINDOW_CLOSED in ctx.statuses || .WINDOW_MINIMIZED in ctx.statuses {
		time.sleep(100 * time.Millisecond)
		return
	}

	if .LEFT in ctx.mouse_pressed {
		if time.since(ctx.prev_click_time) <= DOUBLE_CLICK_INTERVAL {
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
	} else if time.since(ctx.prev_click_time) >= DOUBLE_CLICK_INTERVAL {
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
	ctx.window_size = {c.float(window_size.x), c.float(window_size.y)}
	clay.SetLayoutDimensions({ctx.window_size.x, ctx.window_size.y})

	when ODIN_DEBUG {
		layout_start := time.now()
	}

	// run layout twice to avoid 1-frame
	// delay of immediate mode
	_ = ui_create_layout(ctx, userdata)
	{
		strings.builder_reset(&ctx.textbox_input)
		ctx.mouse_pressed = {}
		ctx.mouse_released = {}
		ctx.keys_pressed = {}
	}

	// runs during second layout pass to prevent issues
	// with scroll container data from deleted rules
	clay.UpdateScrollContainers(
		false,
		ctx.scroll_delta * 5,
		c.float(time.tick_since(ctx.prev_frame_time) / time.Second),
	)
	render_commands := ui_create_layout(ctx, userdata)

	when ODIN_DEBUG {
		layout_time := time.since(layout_start)
		render_start := time.tick_now()
	}

	if ctx.hovered_widget != ctx.prev_hovered_widget do ctx.statuses += {.EVENT}

	if ctx.statuses >= {.TEXTBOX_HOVERING, .TEXTBOX_SELECTED} {
		_ = sdl.SetCursor(TEXT_CURSOR)
	} else if .BUTTON_HOVERING in ctx.statuses || .TEXTBOX_HOVERING in ctx.statuses {
		_ = sdl.SetCursor(HAND_CURSOR)
	} else {
		_ = sdl.SetCursor(DEFAULT_CURSOR)
	}

	if .WINDOW_JUST_SHOWN in ctx.statuses {
		ctx.statuses -= {.WINDOW_JUST_SHOWN}
		ctx.statuses += {.DIRTY}
		return
	}
	if .DIRTY in ctx.statuses {
		ctx.statuses -= {.DIRTY}
		ctx.statuses += {.EVENT}
	}
	if .EVENT in ctx.statuses {
		cmd_buffer := sdl.AcquireGPUCommandBuffer(ctx.device)
		Renderer_draw(ctx, cmd_buffer, &render_commands)
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd_buffer)
		if fence == nil {
			log.error("fence is nil")
			return
		}

		_ = sdl.WaitForGPUFences(ctx.device, true, &fence, 1)
		sdl.ReleaseGPUFence(ctx.device, fence)
		ctx.prev_event_time = time.tick_now()
	} else {
		time.sleep(ctx.prev_frametime)
	}

	when ODIN_DEBUG {
		ctx.statuses += {.DIRTY}
		render_time := time.tick_since(render_start)
		if clay.IsDebugModeEnabled() {
			if time.tick_since(DEBUG_PREV_TIME) > DEBUG_LAYOUT_TIMER_INTERVAL {
				fmt.printfln(
					"FPS: %.2f",
					1 / time.duration_seconds(time.tick_since(ctx.prev_frame_time)),
				)
				fmt.println("Layout time:", layout_time)
				fmt.println("Render time:", render_time)
				fmt.println("Mouse pos:", ctx.mouse_pos)
				fmt.println("Mouse down:", ctx.mouse_down)
				fmt.println("Mouse scroll:", ctx.scroll_delta)
				fmt.println("Display scale:", ctx.scaling)
				fmt.println("Statuses:", ctx.statuses)
				DEBUG_PREV_TIME = time.tick_now()
			}
		}
	}

	ctx.prev_frame_time = time.tick_now()
	ctx.prev_frametime = time.tick_since(frame_start)
}

open_window :: proc(ctx: ^Context) {
	ctx.statuses -= {.WINDOW_CLOSED}
	ctx.statuses += {.WINDOW_JUST_SHOWN}
	sdl.SetTrayEntryLabel(ctx.toggle_entry, "Close")
	sdl.ShowWindow(ctx.window)
	sdl.RaiseWindow(ctx.window)
}

close_window :: proc(ctx: ^Context) {
	ctx.statuses += {.WINDOW_CLOSED}
	sdl.HideWindow(ctx.window)
}

toggle_window :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	ctx := cast(^Context)userdata
	context = odin_context
	if .WINDOW_CLOSED in ctx.statuses {
		sdl.SetTrayEntryLabel(entry, "Close")
		open_window(ctx)
	} else {
		sdl.SetTrayEntryLabel(entry, "Open")
		close_window(ctx)
	}
}

_quit_application :: proc "c" (userdata: rawptr, entry: ^sdl.TrayEntry) {
	ctx := cast(^Context)userdata
	ctx.statuses += {.APP_EXIT}
}

_measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions {
	if text.length == 0 do return {0, 0}

	context = odin_context
	ctx := cast(^Context)userData
	font := retrieve_font(ctx, config.fontId, u16(c.float(config.fontSize) * ctx.scaling))

	size: [2]c.int
	_ = ttf.GetStringSize(font, cstring(text.chars), c.size_t(text.length), &size.x, &size.y)
	return {c.float(size.x) / ctx.scaling, c.float(size.y) / ctx.scaling}
}

_input_key_down :: proc(ctx: ^Context, key: Control_Key) {
	ctx.keys_down += {key}
	ctx.keys_pressed += {key}
}

_input_key_up :: proc(ctx: ^Context, key: Control_Key) {
	ctx.keys_down -= {key}
}

_input_mouse_down :: proc(ctx: ^Context, button: Mouse_Button) {
	ctx.mouse_down += {button}
	ctx.mouse_pressed += {button}
}

_input_mouse_up :: proc(ctx: ^Context, button: Mouse_Button) {
	ctx.mouse_down -= {button}
	ctx.mouse_released += {button}
}

widget_active :: proc(ctx: ^Context, id: clay.ElementId) -> bool {
	return slice.contains(sa.slice(&ctx.active_widgets), id)
}

widget_focus :: proc(ctx: ^Context, id: clay.ElementId) {
	if !slice.contains(sa.slice(&ctx.active_widgets), id) do sa.append(&ctx.active_widgets, id)
}

status_add :: proc(ctx: ^Context, statuses: Context_Statuses) {
	ctx.statuses += statuses
}

textbox_reset :: proc(ctx: ^Context, textlen: int) {
	ctx.textbox_state.selection = {textlen, textlen}
}

unfocus :: proc(ctx: ^Context, id: clay.ElementId) {
	idx, found := slice.linear_search(sa.slice(&ctx.active_widgets), id)
	if found do sa.unordered_remove(&ctx.active_widgets, idx)
}

unfocus_all :: proc(ctx: ^Context) {
	sa.clear(&ctx.active_widgets)
}

window_closed :: proc(ctx: ^Context) -> bool {
	return .WINDOW_CLOSED in ctx.statuses
}

should_exit :: proc(ctx: ^Context) -> bool {
	return .APP_EXIT in ctx.statuses
}

exit :: proc(ctx: ^Context) {
	ctx.statuses += {.APP_EXIT}
}

load_image_mem :: proc(ctx: ^Context, data: []u8, size: [2]int) -> int {
	img_stream := sdl.IOFromConstMem(raw_data(data), len(data))
	defer sdl.CloseIO(img_stream)
	img_surface := img.LoadSizedSVG_IO(img_stream, c.int(size.x), c.int(size.y))
	img_texture := sdl.CreateGPUTexture(
		ctx.device,
		{
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(img_surface.w),
			height = u32(img_surface.h),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	texture_size := 4 * int(img_surface.w) * int(img_surface.h)
	log.debugf("loaded image of size: [%v, %v]", img_surface.w, img_surface.h)
	image := _Image{img_surface, img_texture, texture_size}

	ctx.renderer.pipeline.status += {.TEXTURE_DIRTY}
	sa.append(&ctx.images, Image{image = image, dimensions = size, data = data})
	return sa.len(ctx.images) - 1
}

load_font_mem :: proc(ctx: ^Context, data: []u8, fontsize: u16) -> u16 {
	font_stream := sdl.IOFromConstMem(raw_data(data), len(data))
	font := ttf.OpenFontIO(font_stream, true, c.float(fontsize))
	assert(font != nil)

	font_map := make(map[u16]^ttf.Font, 16, virtual.arena_allocator(&ctx.font_allocator))
	font_map[fontsize] = font
	ui_font := Font {
		font = font_map,
		data = data,
	}

	sa.append(&ctx.fonts, ui_font)
	return u16(sa.len(ctx.fonts) - 1)
}

load_font :: proc(ctx: ^Context, fontsize: u16, path: cstring) -> u16 {
	unimplemented()
}

_set_clipboard :: proc(user_data: rawptr, text: string) -> (ok: bool) {
	text_cstr := strings.clone_to_cstring(text)
	sdl.SetClipboardText(text_cstr)
	delete(text_cstr)
	return true
}

_get_clipboard :: proc(user_data: rawptr) -> (text: string, ok: bool) {
	text_cstr := cstring(sdl.GetClipboardText())
	if text_cstr != nil {
		text = string(text_cstr)
		ok = true
	}
	return
}

_clay_error_handler :: proc "c" (errordata: clay.ErrorData) {
	// [TODO] find out why `ID_LOCAL` is producing duplicate id errors
	// context = runtime.default_context()
	// fmt.printfln("clay error detected: %s", errordata.errorText.chars[:errordata.errorText.length])
}

scrollbar :: proc(
	ctx: ^Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	res, id = _scrollbar(
		ctx,
		scroll_container_data,
		scrollbar_data,
		bar_width,
		bar_color,
		target_color,
		hover_color,
		press_color,
	)

	active := widget_active(ctx, id)
	if .PRESS in res {
		widget_focus(ctx, id)
		if !active {
			res += {.FOCUS}
			scrollbar_data.click_origin = ctx.mouse_pos
			scrollbar_data.pos_origin = scroll_container_data.scrollPosition^
		}
		active = true
	}
	if active && .LEFT in ctx.mouse_down {
		if time.tick_since(ctx.prev_event_time) > EVENT_DELAY do ctx.statuses += {.EVENT}
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
	} else if .LEFT not_in ctx.mouse_down do unfocus(ctx, id)

	return
}

textbox :: proc(
	ctx: ^Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
	enabled := true,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	res, id = _textbox(ctx, buf, textlen, placeholder_text, config, border_config, text_config)

	if enabled {
		active := widget_active(ctx, id)
		if .HOVER in res do ctx.statuses += {.TEXTBOX_HOVERING}

		if active {
			if .CANCEL in res do unfocus(ctx, id)
			if .SUBMIT in res && textlen^ > 0 do unfocus(ctx, id)
		}
	}
	if .HOVER not_in res && .LEFT in ctx.mouse_pressed do unfocus(ctx, id)
	return
}

slider :: proc(
	ctx: ^Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	snap_threshhold: T,
	notches: ..T,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	res, id = _slider(
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
		{sizing = {clay.SizingGrow(), clay.SizingFixed(16)}},
		..notches,
	)

	active := widget_active(ctx, id)
	if .PRESS in res {
		widget_focus(ctx, id)
		if !active do res += {.FOCUS}
	}
	if active && .LEFT in ctx.mouse_down do res += {.CHANGE}

	if .HOVER not_in res && .LEFT in ctx.mouse_pressed do unfocus(ctx, id)
	if .LEFT in ctx.mouse_released do unfocus(ctx, id)

	for notch in notches {
		if abs(pos^ - notch) < snap_threshhold {
			pos^ = notch
			break
		}
	}

	if .CHANGE in res && time.tick_since(ctx.prev_event_time) > EVENT_DELAY do ctx.statuses += {.EVENT}
	return
}

ElementConfig :: union {
	TextConfig,
	IconConfig,
	HorzSpacerConfig,
	VertSpacerConfig,
}

HorzSpacerConfig :: struct {
	size: c.float,
}

VertSpacerConfig :: struct {
	size: c.float,
}

TextConfig :: struct {
	text:  string,
	size:  u16,
	color: clay.Color,
}

IconConfig :: struct {
	id:    int,
	size:  [2]int,
	color: clay.Color,
}

button :: proc(
	ctx: ^Context,
	elements: []ElementConfig,
	layout: clay.LayoutConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color: clay.Color,
	padding: u16,
	enabled := true,
	border_config: clay.BorderElementConfig = {},
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	res, id = _button(
		ctx,
		elements,
		layout,
		border_config,
		corner_radius,
		enabled ? color : color * {0.65, 0.65, 0.65, 1},
		enabled ? hover_color : color * {0.65, 0.65, 0.65, 1},
		enabled ? press_color : color * {0.65, 0.65, 0.65, 1},
		padding,
	)

	if enabled {
		if .HOVER in res do ctx.statuses += {.BUTTON_HOVERING}
		else do unfocus(ctx, id)

		if .PRESS in res do widget_focus(ctx, id)
		else if .RELEASE in res do unfocus(ctx, id)
	}
	return
}

tswitch :: proc(
	ctx: ^Context,
	state: ^bool,
	layout: clay.LayoutConfig,
	color, background_color, active_background_color: clay.Color,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	res, id = _switch(ctx, state, layout, color, background_color, active_background_color)

	if .HOVER in res do ctx.statuses += {.BUTTON_HOVERING}
	else do unfocus(ctx, id)

	if .PRESS in res do widget_focus(ctx, id)
	else if .RELEASE in res do unfocus(ctx, id)

	return
}

_scrollbar :: proc(
	ctx: ^Context,
	scroll_container_data: clay.ScrollContainerData,
	scrollbar_data: ^Scrollbar_Data,
	bar_width: int,
	bar_color, target_color, hover_color, press_color: clay.Color,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	local_id := clay.ID_LOCAL(#procedure)
	id = local_id

	bar_width := bar_width
	if scroll_container_data.contentDimensions.height <= scroll_container_data.scrollContainerDimensions.height do bar_width = 0
	if clay.UI()(
	{
		layout = {sizing = {clay.SizingFixed(c.float(bar_width)), clay.SizingGrow()}},
		floating = {attachment = {element = .RightTop, parent = .RightTop}, attachTo = .Parent},
		backgroundColor = bar_color,
		id = local_id,
	},
	) {
		scroll_res, scroll_id := _scroll_target(
			ctx,
			scroll_container_data,
			bar_width,
			target_color,
			hover_color,
			press_color,
		)

		scroll_active := widget_active(ctx, scroll_id)
		if .PRESS in scroll_res {
			widget_focus(ctx, scroll_id)
			if !scroll_active {
				res += {.FOCUS}
				scrollbar_data.click_origin = ctx.mouse_pos
				scrollbar_data.pos_origin = scroll_container_data.scrollPosition^
			}
			scroll_active = true
		}
		if scroll_active {
			ctx.statuses += {.EVENT}
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
		if .LEFT in ctx.mouse_released do unfocus(ctx, scroll_id)

		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if .LEFT in ctx.mouse_released do res += {.RELEASE}
	}
	return
}

_scroll_target :: proc(
	ctx: ^Context,
	scroll_container_data: clay.ScrollContainerData,
	width: int,
	color, hover_color, press_color: clay.Color,
) -> (
	res: WidgetResults,
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
			active := widget_active(ctx, local_id)
			selected_color := color
			if active do selected_color = press_color
			else if clay.Hovered() do selected_color = hover_color

			if clay.Hovered() do ctx.hovered_widget = id
			if clay.Hovered() do res += {.HOVER}
			if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
			if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

			if clay.UI()(
			{
				layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
				backgroundColor = selected_color,
				cornerRadius = clay.CornerRadiusAll(c.float(size.x) / 2),
			},
			) {
			}
		}
	}
	return
}

_textbox :: proc(
	ctx: ^Context,
	buf: []u8,
	textlen: ^int,
	placeholder_text: string,
	config: clay.ElementDeclaration,
	border_config: clay.BorderElementConfig,
	text_config: clay.TextElementConfig,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	config := config
	border_config := border_config
	text_config := clay.TextConfig(text_config)

	if clay.UI()({layout = {sizing = config.layout.sizing}}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := widget_active(ctx, local_id)
		if !active do border_config.width = {}
		if !active do config.backgroundColor *= {0.8, 0.8, 0.8, 1}
		config.border = border_config
		config.layout.sizing = {clay.SizingGrow(), clay.SizingGrow()}


		if clay.Hovered() {
			ctx.hovered_widget = id
			res += {.HOVER}

			if .LEFT in ctx.mouse_pressed && !active {
				widget_focus(ctx, id)
				ctx.statuses -= {.DOUBLE_CLICKED, .TRIPLE_CLICKED}
				ctx.click_count = 1
				res += {.PRESS, .FOCUS}
				active = true
			} else if .LEFT in ctx.mouse_pressed {
				res += {.PRESS}
			}

			if .LEFT in ctx.mouse_released {
				res += {.RELEASE}
			}
		}

		if clay.UI()(config) {
			if clay.UI()(
			{
				id = local_id,
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					childAlignment = {y = .Center},
				},
				clip = {
					horizontal = true,
					childOffset = {active ? c.float(ctx.textbox_offset) : 0, 0},
				},
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
						log.debugf("selected textbox: %v", ctx.textbox_state.id)
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
								text_size := _measure_text(
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
					text_size := _measure_text(
						clay.StringSlice {
							text_clay_str.length,
							text_clay_str.chars,
							text_clay_str.chars,
						},
						text_config,
						ctx,
					)

					head_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[0]])
					head_size := _measure_text(
						clay.StringSlice {
							head_clay_str.length,
							head_clay_str.chars,
							head_clay_str.chars,
						},
						text_config,
						ctx,
					)
					tail_clay_str := clay.MakeString(text_str[:ctx.textbox_state.selection[1]])
					tail_size := _measure_text(
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
							backgroundColor = text_config.textColor *
							{
									1,
									1,
									1,
									((math.sin(
												c.float(time.tick_since(ctx.start_time)) /
												c.float(250 * time.Millisecond),
											)) +
										1) /
									2,
								},
						},
						) {
							if time.tick_since(ctx.prev_event_time) > EVENT_DELAY do ctx.statuses += {.EVENT}
						}
					} else { 	// selection box
						x_offset := f32(ctx.textbox_offset) + min(head_size.width, tail_size.width)
						selection_width := abs(head_size.width - tail_size.width)

						if clay.UI()(
						{
							floating = {
								attachment = {element = .LeftCenter, parent = .LeftCenter},
								offset = {x_offset, 0},
								pointerCaptureMode = .Passthrough,
								attachTo = .Parent,
								clipTo = .AttachedParent,
							},
							layout = {
								sizing = {
									clay.SizingFixed(selection_width),
									clay.SizingFixed(boundingbox.height - 6),
								},
							},
							backgroundColor = text_config.textColor * {1, 1, 1, 0.25},
						},
						) {
							if time.tick_since(ctx.prev_event_time) > EVENT_DELAY do ctx.statuses += {.EVENT}
						}
					}

					clay.TextDynamic(text_str, text_config)
				} else {
					clay.TextDynamic(placeholder_text, text_config)
				}
			}
		}
	}
	return
}

_slider :: proc(
	ctx: ^Context,
	pos: ^$T,
	default_val, min_val, max_val: T,
	color, hover_color, press_color, line_color, line_highlight: clay.Color,
	layout: clay.LayoutConfig,
	notches: ..T,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) where intrinsics.type_is_float(T) {
	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := widget_active(ctx, local_id)
		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if clay.Hovered() && .LEFT in ctx.mouse_released do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
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

_button :: proc(
	ctx: ^Context,
	elements: []ElementConfig,
	layout: clay.LayoutConfig,
	border: clay.BorderElementConfig,
	corner_radius: clay.CornerRadius,
	color, hover_color, press_color: clay.Color,
	padding: u16,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()({layout = layout}) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id

		active := widget_active(ctx, id)
		selected_color := color
		if active do selected_color = press_color
		else if clay.Hovered() do selected_color = hover_color

		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if clay.Hovered() && active && .LEFT in ctx.mouse_released do res += {.RELEASE}

		if clay.UI()(
		{
			id = local_id,
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				padding = clay.PaddingAll(padding),
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = selected_color,
			cornerRadius = corner_radius,
			border = border,
		},
		) {
			for element in elements {
				switch element in element {
				case IconConfig:
					icon(ctx, element.id, element.size, element.color)
				case TextConfig:
					clay_textconfig := clay.TextConfig(
						{textColor = element.color, fontSize = element.size},
					)
					clay.TextDynamic(element.text, clay_textconfig)
				case HorzSpacerConfig:
					horz_spacer(ctx, element.size)
				case VertSpacerConfig:
					vert_spacer(ctx, element.size)
				}
			}
		}
	}
	return
}

_switch :: proc(
	ctx: ^Context,
	state: ^bool,
	layout: clay.LayoutConfig,
	color, background_color, active_background_color: clay.Color,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	layout := layout
	layout.childAlignment.x = state^ ? .Right : .Left
	layout.childAlignment.y = .Center
	layout.padding = clay.PaddingAll(3)

	if clay.UI()(
	{
		layout = layout,
		backgroundColor = state^ ? active_background_color : background_color,
		cornerRadius = clay.CornerRadiusAll(max(c.float)),
	},
	) {
		local_id := clay.ID_LOCAL(#procedure)
		id = local_id
		hovered := clay.Hovered()
		if hovered do ctx.hovered_widget = id
		if hovered do res += {.HOVER}
		if hovered && .LEFT in ctx.mouse_pressed do res += {.PRESS}
		if hovered && .LEFT in ctx.mouse_released do res += {.RELEASE}
		if hovered && .LEFT in ctx.mouse_released do state^ = !state^

		if clay.UI()(
		{
			layout = {sizing = {clay.SizingPercent(0.5), clay.SizingGrow()}},
			cornerRadius = clay.CornerRadiusAll(max(c.float)),
			backgroundColor = hovered ? color * {1.2, 1.2, 1.2, 1} : color,
		},
		) {
		}
	}
	return
}

spacer :: proc(
	ctx: ^Context,
	horz_constraints: clay.SizingConstraintsMinMax = {},
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(horz_constraints), clay.SizingGrow()}}}) {
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

textlabel :: proc(text: string, config: clay.TextElementConfig) {
	textlabel := clay.TextConfig(config)
	clay.TextDynamic(text, textlabel)
}

@(deferred_none = _modal_close)
modal :: proc() -> proc(config: ModalConfig) -> bool {
	clay._OpenElement()
	return modal_configure
}

ModalConfig :: struct {
	background_color: clay.Color,
	attachment:       clay.FloatingAttachToElement,
	user_data:        rawptr,
}
modal_configure :: proc(config: ModalConfig = {{}, .Root, nil}) -> bool {
	elem_config := clay.ElementDeclaration {
		floating = {
			attachment = {element = .CenterCenter, parent = .CenterCenter},
			attachTo = config.attachment,
		},
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = config.background_color,
		userData = config.user_data,
	}
	clay.ConfigureOpenElement(elem_config)
	return true
}

_modal_close :: proc() {
	clay._CloseElement()
}

icon :: proc(
	ctx: ^Context,
	image_id: int,
	image_size: [2]int,
	tint: clay.Color,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	if clay.UI()(
	{
		layout = {
			sizing = {
				width = clay.SizingFixed(c.float(image_size.x)),
				height = clay.SizingFixed(c.float(image_size.y)),
			},
		},
		image = {imageData = retrieve_image(ctx, image_id, image_size)},
		backgroundColor = tint,
	},
	) {}
	return
}

dropdown :: proc(
	ctx: ^Context,
	options: []string,
	selected: ^int,
	color, background_color: clay.Color,
	text_size: u16,
	dropdown_icon_id, selection_icon_id: Maybe(int),
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	res, id = _dropdown(
		ctx,
		options,
		selected,
		color,
		background_color,
		text_size,
		dropdown_icon_id,
		selection_icon_id,
	)
	return
}

_dropdown :: proc(
	ctx: ^Context,
	options: []string,
	selected: ^int,
	color, background_color: clay.Color,
	text_size: u16,
	dropdown_icon_id, selection_icon_id: Maybe(int),
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	local_id := clay.ID_LOCAL(#procedure)
	id = local_id
	if clay.UI()({id = id, layout = {childAlignment = {x = .Left, y = .Center}}}) {
		textlabel(
			options[selected^],
			{
				textColor = clay.Hovered() ? color * {1.2, 1.2, 1.2, 1} : color,
				fontSize = text_size,
			},
		)

		if dropdown_icon_id, ok := dropdown_icon_id.?; ok {
			icon(ctx, dropdown_icon_id, {int(text_size), int(text_size)}, color)
		}

		open: bool
		if clay.Hovered() do ctx.hovered_widget = id
		if clay.Hovered() do res += {.HOVER}
		if clay.Hovered() && .LEFT in ctx.mouse_released && !widget_active(ctx, id) {
			widget_focus(ctx, id)
			open = true
		}

		if widget_active(ctx, id) {
			dropdown_res, _ := _dropdown_options(
				ctx,
				options,
				selected,
				id,
				color,
				background_color,
				text_size,
				selection_icon_id,
				open,
			)
			if .CHANGE in dropdown_res {
				res += {.CHANGE}
				unfocus(ctx, id)
			} else if .CANCEL in dropdown_res {
				unfocus(ctx, id)
			}
		}
	}
	return
}

_dropdown_options :: proc(
	ctx: ^Context,
	options: []string,
	selected: ^int,
	parent_id: clay.ElementId,
	color, background: clay.Color,
	text_size: u16,
	selection_icon_id: Maybe(int),
	open: bool,
) -> (
	res: WidgetResults,
	id: clay.ElementId,
) {
	dropdown_id := clay.ID_LOCAL(#procedure, parent_id.id)

	open_up: bool
	element_data := clay.GetElementData(parent_id)
	dropdown_data := clay.GetElementData(dropdown_id)
	if element_data.found && dropdown_data.found {
		bounding_box := element_data.boundingBox
		dropdown_bounding_box := dropdown_data.boundingBox

		center_height := bounding_box.height / 2 + bounding_box.y
		bottom_dist := ctx.window_size.y - center_height - 15

		if dropdown_bounding_box.height > bottom_dist {
			open_up = true
		}
	}

	attachment: clay.FloatingAttachPoints =
		open_up ? {element = .CenterBottom, parent = .CenterTop} : {element = .CenterTop, parent = .CenterBottom}
	if clay.UI()(
	{
		id = dropdown_id,
		floating = {
			attachment = attachment,
			attachTo = .Parent,
			pointerCaptureMode = .Capture,
			offset = {0, open_up ? -4 : 4},
			expand = {4, 4},
		},
		backgroundColor = {0, 0, 0, 255},
		cornerRadius = clay.CornerRadiusAll(14),
		userData = transmute(rawptr)Data_Flags{.SHADOW},
	},
	) {
		if clay.UI()(
		{
			layout = {
				childAlignment = {x = .Left, y = .Center},
				layoutDirection = .TopToBottom,
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				padding = clay.PaddingAll(4),
				childGap = 2,
			},
			backgroundColor = background,
			cornerRadius = clay.CornerRadiusAll(10),
		},
		) {
			if !open && !clay.Hovered() && .LEFT in ctx.mouse_released {
				res += {.CANCEL}
				return
			}

			if clay.Hovered() do ctx.hovered_widget = dropdown_id

			for option, idx in options {
				option_id := clay.ID(option, u32(idx))
				if clay.UI()(
				{
					id = option_id,
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingFit()},
						padding = clay.PaddingAll(8),
						childAlignment = {x = .Left, y = .Center},
					},
					backgroundColor = clay.Hovered() ? background * 1.2 : background,
					cornerRadius = clay.CornerRadiusAll(8),
				},
				) {
					if clay.Hovered() do ctx.hovered_widget = option_id

					textlabel(option, {textColor = color, fontSize = text_size})

					horz_spacer(ctx, 8)

					if selection_icon_id, ok := selection_icon_id.?; ok && idx == selected^ {
						icon(ctx, selection_icon_id, {int(text_size), int(text_size)}, color)
					}

					if clay.Hovered() && .LEFT in ctx.mouse_pressed {
						selected^ = idx
						res += {.CHANGE}
					}
				}
			}
		}
	}
	return
}

horz_spacer :: proc(ctx: ^Context, size: c.float) {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(size), clay.SizingGrow()}}}) {}
}

vert_spacer :: proc(ctx: ^Context, size: c.float) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(size)}}}) {}
}

when ODIN_DEBUG {
	memory_debug :: proc(ctx: ^Context, tracking_allocator: mem.Tracking_Allocator) {
		if .M in ctx.keys_pressed && .CTRL in ctx.keys_down {
			if .MEMORY_DEBUG in ctx.statuses {
				ctx.statuses -= {.MEMORY_DEBUG}
			} else {
				ctx.statuses += {.MEMORY_DEBUG}
			}
		}
		if .MEMORY_DEBUG not_in ctx.statuses do return

		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingPercent(0.8), clay.SizingFit()},
				childAlignment = {x = .Center, y = .Center},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(16),
				childGap = 16,
			},
			floating = {
				attachment = {element = .CenterCenter, parent = .CenterCenter},
				attachTo = .Root,
			},
			backgroundColor = {0, 0, 0, 255},
			cornerRadius = clay.CornerRadiusAll(10),
		},
		) {
			textlabel("Memory Debug", {textColor = 255, fontSize = 20})
			textlabel(
				fmt.tprintf("Peak Allocation: %v", tracking_allocator.peak_memory_allocated),
				{textColor = 255, fontSize = 16},
			)
			textlabel(
				fmt.tprintf("Current Allocation: %v", tracking_allocator.current_memory_allocated),
				{textColor = 255, fontSize = 16},
			)
			textlabel(
				fmt.tprintf("Total Allocations: %v", tracking_allocator.total_allocation_count),
				{textColor = 255, fontSize = 16},
			)
			textlabel(
				fmt.tprintf("Total Frees: %v", tracking_allocator.total_free_count),
				{textColor = 255, fontSize = 16},
			)
			textlabel(
				fmt.tprintf(
					"Δ Frees: %v",
					tracking_allocator.total_allocation_count -
					tracking_allocator.total_free_count,
				),
				{textColor = 255, fontSize = 16},
			)
			id := clay.ID("memory_debug_list")
			if clay.UI()({id = id, layout = {sizing = {width = clay.SizingPercent(1)}}}) {
				data := clay.GetElementData(id)
				bounding_box := data.boundingBox

				total_log_size: f32
				for ptr, entry in tracking_allocator.allocation_map {
					_, mem_entry, just_inserted, _ := map_entry(&ctx.memory_debug.memory, ptr)
					if just_inserted {
						mem_entry.color = clay.Color {
							rand.float32_range(10, 230),
							rand.float32_range(10, 230),
							rand.float32_range(10, 230),
							235,
						}
					}

					mem_entry.log_size = math.log10(f32(entry.size))
					total_log_size += mem_entry.log_size
				}

				for ptr, entry in tracking_allocator.allocation_map {
					mem_entry := ctx.memory_debug.memory[ptr]
					entry_width := (mem_entry.log_size / total_log_size) * bounding_box.width
					if clay.UI()(
					{
						layout = {sizing = {clay.SizingFixed(entry_width), clay.SizingFixed(24)}},
						border = clay.Hovered() ? {color = 255, width = clay.BorderAll(1)} : {},
						backgroundColor = mem_entry.color * (clay.Hovered() ? 1.2 : 1),
					},
					) {
						if clay.Hovered() {
							info_id := clay.ID("memory_debug_list_info")
							info_info := clay.GetElementData(info_id)

							info_bounding_box := info_info.boundingBox
							max_x := info_bounding_box.width + info_bounding_box.x
							min_x := info_bounding_box.x
							x_offset: f32
							if max_x > ctx.window_size.x {
								x_offset = -(max_x - ctx.window_size.x) - 4
							} else if min_x < 0 {
								x_offset = -min_x + 4
							}

							if clay.UI()(
							{
								id = info_id,
								layout = {
									layoutDirection = .TopToBottom,
									childAlignment = {x = .Center},
									padding = clay.PaddingAll(4),
								},
								floating = {
									attachment = {element = .CenterTop, parent = .CenterBottom},
									attachTo = .Parent,
									pointerCaptureMode = .Passthrough,
									offset = {x_offset, 4},
								},
								backgroundColor = clay.Color{35, 35, 35, 255},
							},
							) {
								textlabel(fmt.tprintf("%v", ptr), {textColor = 255, fontSize = 16})
								textlabel(
									fmt.tprintf("Size: %v", entry.size),
									{textColor = 255, fontSize = 16},
								)
								textlabel(
									fmt.tprintf("%v", entry.location),
									{textColor = 255, fontSize = 16},
								)
							}
						}
					}
				}
			}
		}
		return
	}
}
