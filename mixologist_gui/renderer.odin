package mixologist_gui

import "clay"
import "core:c"
import "core:log"
import "core:mem"
import "core:strings"
import ttf "sdl3_ttf"
import sdl "vendor:sdl3"

_quad_pipeline: Quad_Pipeline
_text_pipeline: Text_Pipeline
_layers: [dynamic]Layer
_tmp_quads: [dynamic]Quad
_tmp_text: [dynamic]Text

BUFFER_INIT_SIZE :: 256

f32_color :: proc(color: clay.Color) -> [4]f32 {
	return [4]f32{color.r / 255.0, color.g / 255.0, color.b / 255.0, color.a / 255.0}
}

new_scissor :: proc(old: ^Scissor) -> Scissor {
	return Scissor {
		quad_start = old.quad_start + old.quad_len,
		text_start = old.text_start + old.text_len,
	}
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

Globals :: struct {
	projection: matrix[4, 4]f32,
	scale:      f32,
}

Buffer :: struct {
	gpu:      ^sdl.GPUBuffer,
	transfer: ^sdl.GPUTransferBuffer,
	size:     u32,
}

Quad_Pipeline :: struct {
	buffer:        Buffer,
	num_instances: u32,
	pipeline:      ^sdl.GPUGraphicsPipeline,
}

Quad :: struct {
	pos_scale:    [4]f32,
	corner_radii: [4]f32,
	color:        [4]f32,
	border_color: [4]f32,
	border_width: f32,
	_:            [3]f32,
}

Text_Pipeline :: struct {
	engine:          ^ttf.TextEngine,
	pipeline:        ^sdl.GPUGraphicsPipeline,
	vertex_buffer:   Buffer,
	index_buffer:    Buffer,
	instance_buffer: Buffer,
	sampler:         ^sdl.GPUSampler,
}

Text :: struct {
	ref:   ^ttf.Text,
	pos:   [2]f32,
	color: [4]f32,
}

TextVert :: struct {
	pos_uv: [4]f32,
	color:  [4]f32,
}

Layer :: struct {
	quad_instance_start: u32,
	quad_len:            u32,
	text_instance_start: u32,
	text_instance_len:   u32,
	text_vertex_start:   u32,
	text_vertex_len:     u32,
	text_index_start:    u32,
	text_index_len:      u32,
	scissors:            [dynamic]Scissor,
}

Scissor :: struct {
	bounds:     sdl.Rect,
	quad_start: u32,
	quad_len:   u32,
	text_start: u32,
	text_len:   u32,
}

Renderer_init :: proc(ctx: ^UI_Context) {
	// create quad pipeline
	{
		QUAD_VERT :: #load("resources/shaders/compiled/quad.vert.spv")
		QUAD_FRAG :: #load("resources/shaders/compiled/quad.frag.spv")

		vert_info := sdl.GPUShaderCreateInfo {
			code_size           = len(QUAD_VERT),
			code                = raw_data(QUAD_VERT),
			entrypoint          = "main",
			format              = {.SPIRV},
			stage               = .VERTEX,
			num_uniform_buffers = 1,
		}
		vert_shader := sdl.CreateGPUShader(ctx.device, vert_info)
		defer sdl.ReleaseGPUShader(ctx.device, vert_shader)

		vert_attrs := []sdl.GPUVertexAttribute {
			{buffer_slot = 0, location = 0, format = .FLOAT4, offset = 0},
			{buffer_slot = 0, location = 1, format = .FLOAT4, offset = size_of(f32) * 4},
			{buffer_slot = 0, location = 2, format = .FLOAT4, offset = size_of(f32) * 8},
			{buffer_slot = 0, location = 3, format = .FLOAT4, offset = size_of(f32) * 12},
			{buffer_slot = 0, location = 4, format = .FLOAT4, offset = size_of(f32) * 16},
		}

		frag_info := sdl.GPUShaderCreateInfo {
			code_size  = len(QUAD_FRAG),
			code       = raw_data(QUAD_FRAG),
			entrypoint = "main",
			format     = {.SPIRV},
			stage      = .FRAGMENT,
		}
		frag_shader := sdl.CreateGPUShader(ctx.device, frag_info)
		defer sdl.ReleaseGPUShader(ctx.device, frag_shader)

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
				vertex_buffer_descriptions = &sdl.GPUVertexBufferDescription {
					slot = 0,
					input_rate = .INSTANCE,
					instance_step_rate = 0,
					pitch = size_of(Quad),
				},
				num_vertex_buffers = 1,
				vertex_attributes = raw_data(vert_attrs),
				num_vertex_attributes = sdl.Uint32(len(vert_attrs)),
			},
		}

		_quad_pipeline.buffer = create_buffer(
			ctx.device,
			size_of(Quad) * BUFFER_INIT_SIZE,
			{.VERTEX},
		)
		_quad_pipeline.num_instances = BUFFER_INIT_SIZE
		_quad_pipeline.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.device, pipeline_info)
	}
	// create text pipeline
	{
		TEXT_VERT :: #load("resources/shaders/compiled/text.vert.spv")
		TEXT_FRAG :: #load("resources/shaders/compiled/text.frag.spv")

		vert_info := sdl.GPUShaderCreateInfo {
			code_size           = len(TEXT_VERT),
			code                = raw_data(TEXT_VERT),
			entrypoint          = "main",
			format              = {.SPIRV},
			stage               = .VERTEX,
			num_uniform_buffers = 1,
		}
		vert_shader := sdl.CreateGPUShader(ctx.device, vert_info)
		defer sdl.ReleaseGPUShader(ctx.device, vert_shader)

		vert_attrs := []sdl.GPUVertexAttribute {
			{buffer_slot = 0, location = 0, format = .FLOAT4, offset = 0},
			{buffer_slot = 0, location = 1, format = .FLOAT4, offset = size_of(f32) * 4},
			{buffer_slot = 1, location = 2, format = .FLOAT2, offset = 0},
		}

		buffer_descriptions := []sdl.GPUVertexBufferDescription {
			{slot = 0, input_rate = .VERTEX, pitch = size_of(TextVert)},
			{slot = 1, input_rate = .INSTANCE, pitch = size_of([2]f32)},
		}

		frag_info := sdl.GPUShaderCreateInfo {
			code_size    = len(TEXT_FRAG),
			code         = raw_data(TEXT_FRAG),
			entrypoint   = "main",
			format       = {.SPIRV},
			stage        = .FRAGMENT,
			num_samplers = 1,
		}
		frag_shader := sdl.CreateGPUShader(ctx.device, frag_info)
		defer sdl.ReleaseGPUShader(ctx.device, frag_shader)

		sampler := sdl.CreateGPUSampler(
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

		pipeline_info := sdl.GPUGraphicsPipelineCreateInfo {
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			target_info = {
				color_target_descriptions = &sdl.GPUColorTargetDescription {
					format = sdl.GetGPUSwapchainTextureFormat(ctx.device, ctx.window),
					blend_state = sdl.GPUColorTargetBlendState {
						enable_blend = true,
						color_write_mask = sdl.GPUColorComponentFlags{.R, .G, .B, .A},
						alpha_blend_op = sdl.GPUBlendOp.ADD,
						src_alpha_blendfactor = sdl.GPUBlendFactor.SRC_ALPHA,
						dst_alpha_blendfactor = sdl.GPUBlendFactor.ONE_MINUS_SRC_ALPHA,
						color_blend_op = sdl.GPUBlendOp.ADD,
						src_color_blendfactor = sdl.GPUBlendFactor.SRC_ALPHA,
						dst_color_blendfactor = sdl.GPUBlendFactor.ONE_MINUS_SRC_ALPHA,
					},
				},
				num_color_targets = 1,
			},
			vertex_input_state = {
				vertex_buffer_descriptions = raw_data(buffer_descriptions),
				num_vertex_buffers = sdl.Uint32(len(buffer_descriptions)),
				vertex_attributes = raw_data(vert_attrs),
				num_vertex_attributes = sdl.Uint32(len(vert_attrs)),
			},
		}

		_text_pipeline.pipeline = sdl.CreateGPUGraphicsPipeline(ctx.device, pipeline_info)
		_text_pipeline.engine = ttf.CreateGPUTextEngine(ctx.device)
		_text_pipeline.sampler = sampler
		ttf.SetGPUTextEngineWinding(_text_pipeline.engine, .COUNTER_CLOCKWISE)
		_text_pipeline.vertex_buffer = create_buffer(
			ctx.device,
			size_of(TextVert) * BUFFER_INIT_SIZE,
			{.VERTEX},
		)
		_text_pipeline.index_buffer = create_buffer(
			ctx.device,
			size_of(sdl.Sint32) * BUFFER_INIT_SIZE,
			{.INDEX},
		)
		_text_pipeline.instance_buffer = create_buffer(
			ctx.device,
			size_of([2]f32) * BUFFER_INIT_SIZE,
			{.VERTEX},
		)
	}
}

