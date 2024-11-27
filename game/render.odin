package main

import "core:os"
import "core:fmt"
import "core:math"
import "core:math/linalg"

Vertex :: struct {
	pos: Vector2,
	col: Vector4,
	uv: Vector2,
	img_id: u8,
	_pad: [3]u8,
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
	uvs:             [4]Vector2,
	image_ids:       [4]Image_Id,
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

	verts[0].uv = uvs[0]
	verts[1].uv = uvs[1]
	verts[2].uv = uvs[2]
	verts[3].uv = uvs[3]
	
	verts[0].img_id = auto_cast image_ids[0]
	verts[1].img_id = auto_cast image_ids[1]
	verts[2].img_id = auto_cast image_ids[2]
	verts[3].img_id = auto_cast image_ids[3]
}

DEFAULT_UV :: v4{0, 0, 1, 1}
draw_rect_projected :: proc(
	world_to_clip: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
) {

	bl := v2{ 0, 0 }
	tl := v2{ 0, size.y }
	tr := v2{ size.x, size.y }
	br := v2{ size.x, 0 }
	
	draw_quad_projected(world_to_clip, {bl, tl, tr, br}, {col, col, col, col}, {uv.xy, uv.xw, uv.zw, uv.zy}, {img_id,img_id,img_id,img_id})

}

draw_rect_xform :: proc(
	xform: Matrix4,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
) {
	draw_rect_projected(draw_frame.projection * draw_frame.camera_xform * xform, size, col, uv, img_id)
}

draw_rect_aabb :: proc(
	pos: Vector2,
	size: Vector2,
	col: Vector4=COLOR_WHITE,
	uv: Vector4=DEFAULT_UV,
	img_id: Image_Id=.nil,
) {
	xform := linalg.matrix4_translate(v3{pos.x, pos.y, 0})
	draw_rect_xform(xform, size, col, uv, img_id)
}



// :image stuff

import stbi "vendor:stb/image"
import sg "../sokol/gfx"

// todo, use dis for atlas packing
//import "vendor:stb/rect_pack"

Image_Id :: enum {
	nil,
	
	player,
	crawler,
}

Image :: struct {
	sg_img: sg.Image,
	width, height: i32,
}
images: [128]Image
next_image_id: int

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
		img, succ := load_image_from_disk(path)
		if !succ {
			log_error("failed to load image:", img_name)
			continue
		}
		
		images[id] = img
	}
	
	next_image_id = highest_id + 1
}

load_image_from_disk :: proc(path: string) -> (Image, bool) {

	loggie(path)
	stbi.set_flip_vertically_on_load(1)
	
	png_data, succ := os.read_entire_file(path)
	if !succ {
		log_error("read file failed")
		return {}, false
	}
	
	width, height, channels: i32
	img_data := stbi.load_from_memory(raw_data(png_data), auto_cast len(png_data), &width, &height, &channels, 4)
	if img_data == nil {
		log_error("stbi load failed, invalid image?")
		return {}, false
	}
	defer stbi.image_free(img_data)
	
	return make_image(width, height, img_data), true
}

make_image :: proc(width: i32, height: i32, data: [^]byte) -> Image {
	
	// todo, some kind of atlas packing at this level
	
	desc : sg.Image_Desc
	desc.width = width
	desc.height = height
	desc.pixel_format = .RGBA8
	desc.data.subimage[0][0] = {ptr=data, size=auto_cast (width*height*4)}
	sg_img := sg.make_image(desc)
	if sg_img.id == sg.INVALID_ID {
		log_error("failed to make image")
		return {}
	}
	
	img : Image
	img.sg_img = sg_img
	img.width = width
	img.height = height
	
	return img
}