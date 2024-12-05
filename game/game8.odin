package main

import "base:runtime"
import "base:intrinsics"
import t "core:time"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/ease"
import "core:math/rand"
import "core:mem"

import sapp "../sokol/app"
import sg "../sokol/gfx"
import sglue "../sokol/glue"
import slog "../sokol/log"

import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

app_state: struct {
	pass_action: sg.Pass_Action,
	pip: sg.Pipeline,
	bind: sg.Bindings,
	input_state: Input_State,
	game: Game_State,
	message_queue: [dynamic]Message,
	user_id: UserID,
}

UserID :: u64

window_w :: 1280
window_h :: 720

main :: proc() {
	sapp.run({
		init_cb = init,
		frame_cb = frame,
		cleanup_cb = cleanup,
		event_cb = event,
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
	init_fonts()
	
	rand.reset(auto_cast runtime.read_cycle_counter())
	app_state.user_id = rand.uint64()
	// todo - cache this out to disc || replace with steamid in future
	//loggie(app_state.user_id)
	
	// make the vertex buffer
	app_state.bind.vertex_buffers[0] = sg.make_buffer({
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
	app_state.bind.index_buffer = sg.make_buffer({
		type = .INDEXBUFFER,
		data = { ptr = &indices, size = size_of(indices) },
	})
	
	// image stuff
	app_state.bind.samplers[SMP_default_sampler] = sg.make_sampler({})
	
	// setup pipeline
	pipeline_desc : sg.Pipeline_Desc = {
		shader = sg.make_shader(quad_shader_desc(sg.query_backend())),
		index_type = .UINT16,
		layout = {
			attrs = {
				ATTR_quad_position = { format = .FLOAT2 },
				ATTR_quad_color0 = { format = .FLOAT4 },
				ATTR_quad_uv0 = { format = .FLOAT2 },
				ATTR_quad_bytes0 = { format = .UBYTE4N },
				ATTR_quad_color_override0 = { format = .FLOAT4 }
			},
		}
	}
	blend_state : sg.Blend_State = {
		enabled = true,
		src_factor_rgb = .SRC_ALPHA,
		dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
		op_rgb = .ADD,
		src_factor_alpha = .ONE,
		dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
		op_alpha = .ADD,
	}
	pipeline_desc.colors[0] = { blend = blend_state }
	app_state.pip = sg.make_pipeline(pipeline_desc)

	// default pass action
	app_state.pass_action = {
		colors = {
			0 = { load_action = .CLEAR, clear_value = { 0, 0, 0, 1 }},
		},
	}
}

//
// :frame
last_time : t.Time
accumulator: f64
sims_per_second :: 1.0 / 30.0

last_sim_time :f64= 0.0

frame :: proc "c" () {	
	// this'll run at refresh rate (most likely)
	// turning vsync off via the swap_interval at runtime isn't supported yet
	// https://github.com/floooh/sokol/issues/693
	// but if we need it when shipping, it's trivial to patch it in
	// For now, don't need to care about this and just force vsync
	
	using runtime, linalg
	context = runtime.default_context()
	
	current_time := t.now()
	frame_time :f64= t.duration_seconds(t.diff(last_time, current_time))
	last_time = current_time
	// should we use this manually calculated dt, or the sokol frame_duration that's smoothed?
	// not sure, will experiment later
	frame_time = sapp.frame_duration()
	//loggie(frame_time)
	
	// only tick the game state at the rate of sims_per_second
	// https://gafferongames.com/post/fix_your_timestep/
	accumulator += frame_time
	for (accumulator >= sims_per_second) {
		sim_game_state(&app_state.game, sims_per_second, app_state.message_queue[:])
		last_sim_time = seconds_since_init()
		clear(&app_state.message_queue)
		accumulator -= sims_per_second
	}
	
	memset(&draw_frame, 0, size_of(draw_frame)) // @speed, we probs don't want to reset this whole thing
	
	smooth_rendering := true
	if smooth_rendering {
		dt := seconds_since_init()-last_sim_time
		
		temp_gs := new_clone(app_state.game)
		sim_game_state(temp_gs, dt, app_state.message_queue[:])
	
		draw_game_state(temp_gs^, app_state.input_state, &app_state.message_queue)
	} else {
		draw_game_state(app_state.game, app_state.input_state, &app_state.message_queue)
	}
	reset_input_state_for_next_frame(&app_state.input_state)
	
	app_state.bind.images[IMG_tex0] = atlas.sg_image
	app_state.bind.images[IMG_tex1] = images[font.img_id].sg_img
	
	sg.update_buffer(
		app_state.bind.vertex_buffers[0],
		{ ptr = &draw_frame.quads[0], size = size_of(Quad) * len(draw_frame.quads) }
	)
	sg.begin_pass({ action = app_state.pass_action, swapchain = sglue.swapchain() })
	sg.apply_pipeline(app_state.pip)
	sg.apply_bindings(app_state.bind)
	sg.draw(0, 6*draw_frame.quad_count, 1)
	sg.end_pass()
	sg.commit()
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	sg.shutdown()
}

//
// :input

Key_Code :: enum {
	// copied from sokol_app
	INVALID = 0,
	SPACE = 32,
	APOSTROPHE = 39,
	COMMA = 44,
	MINUS = 45,
	PERIOD = 46,
	SLASH = 47,
	_0 = 48,
	_1 = 49,
	_2 = 50,
	_3 = 51,
	_4 = 52,
	_5 = 53,
	_6 = 54,
	_7 = 55,
	_8 = 56,
	_9 = 57,
	SEMICOLON = 59,
	EQUAL = 61,
	A = 65,
	B = 66,
	C = 67,
	D = 68,
	E = 69,
	F = 70,
	G = 71,
	H = 72,
	I = 73,
	J = 74,
	K = 75,
	L = 76,
	M = 77,
	N = 78,
	O = 79,
	P = 80,
	Q = 81,
	R = 82,
	S = 83,
	T = 84,
	U = 85,
	V = 86,
	W = 87,
	X = 88,
	Y = 89,
	Z = 90,
	LEFT_BRACKET = 91,
	BACKSLASH = 92,
	RIGHT_BRACKET = 93,
	GRAVE_ACCENT = 96,
	WORLD_1 = 161,
	WORLD_2 = 162,
	ESCAPE = 256,
	ENTER = 257,
	TAB = 258,
	BACKSPACE = 259,
	INSERT = 260,
	DELETE = 261,
	RIGHT = 262,
	LEFT = 263,
	DOWN = 264,
	UP = 265,
	PAGE_UP = 266,
	PAGE_DOWN = 267,
	HOME = 268,
	END = 269,
	CAPS_LOCK = 280,
	SCROLL_LOCK = 281,
	NUM_LOCK = 282,
	PRINT_SCREEN = 283,
	PAUSE = 284,
	F1 = 290,
	F2 = 291,
	F3 = 292,
	F4 = 293,
	F5 = 294,
	F6 = 295,
	F7 = 296,
	F8 = 297,
	F9 = 298,
	F10 = 299,
	F11 = 300,
	F12 = 301,
	F13 = 302,
	F14 = 303,
	F15 = 304,
	F16 = 305,
	F17 = 306,
	F18 = 307,
	F19 = 308,
	F20 = 309,
	F21 = 310,
	F22 = 311,
	F23 = 312,
	F24 = 313,
	F25 = 314,
	KP_0 = 320,
	KP_1 = 321,
	KP_2 = 322,
	KP_3 = 323,
	KP_4 = 324,
	KP_5 = 325,
	KP_6 = 326,
	KP_7 = 327,
	KP_8 = 328,
	KP_9 = 329,
	KP_DECIMAL = 330,
	KP_DIVIDE = 331,
	KP_MULTIPLY = 332,
	KP_SUBTRACT = 333,
	KP_ADD = 334,
	KP_ENTER = 335,
	KP_EQUAL = 336,
	LEFT_SHIFT = 340,
	LEFT_CONTROL = 341,
	LEFT_ALT = 342,
	LEFT_SUPER = 343,
	RIGHT_SHIFT = 344,
	RIGHT_CONTROL = 345,
	RIGHT_ALT = 346,
	RIGHT_SUPER = 347,
	MENU = 348,
	
	// randy: adding the mouse buttons on the end here so we can unify the enum and not need to use sapp.Mousebutton
	LEFT_MOUSE = 400,
	RIGHT_MOUSE = 401,
	MIDDLE_MOUSE = 402,
}
MAX_KEYCODES :: sapp.MAX_KEYCODES
map_sokol_mouse_button :: proc "c" (sokol_mouse_button: sapp.Mousebutton) -> Key_Code {
	#partial switch sokol_mouse_button {
		case .LEFT: return .LEFT_MOUSE
		case .RIGHT: return .RIGHT_MOUSE
		case .MIDDLE: return .MIDDLE_MOUSE
	}
	return nil
}

Input_State_Flags :: enum {
	down,
	just_pressed,
	just_released,
	repeat,
}

Input_State :: struct {
	keys: [MAX_KEYCODES]bit_set[Input_State_Flags],
}

reset_input_state_for_next_frame :: proc(state: ^Input_State) {
	for &set in state.keys {
		set -= {.just_pressed, .just_released, .repeat}
	}
}

key_just_pressed :: proc(input_state: Input_State, code: Key_Code) -> bool {
	return .just_pressed in input_state.keys[code]
}
key_down :: proc(input_state: Input_State, code: Key_Code) -> bool {
	return .down in input_state.keys[code]
}
key_just_released :: proc(input_state: Input_State, code: Key_Code) -> bool {
	return .just_released in input_state.keys[code]
}
key_repeat :: proc(input_state: Input_State, code: Key_Code) -> bool {
	return .repeat in input_state.keys[code]
}

event :: proc "c" (event: ^sapp.Event) {
	// see this for example of events: https://floooh.github.io/sokol-html5/events-sapp.html
	input_state := &app_state.input_state
	
	#partial switch event.type {
		case .MOUSE_UP:
		if .down in input_state.keys[map_sokol_mouse_button(event.mouse_button)] {
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] -= { .down }
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] += { .just_released }
		}
		case .MOUSE_DOWN:
		if !(.down in input_state.keys[map_sokol_mouse_button(event.mouse_button)]) {
			input_state.keys[map_sokol_mouse_button(event.mouse_button)] += { .down, .just_pressed }
		}
	
		case .KEY_UP:
		if .down in input_state.keys[event.key_code] {
			input_state.keys[event.key_code] -= { .down }
			input_state.keys[event.key_code] += { .just_released }
		}
		case .KEY_DOWN:
		if !event.key_repeat && !(.down in input_state.keys[event.key_code]) {
			input_state.keys[event.key_code] += { .down, .just_pressed }
		}
		if event.key_repeat {
			input_state.keys[event.key_code] += { .repeat }
		}
	}
}

