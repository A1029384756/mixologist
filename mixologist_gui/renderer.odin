package mixologist_gui

import "clay"
import "core:c"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import ttf "sdl3_ttf"
import sdl "vendor:sdl3"

BUFFER_INIT_SIZE :: 256
pipeline: Pipeline
commands: [dynamic]Command

Renderer_init :: proc(ctx: ^UI_Context) {
	// create pipeline
	{
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

		vert_attrs := []sdl.GPUVertexAttribute {
			{buffer_slot = 0, location = 0, format = .FLOAT4, offset = 0 * size_of([4]f32)}, // i_pos_scale
			{buffer_slot = 0, location = 1, format = .FLOAT4, offset = 1 * size_of([4]f32)}, // i_corners
			{buffer_slot = 0, location = 2, format = .FLOAT4, offset = 2 * size_of([4]f32)}, // i_color
			{buffer_slot = 0, location = 3, format = .FLOAT4, offset = 3 * size_of([4]f32)}, // i_border_color
			{buffer_slot = 0, location = 4, format = .FLOAT, offset = 4 * size_of([4]f32)}, // i_border_width
			{buffer_slot = 0, location = 5, format = .FLOAT2, offset = 5 * size_of([4]f32)}, // i_text_pos
			{buffer_slot = 0, location = 6, format = .FLOAT, offset = 6 * size_of([4]f32)}, // i_type
			{buffer_slot = 1, location = 7, format = .FLOAT4, offset = 0 * size_of([4]f32)}, // i_text_pos_uv
			{buffer_slot = 1, location = 8, format = .FLOAT4, offset = 1 * size_of([4]f32)}, // i_text_color
		}
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

		pipeline.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.device, pipeline_info)
		pipeline.text_sampler = sdl.CreateGPUSampler(
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
		pipeline.text_engine = ttf.CreateGPUTextEngine(ctx.device)
		ttf.SetGPUTextEngineWinding(pipeline.text_engine, .COUNTER_CLOCKWISE)
		pipeline.instance_buffer = create_buffer(
			ctx.device,
			size_of(Instance) * BUFFER_INIT_SIZE,
			{.VERTEX},
		)
		pipeline.text_vertex_buffer = create_buffer(
			ctx.device,
			size_of(Text_Vert) * BUFFER_INIT_SIZE,
			{.VERTEX},
		)
		pipeline.text_index_buffer = create_buffer(
			ctx.device,
			size_of(i32) * BUFFER_INIT_SIZE,
			{.INDEX},
		)

		dummy_texture_info := sdl.GPUTextureCreateInfo {
			usage                = {.SAMPLER},
			width                = 1,
			height               = 1,
			layer_count_or_depth = 1,
			num_levels           = 1,
			format               = .R8G8B8A8_UNORM,
		}
		pipeline.dummy_texture = sdl.CreateGPUTexture(ctx.device, dummy_texture_info)
	}
}

Renderer_destroy :: proc(ctx: ^UI_Context) {
	destroy_buffer(ctx.device, &pipeline.instance_buffer)
	destroy_buffer(ctx.device, &pipeline.text_index_buffer)
	destroy_buffer(ctx.device, &pipeline.text_vertex_buffer)
	sdl.ReleaseGPUGraphicsPipeline(ctx.device, pipeline.pipeline)
	delete(commands)
}

