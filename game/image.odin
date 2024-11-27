package main

import "core:os"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"

import sg "../sokol/gfx"
import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"

Image_Id :: enum {
	nil,	
	player,
	crawler,
}

Image :: struct {
	width, height: i32,
	data: [^]byte,
	atlas_x, atlas_y: int, // probs not useful
	atlas_uvs: Vector4,
}
images: [128]Image

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

	pack_images_into_atlas()
}

load_image_from_disk :: proc(path: string) -> (Image, bool) {

	loggie(path)
	//stbi.set_flip_vertically_on_load(1)
	
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
	
	ret : Image;
	ret.width = width
	ret.height = height
	ret.data = img_data
	
	return ret, true
}

Atlas :: struct {
	w, h: int,
	sg_image: sg.Image,
}
atlas: Atlas
// We're hardcoded to use just 1 atlas now since I don't think we'll need more
// It would be easy enough to extend though. Just add in more texture slots in the shader
pack_images_into_atlas :: proc() {

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
		
		img.atlas_x = auto_cast rect.x
		img.atlas_y = auto_cast rect.y
		
		img.atlas_uvs.x = cast(f32)img.atlas_x / cast(f32)atlas.w
		img.atlas_uvs.y = cast(f32)img.atlas_y / cast(f32)atlas.h
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