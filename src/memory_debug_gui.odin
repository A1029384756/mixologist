package mixologist

import "./clay"
import "core:fmt"

when ODIN_DEBUG {
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
				attachment = {element = .LeftTop, parent = .LeftTop},
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
		}
		return
	}
}
