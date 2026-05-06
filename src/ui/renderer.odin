package ui

import "clay"
import "core:c"
import "core:hash"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

BUFFER_INIT_SIZE :: 128
CELL_PIXEL_SCALE :: 100
Renderer :: struct {
	pipeline:     Pipeline,
	commands:     [dynamic]Command,
	prev_buckets: [dynamic]u32,
	cells:        [dynamic]u32,
	cell_wh:      [2]int,
	cell_tl:      [2]int,
	cell_br:      [2]int,
}

Pipeline_Status :: enum {
	TEXTURE_DIRTY,
}
Pipeline_Statuses :: bit_set[Pipeline_Status]

Renderer_init :: proc(ctx: ^Context) {
	VERT :: #load("resources/shaders/compiled/ui.vert.spv")
	FRAG :: #load("resources/shaders/compiled/ui.frag.spv")

	vert_info := sdl.GPUShaderCreateInfo {
		code_size           = len(VERT),
		code                = raw_data(VERT),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	}
	vert_shader := sdl.CreateGPUShader(ctx.device, vert_info)
	defer sdl.ReleaseGPUShader(ctx.device, vert_shader)

	frag_info := sdl.GPUShaderCreateInfo {
		code_size    = len(FRAG),
		code         = raw_data(FRAG),
		entrypoint   = "main",
		format       = {.SPIRV},
		stage        = .FRAGMENT,
		num_samplers = 1,
	}
	frag_shader := sdl.CreateGPUShader(ctx.device, frag_info)
	defer sdl.ReleaseGPUShader(ctx.device, frag_shader)


	

	// odinfmt:disable
	vert_attrs := []sdl.GPUVertexAttribute {
		{buffer_slot = 0, location = 0, format = .FLOAT4, offset = u32(offset_of(Quad, pos_scale))}, // i_pos_scale
		{buffer_slot = 0, location = 1, format = .FLOAT4, offset = u32(offset_of(Quad, corners))}, // i_corners
		{buffer_slot = 0, location = 2, format = .FLOAT4, offset = u32(offset_of(Quad, color))}, // i_color
		{buffer_slot = 0, location = 3, format = .FLOAT4, offset = u32(offset_of(Quad, border_color))}, // i_border_color
		{buffer_slot = 0, location = 4, format = .FLOAT, offset = u32(offset_of(Quad, border_width))}, // i_border_width
		{buffer_slot = 0, location = 5, format = .FLOAT2, offset = u32(offset_of(Instance, text_pos))}, // i_text_pos
		{buffer_slot = 0, location = 6, format = .FLOAT, offset = u32(offset_of(Instance, type))}, // i_type
		{buffer_slot = 1, location = 7, format = .FLOAT4, offset = u32(offset_of(Text_Vert, pos_uv))}, // i_text_pos_uv
		{buffer_slot = 1, location = 8, format = .FLOAT4, offset = u32(offset_of(Text_Vert, color))}, // i_text_color
	}
  // odinfmt:enable

	vertex_buffers := []sdl.GPUVertexBufferDescription {
		{slot = 0, input_rate = .INSTANCE, pitch = size_of(Instance)},
		{slot = 1, input_rate = .VERTEX, pitch = size_of(Text_Vert)},
	}

	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vert_shader,
		fragment_shader = frag_shader,
		primitive_type = .TRIANGLELIST,
		target_info = {
			color_target_descriptions = &sdl.GPUColorTargetDescription {
				format = sdl.GetGPUSwapchainTextureFormat(ctx.device, ctx.window),
				blend_state = {
					src_color_blendfactor = .SRC_ALPHA,
					dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
					color_blend_op = .ADD,
					src_alpha_blendfactor = .ONE,
					dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
					alpha_blend_op = .ADD,
					color_write_mask = {.R, .G, .B, .A},
					enable_blend = true,
					enable_color_write_mask = true,
				},
			},
			num_color_targets = 1,
		},
		vertex_input_state = {
			vertex_buffer_descriptions = raw_data(vertex_buffers),
			num_vertex_buffers = u32(len(vertex_buffers)),
			vertex_attributes = raw_data(vert_attrs),
			num_vertex_attributes = u32(len(vert_attrs)),
		},
	}

	ctx.renderer.pipeline.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.device, pipeline_info)
	ctx.renderer.pipeline.texture_sampler = sdl.CreateGPUSampler(
		ctx.device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	)
	ctx.renderer.pipeline.text_engine = ttf.CreateGPUTextEngine(ctx.device)
	ttf.SetGPUTextEngineWinding(ctx.renderer.pipeline.text_engine, .COUNTER_CLOCKWISE)
	ctx.renderer.pipeline.instance_buffer = create_buffer(
		ctx.device,
		size_of(Instance) * BUFFER_INIT_SIZE,
		{.VERTEX},
	)
	ctx.renderer.pipeline.text_vertex_buffer = create_buffer(
		ctx.device,
		size_of(Text_Vert) * BUFFER_INIT_SIZE,
		{.VERTEX},
	)
	ctx.renderer.pipeline.text_index_buffer = create_buffer(
		ctx.device,
		size_of(i32) * BUFFER_INIT_SIZE,
		{.INDEX},
	)
	ctx.renderer.pipeline.texture_buffer = sdl.CreateGPUTransferBuffer(
		ctx.device,
		sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = 128 * 128 * 4 * BUFFER_INIT_SIZE},
	)

	dummy_texture_info := sdl.GPUTextureCreateInfo {
		usage                = {.SAMPLER},
		width                = 1,
		height               = 1,
		layer_count_or_depth = 1,
		num_levels           = 1,
		format               = .R8G8B8A8_UNORM,
	}
	ctx.renderer.pipeline.dummy_texture = sdl.CreateGPUTexture(ctx.device, dummy_texture_info)

	n_cells := _num_cells(ctx)
	ctx.renderer.prev_buckets = make([dynamic]u32, 0, n_cells.x * n_cells.y)
	ctx.renderer.cells = make([dynamic]u32, 0, n_cells.x * n_cells.y)
	_resize_cells(ctx)
}

