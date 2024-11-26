package main

import "core:math"
import "core:math/linalg"

Vertex :: struct {
	pos: Vector2,
	col: Vector4,
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

draw_quad_projected :: proc(
	world_to_clip:   Matrix4, 
	positions:       [4]Vector2,
	colors:          [4]Vector4,
	//uvs:             [4]Vector2,
	//image_ids:       [4]Image_Id,
	//flags:           [4]Quad_Flags,
	//color_overrides: [4]Vector4,
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

}

draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
) {

	bl := v2{ 0, 0 }
	tl := v2{ 0, size.y }
	tr := v2{ size.x, size.y }
	br := v2{ size.x, 0 }
	
	draw_quad_projected(world_to_clip, {bl, tl, tr, br}, {col, col, col, col})

}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
) {
	draw_rect_projected(draw_frame.projection * draw_frame.camera_xform * xform, size, col)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col)
}