Renderer_draw :: proc(
	ctx: ^UI_Context,
	cmd_buffer: ^sdl.GPUCommandBuffer,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	clear(&commands)

	for i in 0 ..< i32(render_commands.length) {
		cmd := clay.RenderCommandArray_Get(render_commands, i)
		bounds := cmd.boundingBox
		switch cmd.commandType {
		case .Rectangle:
			config := cmd.renderData.rectangle
			color := f32_color(config.backgroundColor)
			cr := config.cornerRadius
			append(
				&commands,
				Quad {
					pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
					corners = {cr.topLeft, cr.topRight, cr.bottomLeft, cr.bottomRight},
					color = color,
				},
			)
		case .Border:
			config := cmd.renderData.border
			color := f32_color(config.color)
			cr := config.cornerRadius
			append(
				&commands,
				Quad {
					pos_scale = {bounds.x, bounds.y, bounds.width, bounds.height},
					corners = {cr.topLeft, cr.topRight, cr.bottomLeft, cr.bottomRight},
					border_color = color,
					border_width = f32(config.width.top),
				},
			)
		case .Text:
			config := cmd.renderData.text
			font := UI_retrieve_font(
				ctx,
				config.fontId,
				u16(c.float(config.fontSize) * ctx.scaling),
			)
			text := string(config.stringContents.chars[:config.stringContents.length])
			c_text := strings.clone_to_cstring(text, allocator)
			sdl_text := ttf.CreateText(pipeline.text_engine, font, c_text, 0)
			data := ttf.GetGPUTextDrawData(sdl_text)

			append(&commands, Text{sdl_text, {bounds.x, bounds.y}, f32_color(config.textColor)})
		case .ScissorStart:
			append(
				&commands,
				ScissorStart {
					c.int(bounds.x * ctx.scaling),
					c.int(bounds.y * ctx.scaling),
					c.int(bounds.width * ctx.scaling),
					c.int(bounds.height * ctx.scaling),
				},
			)
		case .ScissorEnd:
			append(&commands, ScissorEnd{})
		case .Image:
		case .Custom:
		case .None:
		}
	}

	// upload to gpu
	{
		copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)
		defer sdl.EndGPUCopyPass(copy_pass)

		instances := make([dynamic]Instance, 0, len(commands), allocator)
		text_vertices := make([dynamic]Text_Vert, 0, len(commands), allocator)
		text_indices := make([dynamic]c.int, 0, len(commands), allocator)

		for command in commands {
			#partial switch cmd in command {
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
			}
		}

		// instances
		{
			size := u32(len(instances) * size_of(Instance))
			resize_buffer(ctx.device, &pipeline.instance_buffer, size, {.VERTEX})

			i_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				pipeline.instance_buffer.transfer,
				false,
			)
			mem.copy(i_array, raw_data(instances), int(size))
			sdl.UnmapGPUTransferBuffer(ctx.device, pipeline.instance_buffer.transfer)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = pipeline.instance_buffer.transfer},
				{buffer = pipeline.instance_buffer.gpu, size = size},
				false,
			)
		}

		// text
		{
			vert_size := u32(len(text_vertices) * size_of(Text_Vert))
			indices_size := u32(len(text_indices) * size_of(c.int))

			resize_buffer(ctx.device, &pipeline.text_vertex_buffer, vert_size, {.VERTEX})
			resize_buffer(ctx.device, &pipeline.text_index_buffer, indices_size, {.INDEX})

			vertex_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				pipeline.text_vertex_buffer.transfer,
				true,
			)
			mem.copy(vertex_array, raw_data(text_vertices), int(vert_size))
			sdl.UnmapGPUTransferBuffer(ctx.device, pipeline.text_vertex_buffer.transfer)

			index_array := sdl.MapGPUTransferBuffer(
				ctx.device,
				pipeline.text_index_buffer.transfer,
				true,
			)
			mem.copy(index_array, raw_data(text_indices), int(indices_size))
			sdl.UnmapGPUTransferBuffer(ctx.device, pipeline.text_index_buffer.transfer)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = pipeline.text_vertex_buffer.transfer},
				{buffer = pipeline.text_vertex_buffer.gpu, offset = 0, size = vert_size},
				true,
			)

			sdl.UploadToGPUBuffer(
				copy_pass,
				{transfer_buffer = pipeline.text_index_buffer.transfer},
				{buffer = pipeline.text_index_buffer.gpu, offset = 0, size = indices_size},
				true,
			)
		}
	}

	// render
	{
		swapchain_texture: ^sdl.GPUTexture
		w, h: u32
		_ = sdl.WaitAndAcquireGPUSwapchainTexture(
			cmd_buffer,
			ctx.window,
			&swapchain_texture,
			&w,
			&h,
		)

		render_pass := sdl.BeginGPURenderPass(
			cmd_buffer,
			&sdl.GPUColorTargetInfo {
				texture = swapchain_texture,
				load_op = .CLEAR,
				store_op = .STORE,
			},
			1,
			nil,
		)
		defer sdl.EndGPURenderPass(render_pass)

		// bind buffers
		{
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline.pipeline)
			vertex_buffer_bindings := []sdl.GPUBufferBinding {
				{buffer = pipeline.instance_buffer.gpu},
				{buffer = pipeline.text_vertex_buffer.gpu},
			}
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				raw_data(vertex_buffer_bindings),
				u32(len(vertex_buffer_bindings)),
			)
			sdl.BindGPUIndexBuffer(render_pass, {buffer = pipeline.text_index_buffer.gpu}, ._32BIT)
		}

		push_globals(ctx, cmd_buffer, f32(w), f32(h))

		atlas: ^sdl.GPUTexture
		instance_offset, text_index_offset, type_offset: u32
		text_vertex_offset: i32

		for command in commands {
			switch cmd in command {
			case ScissorStart:
				sdl.SetGPUScissor(render_pass, cmd)
			case ScissorEnd:
				sdl.SetGPUScissor(render_pass, {0, 0, i32(w), i32(h)})
			case Text:
				for data := ttf.GetGPUTextDrawData(cmd.ref); data != nil; data = data.next {
					if data.atlas_texture != atlas {
						sdl.BindGPUFragmentSamplers(
							render_pass,
							0,
							&sdl.GPUTextureSamplerBinding {
								texture = data.atlas_texture,
								sampler = pipeline.text_sampler,
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
			case Quad:
				sdl.BindGPUFragmentSamplers(
					render_pass,
					0,
					&sdl.GPUTextureSamplerBinding {
						texture = pipeline.dummy_texture,
						sampler = pipeline.text_sampler,
					},
					1,
				)
				atlas = pipeline.dummy_texture
				sdl.DrawGPUPrimitives(render_pass, 6, 1, 0, instance_offset)
				instance_offset += 1
			}
		}
	}

	// text cleanup -- [TODO] caching
	{
		for command in commands {
			#partial switch cmd in command {
			case Text:
				ttf.DestroyText(cmd.ref)
			}
		}
	}
}

ScissorStart :: sdl.Rect
ScissorEnd :: struct {
}

Command :: union {
	Text,
	Quad,
	ScissorStart,
	ScissorEnd,
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

Quad :: struct #packed {
	pos_scale:    [4]f32,
	corners:      [4]f32,
	color:        [4]f32,
	border_color: [4]f32,
	border_width: f32,
	_:            [3]f32,
}

Instance :: struct #packed {
	quad:     Quad,
	text_pos: [2]f32,
	_:        [2]f32,
	type:     f32,
	_:        [3]f32,
}

Pipeline :: struct {
	pipeline:           ^sdl.GPUGraphicsPipeline,
	text_vertex_buffer: Buffer,
	text_index_buffer:  Buffer,
	instance_buffer:    Buffer,
	text_engine:        ^ttf.TextEngine,
	text_sampler:       ^sdl.GPUSampler,
	dummy_texture:      ^sdl.GPUTexture,
}

f32_color :: proc(color: clay.Color) -> [4]f32 {
	return [4]f32{color.r / 255.0, color.g / 255.0, color.b / 255.0, color.a / 255.0}
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

push_globals :: proc(ctx: ^UI_Context, cmd_buffer: ^sdl.GPUCommandBuffer, w: f32, h: f32) {
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