_num_cells :: proc(ctx: ^Context) -> [2]int {
	x := int(ctx.window_size.x / CELL_PIXEL_SCALE)
	y := int(ctx.window_size.y / CELL_PIXEL_SCALE)
	return {x, y}
}

_resize_cells :: proc(ctx: ^Context) {
	ctx.renderer.cell_wh = _num_cells(ctx)
	ctx.renderer.prev_buckets, ctx.renderer.cells = ctx.renderer.cells, ctx.renderer.prev_buckets
	resize(&ctx.renderer.cells, (ctx.renderer.cell_wh.x + 1) * (ctx.renderer.cell_wh.y + 1))
}

Renderer_destroy :: proc(ctx: ^Context) {
	destroy_buffer(ctx.device, &ctx.renderer.pipeline.instance_buffer)
	destroy_buffer(ctx.device, &ctx.renderer.pipeline.text_index_buffer)
	destroy_buffer(ctx.device, &ctx.renderer.pipeline.text_vertex_buffer)
	sdl.ReleaseGPUTransferBuffer(ctx.device, ctx.renderer.pipeline.texture_buffer)
	if ctx.renderer.pipeline.color_target != nil {
		sdl.ReleaseGPUTexture(ctx.device, ctx.renderer.pipeline.color_target)
	}
	sdl.ReleaseGPUGraphicsPipeline(ctx.device, ctx.renderer.pipeline.pipeline)
	delete(ctx.renderer.commands)
	delete(ctx.renderer.cells)
	delete(ctx.renderer.prev_buckets)
}

_update_overlapping_cells :: proc(renderer: ^Renderer, bb: clay.BoundingBox, h: ^u32) {
	tl := [2]int{int(bb.x), int(bb.y)}
	br := tl + [2]int{int(bb.width), int(bb.height)}
	h_slice := slice.bytes_from_ptr(h, size_of(u32))

	cell_tl := tl / CELL_PIXEL_SCALE
	cell_br := br / CELL_PIXEL_SCALE
	for y in cell_tl.y ..= cell_br.y {
		for x in cell_tl.x ..= cell_br.x {
			x := clamp(x, 0, renderer.cell_wh.x)
			y := clamp(y, 0, renderer.cell_wh.y)
			renderer.cells[x + y * renderer.cell_wh.x] = hash.fnv32a(
				h_slice,
				renderer.cells[x + y * renderer.cell_wh.x],
			)
		}
	}
}

