package mixologist_gui

import "./clay"
import rl "./raylib"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os/os2"
import "core:strings"
import "core:sys/linux"
import "core:text/edit"

EVENT_SIZE :: size_of(linux.Inotify_Event)
EVENT_BUF_LEN :: 1024 * (EVENT_SIZE + 16)
DOUBLE_CLICK_INTERVAL_MS :: 300

Context_Status :: enum {
	TEXTBOX_SELECTED,
	TEXTBOX_HOVERING,
	BUTTON_HOVERING,
	BUTTON_HELD,
	RULES_UPDATED,
	DOUBLE_CLICKED,
	TRIPLE_CLICKED,
}
Context_Statuses :: bit_set[Context_Status]

Context :: struct {
	// text editing
	textbox_input:   strings.Builder,
	textbox_state:   edit.State,
	textbox_offset:  int,
	active_line:     [1024]u8,
	active_line_len: int,
	new_rule:        [1024]u8,
	new_rule_len:    int,
	active_widget:   clay.ElementId,
	// input handling
	_text_store:     [1024]u8, // global text input per frame
	click_count:     int,
	prev_click_time: f64,
	click_debounce:  f64,
	statuses:        Context_Statuses,
	// config state
	aux_rules:       [dynamic]string,
	config_file:     string,
	inotify_fd:      linux.Fd,
	inotify_wd:      linux.Wd,
	// allocations
	arena:           virtual.Arena,
	allocator:       mem.Allocator,
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
	// [TODO] find out why `ID_LOCAL` is producing duplicate id errors
	// context = runtime.default_context()
	// fmt.printfln("clay error detected: %s", errordata.errorText.chars[:errordata.errorText.length])
}

main :: proc() {
	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(800, 600, "Mixologist")
	defer rl.CloseWindow()
	rl.SetExitKey(.KEY_NULL)

	ctx: Context
	if virtual.arena_init_growing(&ctx.arena) != nil {
		panic("Couldn't initialize arena")
	}
	ctx.allocator = virtual.arena_allocator(&ctx.arena)
	ctx.textbox_state.set_clipboard = rl_set_clipboard
	ctx.textbox_state.get_clipboard = rl_get_clipboard
	ctx.textbox_input = strings.builder_from_bytes(ctx._text_store[:])

	// load config rules from disk
	{
		config_dir := os2.user_config_dir(ctx.allocator) or_else panic("config dir not found")
		config_dir = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist"},
			ctx.allocator,
		)
		if !os2.exists(config_dir) {
			os2.mkdir(config_dir)
		}

		ctx.config_file = strings.concatenate(
			{config_dir, os2.Path_Separator_String, "mixologist.conf"},
			ctx.allocator,
		)

		reload_config(&ctx)

		// set up config file watch
		{
			in_err: linux.Errno
			ctx.inotify_fd, in_err = linux.inotify_init1({.NONBLOCK})
			assert(in_err == nil)
			ctx.inotify_wd, in_err = linux.inotify_add_watch(
				ctx.inotify_fd,
				strings.clone_to_cstring(config_dir, ctx.allocator),
				{.CREATE, .DELETE, .MODIFY} + linux.IN_MOVE,
			)
			assert(in_err == nil)
		}
	}

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
		// rule reloading
		{
			inotify_buf: [EVENT_BUF_LEN]u8
			length, read_err := linux.read(ctx.inotify_fd, inotify_buf[:])
			assert(read_err == nil || read_err == .EAGAIN)

			config_modified := false
			for i := 0; i < length; {
				event := cast(^linux.Inotify_Event)&inotify_buf[i]

				if transmute(cstring)uintptr(&event.name) == "mixologist.conf" {
					config_modified = true
					break
				}

				i += EVENT_SIZE + int(event.len)
			}

			if config_modified {
				reload_config(&ctx)
			}
		}

		ctx.statuses -= {.TEXTBOX_HOVERING, .BUTTON_HOVERING}

		when ODIN_DEBUG {
			if rl.IsKeyPressed(.D) && rl.IsKeyDown(.LEFT_CONTROL) {
				clay.SetDebugModeEnabled(!clay.IsDebugModeEnabled())
			}
		}

		// mouse multi-click
		{
			current_time := rl.GetTime()
			if rl.IsMouseButtonPressed(.LEFT) {
				if (current_time - ctx.prev_click_time) <= DOUBLE_CLICK_INTERVAL_MS / 1000. {
					ctx.click_count += 1
				} else {
					ctx.click_count = 1
				}

				ctx.prev_click_time = current_time

				if ctx.click_count == 2 {
					ctx.statuses += {.DOUBLE_CLICKED}
				} else if ctx.click_count == 3 {
					ctx.statuses -= {.DOUBLE_CLICKED}
					ctx.statuses += {.TRIPLE_CLICKED}
				}
			} else if current_time - ctx.prev_click_time >= DOUBLE_CLICK_INTERVAL_MS / 1000. {
				ctx.statuses -= {.DOUBLE_CLICKED, .TRIPLE_CLICKED}
			}
		}

		// get global text input
		{
			strings.builder_reset(&ctx.textbox_input)
			for char := rl.GetCharPressed(); char != 0; char = rl.GetCharPressed() {
				strings.write_rune(&ctx.textbox_input, char)
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
		renderCommands := create_layout(&ctx)
		if ctx.statuses >= {.TEXTBOX_HOVERING, .TEXTBOX_SELECTED} {
			rl.SetMouseCursor(.IBEAM)
		} else if .BUTTON_HOVERING in ctx.statuses || .TEXTBOX_HOVERING in ctx.statuses {
			rl.SetMouseCursor(.POINTING_HAND)
		} else {
			rl.SetMouseCursor(.ARROW)
		}

		rl.BeginDrawing()
		clayRaylibRender(&renderCommands)
		rl.EndDrawing()

		if .RULES_UPDATED in ctx.statuses do save_rules(&ctx)
		if !(.TEXTBOX_SELECTED in ctx.statuses || .BUTTON_HELD in ctx.statuses) do ctx.active_widget = {}

		free_all(context.temp_allocator)
	}
}

