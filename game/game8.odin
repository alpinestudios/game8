package main

import "base:runtime"
import "base:intrinsics"
import t "core:time"
import "core:fmt"
import "core:os"
import "core:math"
import "core:math/linalg"
import "core:math/ease"
import "core:mem"

//
// :sim

sim_game_state :: proc(gs: ^Game_State, delta_t: f64, messages: []Message) {
	defer gs.tick_index += 1
	
	if gs.tick_index == 0 {
		e := entity_create(gs)
		setup_player(e)
	}
	
	for msg in messages {
		#partial switch msg.kind {
			case .move_left: loggie("MOVE LEFT")
			case .move_right:
		}
	}
}

//
// :draw :user

draw_game_state :: proc(game: Game_State, input_state: Input_State, messages_out: ^[dynamic]Message) {
	using linalg

	draw_frame.projection = matrix_ortho3d_f32(window_w * -0.5, window_w * 0.5, window_h * -0.5, window_h * 0.5, -1, 1)
	
	draw_frame.camera_xform = Matrix4(1)
	draw_frame.camera_xform *= xform_scale(2)
	
	alpha :f32= auto_cast math.mod(seconds_since_init() * 0.2, 1.0)
	xform := xform_rotate(alpha * 360.0)
	xform *= xform_scale(1.0 + 1 * sine_breathe(alpha))
	draw_sprite(v2{}, .player, pivot=.bottom_center)
	
	draw_sprite(v2{-50, 50}, .crawler, xform=xform, pivot=.center_center)
	
	draw_text(v2{50, 0}, "sugon", scale=4.0)
	
	
	// :input example
	// we want to do the input here, because we'll need context on things like UI rects that
	// we draw for clicking buttons n shit
	
	if key_down(input_state, auto_cast 'A') {
		append(messages_out, (Message){ kind=.move_left })
		loggie("sent move left")
	}
	
}