//
// :UTILS

DEFAULT_UV :: v4{0, 0, 1, 1}
Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
v2 :: Vector2
v3 :: Vector3
v4 :: Vector4
Matrix4 :: linalg.Matrix4f32;

COLOR_WHITE :: Vector4 {1,1,1,1}

// might do something with these later on
loggie :: fmt.println // log is already used........
log_error :: fmt.println
log_warning :: fmt.println

init_time: t.Time;
seconds_since_init :: proc() -> f64 {
	using t
	if init_time._nsec == 0 {
		log_error("invalid time")
		return 0
	}
	return duration_seconds(since(init_time))
}

xform_translate :: proc(pos: Vector2) -> Matrix4 {
	return linalg.matrix4_translate(v3{pos.x, pos.y, 0})
}
xform_rotate :: proc(angle: f32) -> Matrix4 {
	return linalg.matrix4_rotate(math.to_radians(angle), v3{0,0,1})
}
xform_scale :: proc(scale: Vector2) -> Matrix4 {
	return linalg.matrix4_scale(v3{scale.x, scale.y, 1});
}

Pivot :: enum {
	bottom_left,
	bottom_center,
	bottom_right,
	center_left,
	center_center,
	center_right,
	top_left,
	top_center,
	top_right,
}
scale_from_pivot :: proc(pivot: Pivot) -> Vector2 {
	switch pivot {
		case .bottom_left: return v2{0.0, 0.0}
		case .bottom_center: return v2{0.5, 0.0}
		case .bottom_right: return v2{1.0, 0.0}
		case .center_left: return v2{0.0, 0.5}
		case .center_center: return v2{0.5, 0.5}
		case .center_right: return v2{1.0, 0.5}
		case .top_center: return v2{0.5, 1.0}
		case .top_left: return v2{0.0, 1.0}
		case .top_right: return v2{1.0, 1.0}
	}
	return {};
}