Renderer_destroy :: proc(ctx: ^UI_Context) {
	// quad pipeline
	{
		destroy_buffer(ctx.device, &_quad_pipeline.buffer)
		sdl.ReleaseGPUGraphicsPipeline(ctx.device, _quad_pipeline.pipeline)
	}
	// text pipeline
	{
		destroy_buffer(ctx.device, &_text_pipeline.vertex_buffer)
		destroy_buffer(ctx.device, &_text_pipeline.index_buffer)
		destroy_buffer(ctx.device, &_text_pipeline.instance_buffer)
		sdl.ReleaseGPUGraphicsPipeline(ctx.device, _text_pipeline.pipeline)
	}
	delete(_layers)
}

Renderer_submit :: proc(
	ctx: ^UI_Context,
	cmd_buffer: ^sdl.GPUCommandBuffer,
	render_commands: ^clay.ClayArray(clay.RenderCommand),
	allocator := context.temp_allocator,
) {
	clear(&_layers)
	clear(&_tmp_quads)
	clear(&_tmp_text)

	_tmp_quads = make([dynamic]Quad, 0, _quad_pipeline.num_instances, allocator)
	_tmp_text = make([dynamic]Text, 0, 20, allocator)

	layer := Layer {
		scissors = make([dynamic]Scissor, 0, 10, context.temp_allocator),
	}
	scissor := Scissor{}

	for i in 0 ..< int(render_commands.length) {
		cmd := clay.RenderCommandArray_Get(render_commands, cast(i32)i)
		bounds := cmd.boundingBox

		switch cmd.commandType {
		case .None:
		case .Text:
			config := cmd.renderData.text
			font := UI_retrieve_font(
				ctx,
				config.fontId,
				u16(c.float(config.fontSize) * ctx.scaling),
			)
			text := string(config.stringContents.chars[:config.stringContents.length])
			c_text := strings.clone_to_cstring(text, allocator)
			sdl_text := ttf.CreateText(_text_pipeline.engine, font, c_text, 0)
			data := ttf.GetGPUTextDrawData(sdl_text)

			append(&_tmp_text, Text{sdl_text, {bounds.x, bounds.y}, f32_color(config.textColor)})
			layer.text_instance_len += 1
			layer.text_vertex_len += u32(data.num_vertices)
			layer.text_index_len += u32(data.num_indices)
			scissor.text_len += 1
		case .Image:
		case .ScissorStart:
			bounds := sdl.Rect {
				c.int(bounds.x * ctx.scaling),
				c.int(bounds.y * ctx.scaling),
				c.int(bounds.width * ctx.scaling),
				c.int(bounds.height * ctx.scaling),
			}
			new := new_scissor(&scissor)
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				append(&layer.scissors, scissor)
			}
			scissor = new
			scissor.bounds = bounds
		case .ScissorEnd:
			new := new_scissor(&scissor)
			if scissor.quad_len != 0 || scissor.text_len != 0 {
				append(&layer.scissors, scissor)
			}
			scissor = new
		case .Rectangle:
			config := cmd.renderData.rectangle
			color := f32_color(config.backgroundColor)
			cr := config.cornerRadius
			quad := Quad {
				pos_scale    = {bounds.x, bounds.y, bounds.width, bounds.height},
				corner_radii = {cr.topLeft, cr.topRight, cr.bottomRight, cr.bottomLeft},
				color        = color,
			}
			append(&_tmp_quads, quad)
			layer.quad_len += 1
			scissor.quad_len += 1
		case .Border:
			config := cmd.renderData.border
			cr := config.cornerRadius
			quad := Quad {
				pos_scale    = {bounds.x, bounds.y, bounds.width, bounds.height},
				corner_radii = {cr.topLeft, cr.topRight, cr.bottomRight, cr.bottomLeft},
				color        = f32_color({0, 0, 0, 0}),
				border_color = f32_color(config.color),
				border_width = f32(config.width.top),
			}
			append(&_tmp_quads, quad)
			layer.quad_len += 1
			scissor.quad_len += 1
		case .Custom:
		}
	}

	append(&layer.scissors, scissor)
	append(&_layers, layer)

	copy_pass := sdl.BeginGPUCopyPass(cmd_buffer)

	// upload quads
	{
		num_quads := u32(len(_tmp_quads))
		size := num_quads * size_of(Quad)

		resize_buffer(ctx.device, &_quad_pipeline.buffer, size, {.VERTEX})

		i_array := sdl.MapGPUTransferBuffer(ctx.device, _quad_pipeline.buffer.transfer, false)
		mem.copy(i_array, raw_data(_tmp_quads), int(size))
		sdl.UnmapGPUTransferBuffer(ctx.device, _quad_pipeline.buffer.transfer)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = _quad_pipeline.buffer.transfer},
			{buffer = _quad_pipeline.buffer.gpu, offset = 0, size = size},
			false,
		)
	}
	// upload text
	{
		vertices := make([dynamic]TextVert, 0, BUFFER_INIT_SIZE, allocator)
		indices := make([dynamic]c.int, 0, BUFFER_INIT_SIZE, allocator)
		instances := make([dynamic][2]f32, 0, BUFFER_INIT_SIZE, allocator)

		for &text in _tmp_text {
			append(&instances, text.pos)
			data := ttf.GetGPUTextDrawData(text.ref)

			for data != nil {
				for i in 0 ..< data.num_vertices {
					pos := data.xy[i]
					uv := data.uv[i]
					color := text.color
					append(&vertices, TextVert{{pos.x, -pos.y, uv.x, uv.y}, color})
				}
				append(&indices, ..data.indices[:data.num_indices])
				data = data.next
			}
		}

		// Resize buffers if needed
		vertices_size := u32(len(vertices) * size_of(TextVert))
		indices_size := u32(len(indices) * size_of(c.int))
		instances_size := u32(len(instances) * size_of([2]f32))

		resize_buffer(ctx.device, &_text_pipeline.vertex_buffer, vertices_size, {.VERTEX})
		resize_buffer(ctx.device, &_text_pipeline.index_buffer, indices_size, {.INDEX})
		resize_buffer(ctx.device, &_text_pipeline.instance_buffer, instances_size, {.VERTEX})

		vertex_array := sdl.MapGPUTransferBuffer(
			ctx.device,
			_text_pipeline.vertex_buffer.transfer,
			true,
		)
		mem.copy(vertex_array, raw_data(vertices), int(vertices_size))
		sdl.UnmapGPUTransferBuffer(ctx.device, _text_pipeline.vertex_buffer.transfer)

		index_array := sdl.MapGPUTransferBuffer(
			ctx.device,
			_text_pipeline.index_buffer.transfer,
			true,
		)
		mem.copy(index_array, raw_data(indices), int(indices_size))
		sdl.UnmapGPUTransferBuffer(ctx.device, _text_pipeline.index_buffer.transfer)

		instance_array := sdl.MapGPUTransferBuffer(
			ctx.device,
			_text_pipeline.instance_buffer.transfer,
			true,
		)
		mem.copy(instance_array, raw_data(instances), int(instances_size))
		sdl.UnmapGPUTransferBuffer(ctx.device, _text_pipeline.instance_buffer.transfer)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = _text_pipeline.vertex_buffer.transfer},
			{buffer = _text_pipeline.vertex_buffer.gpu, offset = 0, size = vertices_size},
			true,
		)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = _text_pipeline.index_buffer.transfer},
			{buffer = _text_pipeline.index_buffer.gpu, offset = 0, size = indices_size},
			true,
		)

		sdl.UploadToGPUBuffer(
			copy_pass,
			{transfer_buffer = _text_pipeline.instance_buffer.transfer},
			{buffer = _text_pipeline.instance_buffer.gpu, offset = 0, size = instances_size},
			true,
		)
	}
	sdl.EndGPUCopyPass(copy_pass)
}