Renderer_should_redraw :: proc(
	ctx: ^Context,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
) -> bool {
	if .WINDOW_RESIZED in ctx.statuses {
		_resize_cells(ctx)
		ctx.renderer.cell_tl = 0
		ctx.renderer.cell_br = ctx.renderer.cell_wh
		return true
	}
	_resize_cells(ctx)
	slice.zero(ctx.renderer.cells[:])

	for i in 0 ..< i32(render_commands.length) {
		cmd := clay.RenderCommandArray_Get(render_commands, i)
		bounds := cmd.boundingBox

		cmd_bytes := slice.bytes_from_ptr(cmd, size_of(clay.RenderCommand))
		h := hash.fnv32a(cmd_bytes)
		_update_overlapping_cells(&ctx.renderer, bounds, &h)
	}

	cell_tl := [2]int{ctx.renderer.cell_wh.x, ctx.renderer.cell_wh.y}
	cell_br := [2]int{0, 0}
	cells_match := true
	find_cell_mismatch: for y in 0 ..= ctx.renderer.cell_wh.y {
		for x in 0 ..= ctx.renderer.cell_wh.x {
			idx := x + y * ctx.renderer.cell_wh.x
			if len(ctx.renderer.cells) != len(ctx.renderer.prev_buckets) {
				cells_match = false
				cell_tl = 0
				cell_br = ctx.renderer.cell_wh
				break find_cell_mismatch
			}
			if ctx.renderer.cells[idx] != ctx.renderer.prev_buckets[idx] {
				cells_match = false
				cell_tl.x = min(cell_tl.x, x)
				cell_tl.y = min(cell_tl.y, y)
				cell_br.x = max(cell_br.x, x)
				cell_br.y = max(cell_br.y, y)
			}
		}
	}
	ctx.renderer.cell_tl = cell_tl
	ctx.renderer.cell_br = cell_br
	return !cells_match
}