sine_breathe :: proc(p: $T) -> T where intrinsics.type_is_float(T) {
	return (math.sin((p - .25) * 2.0 * math.PI) / 2.0) + 0.5
}

//
// :RENDER STUFF
//
// API ordered highest -> lowest level

draw_sprite :: proc(pos: Vector2, img_id: Image_Id, pivot:= Pivot.bottom_left, xform := Matrix4(1), color_override:= v4{0,0,0,0}) {
	image := images[img_id]
	size := v2{auto_cast image.width, auto_cast image.height}
	
	xform0 := Matrix4(1)
	xform0 *= xform_translate(pos)
	xform0 *= xform // we slide in here because rotations + scales work nicely at this point
	xform0 *= xform_translate(size * -scale_from_pivot(pivot))
	
	draw_rect_xform(xform0, size, img_id=img_id, color_override=color_override)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col, uv, img_id, color_override)
}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0},
) {
	draw_rect_projected(draw_frame.projection * draw_frame.camera_xform * xform, size, col, uv, img_id, color_override)
}

Vertex :: struct {
	pos: Vector2,
	col: Vector4,
	uv: Vector2,
	tex_index: u8,
	_pad: [3]u8,
	color_override: Vector4,
}

Quad :: [4]Vertex;

MAX_QUADS :: 8192
MAX_VERTS :: MAX_QUADS * 4

