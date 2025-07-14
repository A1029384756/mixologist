package mixologist

@(require) import "./clay"
@(require) import "core:fmt"
@(require) import "core:math"
@(require) import "core:math/rand"

when ODIN_DEBUG {
	MemEntry :: struct {
		log_size: f32,
		color:    clay.Color,
	}


	@(thread_local)
	memory: map[rawptr]MemEntry

	@(init)
	debug_menu_init :: proc() {
		memory = make(map[rawptr]MemEntry, 1e3)
	}

	@(fini)
	debug_menu_fini :: proc() {
		delete(memory)
	}

	memory_debug_modal :: proc(ctx: ^GUI_Context) {
		if .M in ctx.ui_ctx.keys_pressed && .CTRL in ctx.ui_ctx.keys_down {
			if .DEBUGGING in ctx.statuses {
				ctx.statuses -= {.DEBUGGING}
			} else {
				ctx.statuses += {.DEBUGGING}
			}
		}

		if .DEBUGGING in ctx.statuses {
			debug_menu(ctx)
		}
		return
	}

	debug_menu :: proc(ctx: ^GUI_Context) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingPercent(0.8), clay.SizingFit({})},
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
			UI_textlabel("Memory Debug", {textColor = TEXT, fontSize = 20})
			UI_textlabel(
				fmt.tprintf("Peak Allocation: %v", track.peak_memory_allocated),
				{textColor = TEXT, fontSize = 16},
			)
			UI_textlabel(
				fmt.tprintf("Current Allocation: %v", track.current_memory_allocated),
				{textColor = TEXT, fontSize = 16},
			)
			UI_textlabel(
				fmt.tprintf("Total Allocations: %v", track.total_allocation_count),
				{textColor = TEXT, fontSize = 16},
			)
			UI_textlabel(
				fmt.tprintf("Total Frees: %v", track.total_free_count),
				{textColor = TEXT, fontSize = 16},
			)
			UI_textlabel(
				fmt.tprintf("Δ Frees: %v", track.total_allocation_count - track.total_free_count),
				{textColor = TEXT, fontSize = 16},
			)
			id := clay.ID("memory_debug_list")
			if clay.UI()({id = id, layout = {sizing = {width = clay.SizingPercent(1)}}}) {
				data := clay.GetElementData(id)
				bounding_box := data.boundingBox

				total_log_size: f32
				for ptr, entry in track.allocation_map {
					_, mem_entry, just_inserted, _ := map_entry(&memory, ptr)
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

				for ptr, entry in track.allocation_map {
					mem_entry := memory[ptr]
					entry_width := (mem_entry.log_size / total_log_size) * bounding_box.width
					if clay.UI()(
					{
						layout = {sizing = {clay.SizingFixed(entry_width), clay.SizingFixed(24)}},
						border = clay.Hovered() ? {color = ROSEWATER, width = clay.BorderAll(1)} : {},
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
							if max_x > ctx.ui_ctx.window_size.x {
								x_offset = -(max_x - ctx.ui_ctx.window_size.x) - 4
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
								UI_textlabel(
									fmt.tprintf("%v", ptr),
									{textColor = TEXT, fontSize = 16},
								)
								UI_textlabel(
									fmt.tprintf("Size: %v", entry.size),
									{textColor = TEXT, fontSize = 16},
								)
								UI_textlabel(
									fmt.tprintf("%v", entry.location),
									{textColor = TEXT, fontSize = 16},
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