Renderer_draw :: proc(
	ctx: ^Context,
	cmd_buffer: ^sdl.GPUCommandBuffer,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	clear(&ctx.renderer.commands)
	overlay_colors := make([dynamic]clay.Color, allocator)

	clamp_corners :: proc(cr: clay.CornerRadius, bounds: clay.BoundingBox) -> clay.CornerRadius {
		return clay.CornerRadius {
			topLeft = clamp(cr.topLeft, 0, min(bounds.width, bounds.height) / 2),
			topRight = clamp(cr.topRight, 0, min(bounds.width, bounds.height) / 2),
			bottomLeft = clamp(cr.bottomLeft, 0, min(bounds.width, bounds.height) / 2),
			bottomRight = clamp(cr.bottomRight, 0, min(bounds.width, bounds.height) / 2),
		}
	}

	pixel_tl_int := ctx.renderer.cell_tl * CELL_PIXEL_SCALE
	pixel_br_int := (ctx.renderer.cell_br + 1) * CELL_PIXEL_SCALE
	pixel_tl := [2]f32{f32(pixel_tl_int.x), f32(pixel_tl_int.y)} * ctx.scaling
	pixel_br := [2]f32{f32(pixel_br_int.x), f32(pixel_br_int.y)} * ctx.scaling
	pixel_wh := pixel_br - pixel_tl
	append(
		&ctx.renderer.commands,
		ScissorStart{i32(pixel_tl.x), i32(pixel_tl.y), i32(pixel_wh.x), i32(pixel_wh.y)},
	)

	for i in 0 ..< i32(render_commands.length) {
		cmd := clay.RenderCommandArray_Get(render_commands, i)
		bounds := cmd.boundingBox

		#partial switch cmd.commandType {
		case .Rectangle:
			config := cmd.renderData.rectangle
			color := f32_color(config.backgroundColor)
			cr := clamp_corners(config.cornerRadius, bounds)
			widget_data := transmute(Data_Flags)cmd.userData
			if .SHADOW in widget_data {
				append(
					&ctx.renderer.commands,
					Shadow {
						pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
						corners = {cr.topLeft, cr.topRight, cr.bottomLeft, cr.bottomRight},
						color = color,
					},
				)
			} else {
				append(
					&ctx.renderer.commands,
					Quad {
						pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
						corners = {cr.topLeft, cr.topRight, cr.bottomLeft, cr.bottomRight},
						color = color,
					},
				)
			}
		case .Border:
			config := cmd.renderData.border
			color := f32_color(config.color)
			cr := clamp_corners(config.cornerRadius, bounds)
			append(
				&ctx.renderer.commands,
				Quad {
					pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
					corners = {cr.topLeft, cr.topRight, cr.bottomLeft, cr.bottomRight},
					border_color = color,
					border_width = f32(config.width.top),
				},
			)
		case .Text:
			config := cmd.renderData.text
			font := retrieve_font(ctx, config.fontId, u16(c.float(config.fontSize) * ctx.scaling))
			text := string(config.stringContents.chars[:config.stringContents.length])
			c_text := strings.clone_to_cstring(text, allocator)
			sdl_text := ttf.CreateText(ctx.renderer.pipeline.text_engine, font, c_text, 0)
			append(
				&ctx.renderer.commands,
				Text{sdl_text, {bounds.x, bounds.y}, f32_color(config.textColor)},
			)
		case .ScissorStart:
			append(
				&ctx.renderer.commands,
				ScissorStart {
					c.int(bounds.x * ctx.scaling),
					c.int(bounds.y * ctx.scaling),
					c.int(bounds.width * ctx.scaling),
					c.int(bounds.height * ctx.scaling),
				},
			)
		case .ScissorEnd:
			append(&ctx.renderer.commands, ScissorEnd{})
		case .Image:
			config := cmd.renderData.image

			if config.backgroundColor == {} {
				config.backgroundColor = 255
			}

			image := R_Image {
				pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
				img       = cast(^_Image)config.imageData,
				color     = f32_color(overlay_colors[len(overlay_colors) - 1]),
			}
			append(&ctx.renderer.commands, image)
		case .OverlayColorStart:
			config := cmd.renderData.overlayColor
			append(&overlay_colors, config.color)
		case .OverlayColorEnd:
			pop(&overlay_colors)
		case .Custom:
		case .None:
		}
	}
	append(&ctx.renderer.commands, ScissorEnd{})

	// upload to gpu
	{
		copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)
		defer sdl.EndGPUCopyPass(copy_pass)

		instances := make([dynamic]Instance, 0, len(ctx.renderer.commands), allocator)
		text_vertices := make([dynamic]Text_Vert, 0, len(ctx.renderer.commands), allocator)
		text_indices := make([dynamic]c.int, 0, len(ctx.renderer.commands), allocator)
		textures := make([dynamic]^_Image, 0, len(ctx.renderer.commands), allocator)
		curr_texture_buffer_size: int

		for command in ctx.renderer.commands {
			#partial switch cmd in command {
			case R_Image:
				append(
					&instances,
					Instance{quad = {pos_scale = cmd.pos_scale, color = cmd.color}, type = 2},
				)
				append(&textures, cmd.img)
				curr_texture_buffer_size += cmd.img.size
			case Text:
				for data := ttf.GetGPUTextDrawData(cmd.ref); data != nil; data = data.next {
					for i in 0 ..< data.num_vertices {
						pos := data.xy[i]
						uv := data.uv[i]
						append(&text_vertices, Text_Vert{{pos.x, -pos.y, uv.x, uv.y}, cmd.color})
					}
					append(&text_indices, ..data.indices[:data.num_indices])
				}
				append(&instances, Instance{text_pos = cmd.pos, type = 1})
			case Quad:
				append(&instances, Instance{quad = cmd, type = 0})
			case Shadow:
				append(&instances, Instance{quad = Quad(cmd), type = 3})
			}
		}

		// instances
		{
			size := u32(len(instances) * size_of(Instance))
			resize_buffer(ctx.device, &ctx.renderer.pipeline.instance_buffer, size, {.VERTEX})

			i_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.instance_buffer.transfer,
				false,
			)
			mem.copy(i_array, raw_data(instances), int(size))
			sdl.UnmapGPUTransferBuffer(ctx.device, ctx.renderer.pipeline.instance_buffer.transfer)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = ctx.renderer.pipeline.instance_buffer.transfer},
				{buffer = ctx.renderer.pipeline.instance_buffer.gpu, size = size},
				false,
			)
		}

		// text
		{
			vert_size := u32(len(text_vertices) * size_of(Text_Vert))
			indices_size := u32(len(text_indices) * size_of(c.int))

			resize_buffer(
				ctx.device,
				&ctx.renderer.pipeline.text_vertex_buffer,
				vert_size,
				{.VERTEX},
			)
			resize_buffer(
				ctx.device,
				&ctx.renderer.pipeline.text_index_buffer,
				indices_size,
				{.INDEX},
			)

			vertex_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.text_vertex_buffer.transfer,
				false,
			)
			mem.copy(vertex_array, raw_data(text_vertices), int(vert_size))
			sdl.UnmapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.text_vertex_buffer.transfer,
			)

			index_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.text_index_buffer.transfer,
				false,
			)
			mem.copy(index_array, raw_data(text_indices), int(indices_size))
			sdl.UnmapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.text_index_buffer.transfer,
			)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = ctx.renderer.pipeline.text_vertex_buffer.transfer},
				{
					buffer = ctx.renderer.pipeline.text_vertex_buffer.gpu,
					offset = 0,
					size = vert_size,
				},
				false,
			)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = ctx.renderer.pipeline.text_index_buffer.transfer},
				{
					buffer = ctx.renderer.pipeline.text_index_buffer.gpu,
					offset = 0,
					size = indices_size,
				},
				false,
			)
		}

		// textures
		if .TEXTURE_DIRTY in ctx.renderer.pipeline.status {
			if curr_texture_buffer_size > ctx.renderer.pipeline.texture_buffer_size {
				sdl.ReleaseGPUTransferBuffer(ctx.device, ctx.renderer.pipeline.texture_buffer)
				ctx.renderer.pipeline.texture_buffer = sdl.CreateGPUTransferBuffer(
					ctx.device,
					sdl.GPUTransferBufferCreateInfo {
						usage = .UPLOAD,
						size = max(BUFFER_INIT_SIZE, u32(curr_texture_buffer_size)),
					},
				)
				ctx.renderer.pipeline.texture_buffer_size = curr_texture_buffer_size
			}

			transfer_offset := 0
			texture_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				ctx.renderer.pipeline.texture_buffer,
				false,
			)
			for texture in textures {
				mem.copy(
					mem.ptr_offset(cast(^u8)texture_array, transfer_offset),
					texture.surface.pixels,
					texture.size,
				)
				transfer_offset += texture.size
			}
			sdl.UnmapGPUTransferBuffer(ctx.device, ctx.renderer.pipeline.texture_buffer)

			transfer_offset = 0
			for texture in textures {
				sdl.UploadToGPUTexture(
					copy_pass,
					{
						transfer_buffer = ctx.renderer.pipeline.texture_buffer,
						offset = u32(transfer_offset),
					},
					{
						texture = texture.texture,
						w = u32(texture.surface.w),
						h = u32(texture.surface.h),
						d = 1,
					},
					false,
				)
				transfer_offset += texture.size
			}
		}
	}

	// render
	swapchain_texture: ^sdl.GPUTexture
	w, h: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buffer, ctx.window, &swapchain_texture, &w, &h) {
		log.error("failed to acquire swapchain texture")
		return
	}
	if swapchain_texture == nil {
		log.error("swapchain texture is nil")
		return
	}

	if swapchain_texture != nil {
		color_load_op: sdl.GPULoadOp = .LOAD
		if ctx.renderer.pipeline.color_target == nil ||
		   ctx.renderer.pipeline.color_target_size != ([2]u32{w, h}) {
			if ctx.renderer.pipeline.color_target != nil {
				sdl.ReleaseGPUTexture(ctx.device, ctx.renderer.pipeline.color_target)
			}
			ctx.renderer.pipeline.color_target = sdl.CreateGPUTexture(
				ctx.device,
				sdl.GPUTextureCreateInfo {
					usage = {.COLOR_TARGET, .SAMPLER},
					width = w,
					height = h,
					layer_count_or_depth = 1,
					num_levels = 1,
					format = sdl.GetGPUSwapchainTextureFormat(ctx.device, ctx.window),
				},
			)
			ctx.renderer.pipeline.color_target_size = {w, h}
			color_load_op = .CLEAR
		}

		{
			render_pass := sdl.BeginGPURenderPass(
				cmd_buffer,
				&sdl.GPUColorTargetInfo {
					texture = ctx.renderer.pipeline.color_target,
					load_op = color_load_op,
					store_op = .STORE,
				},
				1,
				nil,
			)
			defer sdl.EndGPURenderPass(render_pass)

			// binding
			{
				sdl.BindGPUGraphicsPipeline(render_pass, ctx.renderer.pipeline.pipeline)
				vertex_buffer_bindings := []sdl.GPUBufferBinding {
					{buffer = ctx.renderer.pipeline.instance_buffer.gpu},
					{buffer = ctx.renderer.pipeline.text_vertex_buffer.gpu},
				}
				sdl.BindGPUVertexBuffers(
					render_pass,
					0,
					raw_data(vertex_buffer_bindings),
					u32(len(vertex_buffer_bindings)),
				)
				sdl.BindGPUIndexBuffer(
					render_pass,
					{buffer = ctx.renderer.pipeline.text_index_buffer.gpu},
					._32BIT,
				)

				sdl.BindGPUFragmentSamplers(
					render_pass,
					0,
					&sdl.GPUTextureSamplerBinding {
						texture = ctx.renderer.pipeline.dummy_texture,
						sampler = ctx.renderer.pipeline.texture_sampler,
					},
					1,
				)
			}

			push_globals(ctx, cmd_buffer, f32(w), f32(h))

			atlas: ^sdl.GPUTexture
			instance_offset, text_index_offset: u32
			text_vertex_offset: i32

			scissor_stack := make([dynamic]sdl.Rect, allocator)
			for command in ctx.renderer.commands {
				#partial switch cmd in command {
				case ScissorStart:
					rect := sdl.Rect(cmd)
					if parent, ok := slice.get(scissor_stack[:], len(scissor_stack) - 1); ok {
						rect = intersect_rect(rect, parent)
					}
					sdl.SetGPUScissor(render_pass, rect)
					append(&scissor_stack, rect)
				case ScissorEnd:
					pop(&scissor_stack)
					if scissor_top, ok := slice.get(scissor_stack[:], len(scissor_stack) - 1); ok {
						sdl.SetGPUScissor(render_pass, scissor_top)
					} else {
						sdl.SetGPUScissor(render_pass, {0, 0, i32(w), i32(h)})
					}
				case R_Image:
					sdl.BindGPUFragmentSamplers(
						render_pass,
						0,
						&sdl.GPUTextureSamplerBinding {
							texture = cmd.img.texture,
							sampler = ctx.renderer.pipeline.texture_sampler,
						},
						1,
					)
					atlas = cmd.img.texture
					sdl.DrawGPUPrimitives(render_pass, 6, 1, 0, instance_offset)
					instance_offset += 1
				case Text:
					for data := ttf.GetGPUTextDrawData(cmd.ref); data != nil; data = data.next {
						if data.atlas_texture != atlas {
							sdl.BindGPUFragmentSamplers(
								render_pass,
								0,
								&sdl.GPUTextureSamplerBinding {
									texture = data.atlas_texture,
									sampler = ctx.renderer.pipeline.texture_sampler,
								},
								1,
							)
							atlas = data.atlas_texture
						}

						sdl.DrawGPUIndexedPrimitives(
							render_pass,
							u32(data.num_indices),
							1,
							text_index_offset,
							text_vertex_offset,
							instance_offset,
						)

						text_index_offset += u32(data.num_indices)
						text_vertex_offset += data.num_vertices
					}
					instance_offset += 1
				case Quad, Shadow:
					sdl.DrawGPUPrimitives(render_pass, 6, 1, 0, instance_offset)
					instance_offset += 1
				}
			}
		}

		sdl.BlitGPUTexture(
			cmd_buffer,
			sdl.GPUBlitInfo {
				source = {texture = ctx.renderer.pipeline.color_target, w = w, h = h},
				destination = {texture = swapchain_texture, w = w, h = h},
				load_op = .DONT_CARE,
				filter = .NEAREST,
			},
		)
	}

	// text cleanup -- [TODO] caching
	{
		for command in ctx.renderer.commands {
			#partial switch cmd in command {
			case Text:
				ttf.DestroyText(cmd.ref)
			}
		}
	}
}