Draw_Frame :: struct {

	quads: [MAX_QUADS]Quad,
	quad_count: int,
	
	projection: Matrix4,
	camera_xform: Matrix4,

}
draw_frame : Draw_Frame;

// below is the lower level draw rect stuff

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
	color_override:= v4{0,0,0,0}
) {

	bl := v2{ 0, 0 }
	tl := v2{ 0, size.y }
	tr := v2{ size.x, size.y }
	br := v2{ size.x, 0 }
	
	uv0 := uv
	if uv == DEFAULT_UV {
		uv0 = images[img_id].atlas_uvs
	}
	
	tex_index :u8= images[img_id].tex_index
	if img_id == .nil {
		tex_index = 255 // bypasses texture sampling
	}
	
	draw_quad_projected(world_to_clip, {bl, tl, tr, br}, {col, col, col, col}, {uv0.xy, uv0.xw, uv0.zw, uv0.zy}, {tex_index,tex_index,tex_index,tex_index}, {color_override,color_override,color_override,color_override})

}

draw_quad_projected :: proc(
	world_to_clip:   Matrix4, 
	positions:       [4]Vector2,
	colors:          [4]Vector4,
	uvs:             [4]Vector2,
	tex_indicies:       [4]u8,
	//flags:           [4]Quad_Flags,
	color_overrides: [4]Vector4,
	//hsv:             [4]Vector3
) {
	using linalg

	if draw_frame.quad_count >= MAX_QUADS {
		log_error("max quads reached")
		return
	}
		
	verts := cast(^[4]Vertex)&draw_frame.quads[draw_frame.quad_count];
	draw_frame.quad_count += 1;
	
	verts[0].pos = (world_to_clip * Vector4{positions[0].x, positions[0].y, 0.0, 1.0}).xy
	verts[1].pos = (world_to_clip * Vector4{positions[1].x, positions[1].y, 0.0, 1.0}).xy
	verts[2].pos = (world_to_clip * Vector4{positions[2].x, positions[2].y, 0.0, 1.0}).xy
	verts[3].pos = (world_to_clip * Vector4{positions[3].x, positions[3].y, 0.0, 1.0}).xy
	
	verts[0].col = colors[0]
	verts[1].col = colors[1]
	verts[2].col = colors[2]
	verts[3].col = colors[3]

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]
	
	verts[0].tex_index = tex_indicies[0]
	verts[1].tex_index = tex_indicies[1]
	verts[2].tex_index = tex_indicies[2]
	verts[3].tex_index = tex_indicies[3]
	
	verts[0].color_override = color_overrides[0]
	verts[1].color_override = color_overrides[1]
	verts[2].color_override = color_overrides[2]
	verts[3].color_override = color_overrides[3]
}

//
// :IMAGE STUFF
//
Image_Id :: enum {
	nil,
	player,
	crawler,
}

Image :: struct {
	width, height: i32,
	tex_index: u8,
	sg_img: sg.Image,
	data: [^]byte,
	atlas_uvs: Vector4,
}
images: [128]Image
image_count: int