Renderer_draw :: proc(ctx: ^UI_Context, cmd_buffer: ^sdl.GPUCommandBuffer) {
	swapchain_texture: ^sdl.GPUTexture
	w, h: u32
	_ = sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buffer, ctx.window, &swapchain_texture, &w, &h)

	for &layer, index in _layers {
		op: sdl.GPULoadOp = index == 0 ? .CLEAR : .LOAD
		// draw quads
		draw_quads: {
			if layer.quad_len == 0 {
				break draw_quads
			}

			render_pass := sdl.BeginGPURenderPass(
				cmd_buffer,
				&sdl.GPUColorTargetInfo {
					texture = swapchain_texture,
					clear_color = sdl.FColor{1.0, 1.0, 1.0, 1.0},
					load_op = op,
					store_op = sdl.GPUStoreOp.STORE,
				},
				1,
				nil,
			)
			sdl.BindGPUGraphicsPipeline(render_pass, _quad_pipeline.pipeline)

			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&sdl.GPUBufferBinding{buffer = _quad_pipeline.buffer.gpu, offset = 0},
				1,
			)
			push_globals(ctx, cmd_buffer, f32(w), f32(h))

			quad_offset := layer.quad_instance_start

			for &scissor in layer.scissors {
				if scissor.quad_len == 0 {
					continue
				}

				if scissor.bounds.w == 0 || scissor.bounds.h == 0 {
					sdl.SetGPUScissor(render_pass, {0, 0, c.int(w), c.int(h)})
				} else {
					sdl.SetGPUScissor(render_pass, scissor.bounds)
				}

				sdl.DrawGPUPrimitives(render_pass, 6, scissor.quad_len, 0, quad_offset)
				quad_offset += scissor.quad_len
			}
			sdl.EndGPURenderPass(render_pass)
		}
		// draw text
		draw_text: {
			if layer.text_instance_len == 0 {
				break draw_text
			}

			render_pass := sdl.BeginGPURenderPass(
				cmd_buffer,
				&sdl.GPUColorTargetInfo {
					texture = swapchain_texture,
					load_op = sdl.GPULoadOp.LOAD,
					store_op = sdl.GPUStoreOp.STORE,
				},
				1,
				nil,
			)
			sdl.BindGPUGraphicsPipeline(render_pass, _text_pipeline.pipeline)

			v_bindings: [2]sdl.GPUBufferBinding = {
				sdl.GPUBufferBinding{buffer = _text_pipeline.vertex_buffer.gpu, offset = 0},
				sdl.GPUBufferBinding{buffer = _text_pipeline.instance_buffer.gpu, offset = 0},
			}

			sdl.BindGPUVertexBuffers(render_pass, 0, raw_data(v_bindings[:]), 2)
			sdl.BindGPUIndexBuffer(
				render_pass,
				{buffer = _text_pipeline.index_buffer.gpu, offset = 0},
				._32BIT,
			)

			push_globals(ctx, cmd_buffer, f32(w), f32(h))

			atlas: ^sdl.GPUTexture

			layer_text := _tmp_text[layer.text_instance_start:layer.text_instance_start +
			layer.text_instance_len]
			index_offset: u32 = layer.text_instance_start
			vertex_offset: i32 = i32(layer.text_vertex_start)
			instance_offset: u32 = layer.text_instance_start

			for &scissor in layer.scissors {
				if scissor.text_len == 0 {
					continue
				}

				if scissor.bounds.w == 0 || scissor.bounds.h == 0 {
					sdl.SetGPUScissor(render_pass, {0, 0, i32(w), i32(h)})
				} else {
					sdl.SetGPUScissor(render_pass, scissor.bounds)
				}

				for &text in layer_text[scissor.text_start:scissor.text_start + scissor.text_len] {
					data := ttf.GetGPUTextDrawData(text.ref)

					for data != nil {
						if data.atlas_texture != atlas {
							sdl.BindGPUFragmentSamplers(
								render_pass,
								0,
								&sdl.GPUTextureSamplerBinding {
									texture = data.atlas_texture,
									sampler = _text_pipeline.sampler,
								},
								1,
							)
							atlas = data.atlas_texture
						}

						sdl.DrawGPUIndexedPrimitives(
							render_pass,
							u32(data.num_indices),
							1,
							index_offset,
							vertex_offset,
							instance_offset,
						)

						index_offset += u32(data.num_indices)
						vertex_offset += data.num_vertices

						data = data.next
					}

					instance_offset += 1
				}
			}

			sdl.EndGPURenderPass(render_pass)
		}
	}
}