ScissorStart :: sdl.Rect
ScissorEnd :: struct {}

intersect_rect :: proc(a, b: sdl.Rect) -> sdl.Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

Command :: union {
	Text,
	Quad,
	R_Image,
	Shadow,
	ScissorStart,
	ScissorEnd,
}

R_Image :: distinct struct #packed {
	pos_scale: [4]f32,
	color:     [4]f32,
	img:       ^_Image,
}

Text_Vert :: struct #packed {
	pos_uv: [4]f32,
	color:  [4]f32,
}

Text :: struct {
	ref:   ^ttf.Text,
	pos:   [2]f32,
	color: [4]f32,
}

Shadow :: distinct Quad

Quad :: struct #packed {
	pos_scale:    [4]f32,
	corners:      [4]f32,
	color:        [4]f32,
	border_color: [4]f32,
	border_width: f32,
}

Instance :: struct #packed {
	quad:     Quad,
	text_pos: [2]f32,
	type:     f32,
}

Pipeline :: struct {
	pipeline:            ^sdl.GPUGraphicsPipeline,
	text_vertex_buffer:  Buffer,
	text_index_buffer:   Buffer,
	instance_buffer:     Buffer,
	texture_buffer:      ^sdl.GPUTransferBuffer,
	texture_buffer_size: int,
	text_engine:         ^ttf.TextEngine,
	texture_sampler:     ^sdl.GPUSampler,
	dummy_texture:       ^sdl.GPUTexture,
	color_target:        ^sdl.GPUTexture,
	color_target_size:   [2]u32,
	status:              Pipeline_Statuses,
}

