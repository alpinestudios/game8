package main

import "core:fmt"

import t "core:time"
import "core:math"
import "core:math/linalg"

import "base:runtime"
import sapp "../sokol/app"
import sg "../sokol/gfx"
import sglue "../sokol/glue"
import slog "../sokol/log"

state: struct {
	pass_action: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,
}

window_w :: 1280
window_h :: 720

main :: proc() {
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		width = window_w,
		height = window_h,
		window_title = "quad",
		icon = { sokol_default = true },
		logger = { func = slog.func },
	})
}

init :: proc "c" () {
	using linalg, fmt
	context = runtime.default_context()
	
	init_time = t.now()

	sg.setup({
		environment = sglue.environment(),
		logger = { func = slog.func },
		d3d11_shader_debugging = ODIN_DEBUG,
	})
	
	init_images()
	
	// make the vertex buffer
	state.bind.vertex_buffers[0] = sg.make_buffer({
		usage = .DYNAMIC,
		size = size_of(Quad) * len(draw_frame.quads),
	})

	// make & fill the index buffer
	index_buffer_count :: MAX_QUADS*6
	indices : [index_buffer_count]u16;
	i := 0;
	for i < index_buffer_count {
		// vertex offset pattern to draw a quad
		// { 0, 1, 2,  0, 2, 3 }
		indices[i + 0] = auto_cast ((i/6)*4 + 0)
		indices[i + 1] = auto_cast ((i/6)*4 + 1)
		indices[i + 2] = auto_cast ((i/6)*4 + 2)
		indices[i + 3] = auto_cast ((i/6)*4 + 0)
		indices[i + 4] = auto_cast ((i/6)*4 + 2)
		indices[i + 5] = auto_cast ((i/6)*4 + 3)
		i += 6;
	}
	state.bind.index_buffer = sg.make_buffer({
		type = .INDEXBUFFER,
		data = { ptr = &indices, size = size_of(indices) },
	})
	
	// image stuff
	state.bind.samplers[SMP_default_sampler] = sg.make_sampler({})

	// a shader and pipeline object
	state.pip = sg.make_pipeline({
		shader = sg.make_shader(quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				ATTR_quad_position = { format = .FLOAT2 },
				ATTR_quad_color0 = { format = .FLOAT4 },
				ATTR_quad_uv0 = { format = .FLOAT2 },
				ATTR_quad_bytes0 = { format = .UBYTE4N },
			},
		},
	})

	// default pass action
	state.pass_action = {
		colors = {
			0 = { load_action = .CLEAR, clear_value = { 0, 0, 0, 1 }},
		},
	}
}

frame :: proc "c" () {
	context = runtime.default_context()
	using runtime, linalg
	
	memset(&draw_frame, 0, size_of(draw_frame)) // @speed, we probs don't want to reset this whole thing
	
	draw_stuff()
	
	// currently doesn't support mutliple textures. Hard coding the player in for now.
	state.bind.images[IMG_tex0] = images[Image_Id.player].sg_img
	
	sg.update_buffer(
		state.bind.vertex_buffers[0],
		{ ptr = &draw_frame.quads[0], size = size_of(Quad) * len(draw_frame.quads) }
	)
	sg.begin_pass({ action = state.pass_action, swapchain = sglue.swapchain() })
	sg.apply_pipeline(state.pip)
	sg.apply_bindings(state.bind)
	sg.draw(0, 6*draw_frame.quad_count, 1)
	sg.end_pass()
	sg.commit()
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	sg.shutdown()
}

draw_stuff :: proc() {
	using linalg

	draw_frame.projection = matrix_ortho3d_f32(window_w * -0.5, window_w * 0.5, window_h * -0.5, window_h * 0.5, -1, 1)
	draw_frame.camera_xform = Matrix4(1)
	
	alpha :f32= auto_cast math.mod(seconds_since_init() * 0.1, 1.0)
	xform := xform_rotate(alpha * 360.0)
	draw_rect_xform(xform, v2{100, 100}, img_id=.player)
	draw_rect_aabb(v2{-100, 100}, v2{50, 50}, img_id=.crawler)
}