init_images :: proc() {
	using fmt

	img_dir := "res/images/"
	
	highest_id := 0;
	for img_name, id in Image_Id {
		if id == 0 { continue }
		
		if id > highest_id {
			highest_id = id
		}
		
		path := tprint(img_dir, img_name, ".png", sep="")
		png_data, succ := os.read_entire_file(path)
		assert(succ)
		
		stbi.set_flip_vertically_on_load(1)
		width, height, channels: i32
		img_data := stbi.load_from_memory(raw_data(png_data), auto_cast len(png_data), &width, &height, &channels, 4)
		assert(img_data != nil, "stbi load failed, invalid image?")
			
		img : Image;
		img.width = width
		img.height = height
		img.data = img_data
		
		images[id] = img
	}
	image_count = highest_id + 1
	
	pack_images_into_atlas()
}

Atlas :: struct {
	w, h: int,
	sg_image: sg.Image,
}
atlas: Atlas
// We're hardcoded to use just 1 atlas now since I don't think we'll need more
// It would be easy enough to extend though. Just add in more texture slots in the shader
pack_images_into_atlas :: proc() {

	// TODO - add a single pixel of padding for each so we avoid the edge oversampling issue

	// 8192 x 8192 is the WGPU recommended max I think
	atlas.w = 128
	atlas.h = 128
	
	cont : stbrp.Context
	nodes : [128]stbrp.Node // #volatile with atlas.w
	stbrp.init_target(&cont, auto_cast atlas.w, auto_cast atlas.h, &nodes[0], auto_cast atlas.w)
	
	rects : [dynamic]stbrp.Rect
	for img, id in images {
		if img.width == 0 {
			continue
		}
		append(&rects, stbrp.Rect{ id=auto_cast id, w=auto_cast img.width, h=auto_cast img.height })
	}
	
	succ := stbrp.pack_rects(&cont, &rects[0], auto_cast len(rects))
	if succ == 0 {
		assert(false, "failed to pack all the rects, ran out of space?")
	}
	
	// allocate big atlas
	raw_data, err := mem.alloc(atlas.w * atlas.h * 4)
	defer mem.free(raw_data)
	mem.set(raw_data, 255, atlas.w*atlas.h*4)
	
	// copy rect row-by-row into destination atlas
	for rect in rects {
		img := &images[rect.id]
		
		// copy row by row into atlas
		for row in 0..<rect.h {
			src_row := mem.ptr_offset(&img.data[0], row * rect.w * 4)
			dest_row := mem.ptr_offset(cast(^u8)raw_data, ((rect.y + row) * auto_cast atlas.w + rect.x) * 4)
			mem.copy(dest_row, src_row, auto_cast rect.w * 4)
		}
		
		// yeet old data
		stbi.image_free(img.data)
		img.data = nil;
		
		// img.atlas_x = auto_cast rect.x
		// img.atlas_y = auto_cast rect.y
		
		img.atlas_uvs.x = cast(f32)rect.x / cast(f32)atlas.w
		img.atlas_uvs.y = cast(f32)rect.y / cast(f32)atlas.h
		img.atlas_uvs.z = img.atlas_uvs.x + cast(f32)img.width / cast(f32)atlas.w
		img.atlas_uvs.w = img.atlas_uvs.y + cast(f32)img.height / cast(f32)atlas.h
	}
	
	stbi.write_png("atlas.png", auto_cast atlas.w, auto_cast atlas.h, 4, raw_data, 4 * auto_cast atlas.w)
	
	// setup image for GPU
	desc : sg.Image_Desc
	desc.width = auto_cast atlas.w
	desc.height = auto_cast atlas.h
	desc.pixel_format = .RGBA8
	desc.data.subimage[0][0] = {ptr=raw_data, size=auto_cast (atlas.w*atlas.h*4)}
	atlas.sg_image = sg.make_image(desc)
	if atlas.sg_image.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
}