reload_config :: proc(ctx: ^Context) {
	assert(len(ctx.config_file) > 0, "must load config before running")
	clear(&ctx.aux_rules)
	file_bytes, config_file_err := os2.read_entire_file(ctx.config_file, context.allocator)
	defer delete(file_bytes)

	file_string: string
	if config_file_err == nil {
		file_string = string(file_bytes)
	} else {
		fmt.println("could not get read file")
	}

	for line in strings.split_lines_iterator(&file_string) {
		append(&ctx.aux_rules, strings.clone(line))
	}
}

save_rules :: proc(ctx: ^Context) {
	// save out rules to file
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for rule in ctx.aux_rules {
		fmt.sbprintln(&builder, rule)
	}
	rules_file := strings.to_string(builder)
	write_err := os2.write_entire_file(ctx.config_file, transmute([]u8)rules_file)
	if write_err != nil {
		fmt.println("could not save out config file: %v", write_err)
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
			if clay.UI(
				clay.Layout(
					{
						layoutDirection = .LEFT_TO_RIGHT,
						sizing = {clay.SizingPercent(1), clay.SizingFixed(64)},
						padding = {16, 16},
						childAlignment = {y = .CENTER},
					},
				),
			) {
				// new rule textbox
				{
					placeholder_str := "New rule..."
					tb_res, tb_id := textbox(
						ctx,
						ctx.new_rule[:],
						&ctx.new_rule_len,
						placeholder_str,
						{textColor = TEXT, fontSize = 16},
						{sizing = {clay.SizingPercent(0.5), clay.SizingPercent(1)}},
						{color = SURFACE_1, cornerRadius = clay.CornerRadiusAll(5)},
						{color = MAUVE, width = 2},
						{5, 5},
						5,
					)

					active := tb_id == ctx.active_widget
					if .PRESS in tb_res {
						ctx.active_widget = tb_id
						if !active do ctx.new_rule_len = 0
						ctx.statuses += {.TEXTBOX_SELECTED}
					}

					if active && .HOVER in tb_res do ctx.statuses += {.TEXTBOX_HOVERING}
					else if !active && .HOVER in tb_res do ctx.statuses += {.BUTTON_HOVERING}

					if !(.HOVER in tb_res) && rl.IsMouseButtonPressed(.LEFT) {
						ctx.statuses -= {.TEXTBOX_SELECTED}
					}

					if .CANCEL in tb_res {
						ctx.active_widget = {}
					}

					if .SUBMIT in tb_res && ctx.new_rule_len > 0 {
						append(
							&ctx.aux_rules,
							strings.clone(string(ctx.new_rule[:ctx.new_rule_len])),
						)
						ctx.new_rule_len = 0
						ctx.active_widget = {}
						ctx.statuses += {.RULES_UPDATED}
					}

					spacer()

					button_res, button_id := text_button(
						ctx,
						"Add Rule",
						{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
						clay.CornerRadiusAll(5),
						SURFACE_2,
						SURFACE_1,
						SURFACE_0,
						TEXT,
						16,
						5,
					)

					if .HOVER in button_res do ctx.statuses += {.BUTTON_HOVERING}
					if .PRESS in button_res {
						ctx.active_widget = button_id
						ctx.statuses += {.BUTTON_HELD}
					}
					if .RELEASE in button_res {
						ctx.statuses -= {.BUTTON_HELD}
						if ctx.new_rule_len > 0 {
							append(
								&ctx.aux_rules,
								strings.clone(string(ctx.new_rule[:ctx.new_rule_len])),
							)
							ctx.new_rule_len = 0
							ctx.active_widget = {}
							ctx.statuses += {.RULES_UPDATED}
						}
					}
				}
			}
			for &elem, i in ctx.aux_rules do rule_line(ctx, &elem, i + 1)
		}
	}

	return clay.EndLayout()
}

