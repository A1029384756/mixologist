package mixologist

@(require) import "./clay"
@(require) import "core:fmt"
@(require) import "core:math/rand"

when ODIN_DEBUG {
	@(thread_local)
	memory_colors: map[rawptr]clay.Color

	@(init)
	debug_menu_init :: proc() {
		memory_colors = make(map[rawptr]clay.Color, 1e3)
	}

	@(fini)
	debug_menu_fini :: proc() {
		delete(memory_colors)
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
				sizing = {clay.SizingFit({}), clay.SizingFit({})},
				childAlignment = {x = .Center, y = .Center},
				layoutDirection = .TopToBottom,
				padding = clay.PaddingAll(16),
				childGap = 16,
			},
			floating = {
				attachment = {element = .CenterCenter, parent = .CenterCenter},
				attachTo = .Root,
				offset = {16, 16},
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
			id := clay.ID_LOCAL("memory_debug_list")
			if clay.UI()({id = id, layout = {sizing = {width = clay.SizingGrow()}}}) {
				data := clay.GetElementData(id)
				if !data.found do return

				bounding_box := data.boundingBox
				for ptr, entry in track.allocation_map {
					_, color, just_inserted, _ := map_entry(&memory_colors, ptr)
					if just_inserted {
						color^ = clay.Color {
							rand.float32_range(10, 230),
							rand.float32_range(10, 230),
							rand.float32_range(10, 230),
							235,
						}
					}
					entry_width := bounding_box.width / f32(len(track.allocation_map))
					if clay.UI()(
					{
						layout = {sizing = {clay.SizingFixed(entry_width), clay.SizingFixed(24)}},
						border = clay.Hovered() ? {color = ROSEWATER, width = clay.BorderAll(1)} : {},
						backgroundColor = color^ * (clay.Hovered() ? 1.2 : 1),
					},
					) {
						if clay.Hovered() {
							if clay.UI()(
							{
								layout = {
									layoutDirection = .TopToBottom,
									childAlignment = {x = .Center},
									padding = clay.PaddingAll(4),
								},
								floating = {
									attachment = {element = .CenterTop, parent = .CenterBottom},
									attachTo = .Parent,
									pointerCaptureMode = .Capture,
									offset = {0, 4},
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