//
// :FONT
//
draw_text :: proc(pos: Vector2, text: string, scale:= 1.0) {
	using stbtt
	
	x: f32
	y: f32

	for char in text {
		
		advance_x: f32
		advance_y: f32
		q: aligned_quad
		GetBakedQuad(&font.char_data[0], font_bitmap_w, font_bitmap_h, cast(i32)char - 32, &advance_x, &advance_y, &q, false)
		// this is the the data for the aligned_quad we're given, with y+ going down
		// x0, y0,     s0, t0, // top-left
		// x1, y1,     s1, t1, // bottom-right
		
		
		size := v2{ abs(q.x0 - q.x1), abs(q.y0 - q.y1) }
		
		bottom_left := v2{ q.x0, -q.y1 }
		top_right := v2{ q.x1, -q.y0 }
		assert(bottom_left + size == top_right)
		
		offset_to_render_at := v2{x,y} + bottom_left
		
		uv := v4{ q.s0, q.t1,
							q.s1, q.t0 }
		
		xform := Matrix4(1)
		xform *= xform_translate(pos)
		xform *= xform_scale(v2{auto_cast scale, auto_cast scale})
		xform *= xform_translate(offset_to_render_at)
		draw_rect_xform(xform, size, uv=uv, img_id=font.img_id)
		
		x += advance_x
		y += -advance_y
	}

}

font_bitmap_w :: 256
font_bitmap_h :: 256
char_count :: 96
Font :: struct {
	char_data: [char_count]stbtt.bakedchar,
	img_id: Image_Id,
}
font: Font

init_fonts :: proc() {
	using stbtt
	
	bitmap, _ := mem.alloc(font_bitmap_w * font_bitmap_h)
	font_height := 15 // for some reason this only bakes properly at 15 ? it's a 16px font dou...
	path := "res/fonts/alagard.ttf"
	ttf_data, err := os.read_entire_file(path)
	assert(ttf_data != nil, "failed to read font")
	
	ret := BakeFontBitmap(raw_data(ttf_data), 0, auto_cast font_height, auto_cast bitmap, font_bitmap_w, font_bitmap_h, 32, char_count, &font.char_data[0])
	assert(ret > 0, "not enough space in bitmap")
	
	stbi.write_png("font.png", auto_cast font_bitmap_w, auto_cast font_bitmap_h, 1, bitmap, auto_cast font_bitmap_w)
	
	// setup font atlas so we can use it in the shader
	desc : sg.Image_Desc
	desc.width = auto_cast font_bitmap_w
	desc.height = auto_cast font_bitmap_h
	desc.pixel_format = .R8
	desc.data.subimage[0][0] = {ptr=bitmap, size=auto_cast (font_bitmap_w*font_bitmap_h)}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
	}
	
	id := store_image(font_bitmap_w, font_bitmap_h, 1, sg_img)
	font.img_id = id
}
// kind scuffed...
// but I'm abusing the Images to store the font atlas by just inserting it at the end with the next id
store_image :: proc(w: int, h: int, tex_index: u8, sg_img: sg.Image) -> Image_Id {

	img : Image
	img.width = auto_cast w
	img.height = auto_cast h
	img.tex_index = tex_index
	img.sg_img = sg_img
	img.atlas_uvs = DEFAULT_UV
	
	id := image_count
	images[id] = img
	image_count += 1
	
	return auto_cast id
}

//
// :GAME

Game_State :: struct {
	tick_index: u64,
	entities: [128]Entity,
	latest_entity_handle: Entity_Handle,
}

Message_Kind :: enum {
	move_left,
	move_right,
	jump,
	create_player,
}

Message :: struct {
	kind: Message_Kind,
	from_entity: Entity_Handle,
	using variant: struct #raw_union {
		create_player: struct {
			user_id: UserID,
		}
	}
}

add_message :: proc(messages: ^[dynamic]Message, new_message: Message) -> ^Message {

	for msg in messages {
		#partial switch msg.kind {
			case:
			if msg.kind == new_message.kind {
				return nil;
			}
		}
	}

	index := append(messages, new_message) - 1
	return &messages[index]
}

//
// :ENTITY

Entity_Flags :: enum {
	allocated,
	physics
}

Entity_Kind :: enum {
	nil,
	player,
}

Entity :: struct {
	id: Entity_Handle,
	kind: Entity_Kind,
	flags: bit_set[Entity_Flags],
	pos: Vector2,
	user_id: UserID,
	
	frame: struct{
		input_axis: Vector2,
	}
}

Entity_Handle :: u64

handle_to_entity :: proc(gs: ^Game_State, handle: Entity_Handle) -> ^Entity {
	for &en in gs.entities {
		if (.allocated in en.flags) && en.id == handle {
			return &en
		}
	}
	log_error("entity no longer valid")
	return nil
}