rule_line :: proc(ctx: ^Context, entry: ^string, idx: int) {
	if clay.UI(
		clay.Layout(
			{
				layoutDirection = .LEFT_TO_RIGHT,
				sizing = {clay.SizingPercent(1), clay.SizingFixed(64)},
				padding = {16, 16},
				childAlignment = {y = .CENTER},
			},
		),
		clay.Rectangle({color = idx % 2 == 0 ? MANTLE : CRUST}),
	) {
		tb_res, tb_id := textbox(
			ctx,
			ctx.active_line[:],
			&ctx.active_line_len,
			entry^,
			{textColor = TEXT, fontSize = 16},
			{sizing = {clay.SizingPercent(0.5), clay.SizingPercent(1)}},
			{color = SURFACE_1, cornerRadius = clay.CornerRadiusAll(5)},
			{color = MAUVE, width = 2},
			{5, 5},
			5,
		)

		active := tb_id == ctx.active_widget
		if active {
			if .SUBMIT in tb_res {
				delete(entry^)
				if ctx.active_line_len == 0 {
					ordered_remove(&ctx.aux_rules, idx - 1)
				} else {
					entry^ = strings.clone(string(ctx.active_line[:ctx.active_line_len]))
				}
				ctx.active_widget = {}
				ctx.statuses += {.RULES_UPDATED}
			} else if .CANCEL in tb_res {
				ctx.active_widget = {}
			}
			if .PRESS in tb_res {
				ctx.active_widget = tb_id
				ctx.statuses += {.TEXTBOX_SELECTED}
			}
			if .HOVER in tb_res do ctx.statuses += {.TEXTBOX_HOVERING}
			if !(.HOVER in tb_res) && rl.IsMouseButtonPressed(.LEFT) {
				ctx.statuses -= {.TEXTBOX_SELECTED}
			}
		}

		spacer()

		button_res, button_id := text_button(
			ctx,
			"Edit",
			{sizing = {clay.SizingFit({}), clay.SizingFit({})}},
			clay.CornerRadiusAll(5),
			SURFACE_2,
			SURFACE_1,
			SURFACE_0,
			TEXT,
			16,
			5,
		)

		if .HOVER in button_res do ctx.statuses += {.BUTTON_HOVERING}
		if .PRESS in button_res {
			ctx.active_widget = button_id
			ctx.statuses += {.BUTTON_HELD}
		}
		if .RELEASE in button_res {
			ctx.statuses -= {.BUTTON_HELD}
			if active {
				delete(entry^)
				entry^ = strings.clone(string(ctx.active_line[:ctx.active_line_len]))
				ctx.active_widget = {}
				ctx.statuses += {.RULES_UPDATED}
			} else {
				ctx.active_widget = tb_id
				ctx.statuses += {.TEXTBOX_SELECTED}
				copy(ctx.active_line[:], entry^)
				ctx.active_line_len = len(entry)
			}
		}
	}
}