f32_color :: proc(color: clay.Color) -> [4]f32 {
	unscaled_color := [4]f32{color.r, color.g, color.b, color.a}
	return unscaled_color / 255
}

Globals :: struct {
	projection: matrix[4, 4]f32,
	scale:      f32,
}

ortho_rh :: proc(
	left: f32,
	right: f32,
	bottom: f32,
	top: f32,
	near: f32,
	far: f32,
) -> matrix[4, 4]f32 {
	return matrix[4, 4]f32{
		2.0 / (right - left), 0.0, 0.0, -(right + left) / (right - left),
		0.0, 2.0 / (top - bottom), 0.0, -(top + bottom) / (top - bottom),
		0.0, 0.0, -2.0 / (far - near), -(far + near) / (far - near),
		0.0, 0.0, 0.0, 1.0,
	}
}

push_globals :: proc(ctx: ^Context, cmd_buffer: ^sdl.GPUCommandBuffer, w: f32, h: f32) {
	globals := Globals {
		ortho_rh(left = 0.0, top = 0.0, right = f32(w), bottom = f32(h), near = -1.0, far = 1.0),
		ctx.scaling,
	}
	sdl.PushGPUVertexUniformData(cmd_buffer, 0, &globals, size_of(Globals))
}

Buffer :: struct {
	gpu:      ^sdl.GPUBuffer,
	transfer: ^sdl.GPUTransferBuffer,
	size:     u32,
}