entity_to_handle :: proc(gs: Game_State, entity: Entity) -> Entity_Handle {
	return entity.id
}

entity_create :: proc(gs:^Game_State) -> ^Entity {
	spare_en : ^Entity
	for &en in gs.entities {
		if !(.allocated in en.flags) {
			spare_en = &en
			break
		}
	}
	
	if spare_en == nil {
		log_error("ran out of entities, increase size")
		return nil
	} else {
		spare_en.flags = { .allocated }
		gs.latest_entity_handle += 1
		spare_en.id = gs.latest_entity_handle
		return spare_en
	}
}

entity_destroy :: proc(gs:^Game_State, entity: ^Entity) {
	mem.set(entity, 0, size_of(Entity))
}

setup_player :: proc(e: ^Entity) {
	e.kind = .player
	e.flags |= { .physics }
}


//
// THE GAMEPLAY LINE
//

//
// :sim

sim_game_state :: proc(gs: ^Game_State, delta_t: f64, messages: []Message) {
	defer gs.tick_index += 1
	
	for &en in gs.entities {
		en.frame = {}
	}
	
	for msg in messages {
		#partial switch msg.kind {
			case .create_player: {
			
				user_id := msg.create_player.user_id
				assert(user_id != 0, "invalid user id")
				
				existing_user := false
				for en in gs.entities {
					if en.user_id == user_id {
						existing_user = true
						break
					}
				}
			
				if !existing_user {
					e := entity_create(gs)
					setup_player(e)
					e.user_id = user_id
				}
				
			}
		}
	}
	
	for msg in messages {
		#partial switch msg.kind {
			case .move_left: {
				en := handle_to_entity(gs, msg.from_entity)
				en.frame.input_axis.x += -1.0
			}
			case .move_right: {
				en := handle_to_entity(gs, msg.from_entity)
				en.frame.input_axis.x += 1.0
			}
		}
	}
	
	for &en in gs.entities {
		if en.kind == .player {
			speed := 100.0
			loggie(en.frame.input_axis)
			en.pos += en.frame.input_axis * auto_cast (speed * delta_t)
		}
	}
}

//
// :draw :user

draw_game_state :: proc(gs: Game_State, input_state: Input_State, messages_out: ^[dynamic]Message) {
	using linalg
	
	player: Entity
	player_handle: Entity_Handle
	for en in gs.entities {
		if en.kind == .player && en.user_id == app_state.user_id {
			player = en
			player_handle = entity_to_handle(gs, player)
			break
		}
	}
	
	if player_handle == 0 {
		append(messages_out, (Message){ kind=.create_player, create_player={ user_id=app_state.user_id } })
	}

	draw_frame.projection = matrix_ortho3d_f32(window_w * -0.5, window_w * 0.5, window_h * -0.5, window_h * 0.5, -1, 1)
	
	draw_frame.camera_xform = Matrix4(1)
	draw_frame.camera_xform *= xform_scale(2)
	
	// draw_sprite(v2{}, .player, pivot=.bottom_center)
	
	alpha := f32(math.mod(seconds_since_init() * 0.2, 1.0))
	xform := xform_rotate(alpha * 360.0)
	xform *= xform_scale(1.0 + 1 * sine_breathe(alpha))
	draw_sprite(v2{-50, 50}, .crawler, xform=xform, pivot=.center_center)
	
	draw_text(v2{50, 0}, "sugon", scale=4.0)
	
	for en in gs.entities {
		#partial switch en.kind {
			case .player: draw_player(en)
		}
	}
	
	// :input example
	// we want to do the input here, because we'll need context on things like UI rects that
	// we draw for clicking buttons n shit
	
	if player_handle != 0 {	
		if key_down(input_state, auto_cast 'A') {
			add_message(messages_out, {kind=.move_left, from_entity=player_handle})
		}
		if key_down(input_state, auto_cast 'D') {
			add_message(messages_out, {kind=.move_right, from_entity=player_handle})
		}
		if key_down(input_state, .SPACE) {
			add_message(messages_out, {kind=.jump, from_entity=player_handle})
		}
	}
}

draw_player :: proc(en: Entity) {

	img := Image_Id.player
	
	xform := Matrix4(1)
	xform *= xform_scale(v2{1,1})
	
	draw_sprite(en.pos, img, pivot=.bottom_center, xform=xform)

}