create_buffer :: proc(
	device: ^sdl.GPUDevice,
	size: u32,
	gpu_usage: sdl.GPUBufferUsageFlags,
) -> Buffer {
	return Buffer {
		gpu = sdl.CreateGPUBuffer(device, sdl.GPUBufferCreateInfo{usage = gpu_usage, size = size}),
		transfer = sdl.CreateGPUTransferBuffer(
			device,
			sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = size},
		),
		size = size,
	}
}

resize_buffer :: proc(
	device: ^sdl.GPUDevice,
	buffer: ^Buffer,
	new_size: u32,
	gpu_usage: sdl.GPUBufferUsageFlags,
) {
	if new_size > buffer.size {
		log.debug("Resizing buffer from", buffer.size, "to", new_size)
		destroy_buffer(device, buffer)
		buffer.gpu = sdl.CreateGPUBuffer(
			device,
			sdl.GPUBufferCreateInfo{usage = gpu_usage, size = new_size},
		)
		buffer.transfer = sdl.CreateGPUTransferBuffer(
			device,
			sdl.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = new_size},
		)
		buffer.size = new_size
	}
}

destroy_buffer :: proc(device: ^sdl.GPUDevice, buffer: ^Buffer) {
	sdl.ReleaseGPUBuffer(device, buffer.gpu)
	sdl.ReleaseGPUTransferBuffer(device, buffer.transfer)
}
