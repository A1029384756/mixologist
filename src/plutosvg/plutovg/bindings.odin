package plutovg

import "core:c"

foreign import plutovg "system:plutovg"

@(default_calling_convention = "c", link_prefix = "plutovg_")
foreign plutovg {
	canvas_add_glyph :: proc(canvas: ^canvas_t, codepoint: codepoint_t, x: f32, y: f32) -> f32 ---
	canvas_add_path :: proc(canvas: ^canvas_t, path: ^path_t) ---
	canvas_add_text :: proc(canvas: ^canvas_t, text: rawptr, length: c.int, encoding: text_encoding_t, x: f32, y: f32) -> f32 ---
	canvas_arc :: proc(canvas: ^canvas_t, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, ccw: bool) ---
	canvas_arc_to :: proc(canvas: ^canvas_t, rx: f32, ry: f32, angle: f32, large_arc_flag: bool, sweep_flag: bool, x: f32, y: f32) ---
	canvas_circle :: proc(canvas: ^canvas_t, cx: f32, cy: f32, r: f32) ---
	canvas_clip :: proc(canvas: ^canvas_t) ---
	canvas_clip_extents :: proc(canvas: ^canvas_t, extents: ^rect_t) ---
	canvas_clip_path :: proc(canvas: ^canvas_t, path: ^path_t) ---
	canvas_clip_preserve :: proc(canvas: ^canvas_t) ---
	canvas_clip_rect :: proc(canvas: ^canvas_t, x: f32, y: f32, w: f32, h: f32) ---
	canvas_clip_text :: proc(canvas: ^canvas_t, text: rawptr, length: c.int, encoding: text_encoding_t, x: f32, y: f32) -> f32 ---
	canvas_close_path :: proc(canvas: ^canvas_t) ---
	canvas_create :: proc(surface: ^surface_t) -> ^canvas_t ---
	canvas_cubic_to :: proc(canvas: ^canvas_t, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) ---
	canvas_destroy :: proc(canvas: ^canvas_t) ---
	canvas_ellipse :: proc(canvas: ^canvas_t, cx: f32, cy: f32, rx: f32, ry: f32) ---
	canvas_fill :: proc(canvas: ^canvas_t) ---
	canvas_fill_extents :: proc(canvas: ^canvas_t, extents: ^rect_t) ---
	canvas_fill_path :: proc(canvas: ^canvas_t, path: ^path_t) ---
	canvas_fill_preserve :: proc(canvas: ^canvas_t) ---
	canvas_fill_rect :: proc(canvas: ^canvas_t, x: f32, y: f32, w: f32, h: f32) ---
	canvas_fill_text :: proc(canvas: ^canvas_t, text: rawptr, length: c.int, encoding: text_encoding_t, x: f32, y: f32) -> f32 ---
	canvas_font_metrics :: proc(canvas: ^canvas_t, ascent: ^f32, descent: ^f32, line_gap: ^f32, extents: ^rect_t) ---
	canvas_get_current_point :: proc(canvas: ^canvas_t, x: ^f32, y: ^f32) ---
	canvas_get_dash_array :: proc(canvas: ^canvas_t, dashes: ^^f32) -> c.int ---
	canvas_get_dash_offset :: proc(canvas: ^canvas_t) -> f32 ---
	canvas_get_fill_rule :: proc(canvas: ^canvas_t) -> fill_rule_t ---
	canvas_get_font_face :: proc(canvas: ^canvas_t) -> ^font_face_t ---
	canvas_get_font_size :: proc(canvas: ^canvas_t) -> f32 ---
	canvas_get_line_cap :: proc(canvas: ^canvas_t) -> line_cap_t ---
	canvas_get_line_join :: proc(canvas: ^canvas_t) -> line_join_t ---
	canvas_get_line_width :: proc(canvas: ^canvas_t) -> f32 ---
	canvas_get_matrix :: proc(canvas: ^canvas_t, _matrix: ^matrix_t) ---
	canvas_get_miter_limit :: proc(canvas: ^canvas_t) -> f32 ---
	canvas_get_opacity :: proc(canvas: ^canvas_t) -> f32 ---
	canvas_get_operator :: proc(canvas: ^canvas_t) -> operator_t ---
	canvas_get_paint :: proc(canvas: ^canvas_t, color: ^color_t) -> ^paint_t ---
	canvas_get_path :: proc(canvas: ^canvas_t) -> ^path_t ---
	canvas_get_reference_count :: proc(canvas: ^canvas_t) -> c.int ---
	canvas_get_surface :: proc(canvas: ^canvas_t) -> ^surface_t ---
	canvas_glyph_metrics :: proc(canvas: ^canvas_t, codepoint: codepoint_t, advance_width: ^f32, left_side_bearing: ^f32, extents: ^rect_t) ---
	canvas_map :: proc(canvas: ^canvas_t, x: f32, y: f32, xx: ^f32, yy: ^f32) ---
	canvas_map_point :: proc(canvas: ^canvas_t, src: ^point_t, dst: ^point_t) ---
	canvas_map_rect :: proc(canvas: ^canvas_t, src: ^rect_t, dst: ^rect_t) ---
	canvas_move_to :: proc(canvas: ^canvas_t, x: f32, y: f32) ---
	canvas_line_to :: proc(canvas: ^canvas_t, x: f32, y: f32) ---
	canvas_new_path :: proc(canvas: ^canvas_t) ---
	canvas_paint :: proc(canvas: ^canvas_t) ---
	canvas_quad_to :: proc(canvas: ^canvas_t, x1: f32, y1: f32, x2: f32, y2: f32) ---
	canvas_rect :: proc(canvas: ^canvas_t, x: f32, y: f32, w: f32, h: f32) ---
	canvas_reference :: proc(canvas: ^canvas_t) -> ^canvas_t ---
	canvas_reset_matrix :: proc(canvas: ^canvas_t) ---
	canvas_restore :: proc(canvas: ^canvas_t) ---
	canvas_rotate :: proc(canvas: ^canvas_t, angle: f32) ---
	canvas_round_rect :: proc(canvas: ^canvas_t, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) ---
	canvas_save :: proc(canvas: ^canvas_t) ---
	canvas_scale :: proc(canvas: ^canvas_t, sx: f32, sy: f32) ---
	canvas_set_color :: proc(canvas: ^canvas_t, color: ^color_t) ---
	canvas_set_dash :: proc(canvas: ^canvas_t, offset: f32, dashes: ^f32, ndashes: c.int) ---
	canvas_set_dash_array :: proc(canvas: ^canvas_t, dashes: ^f32, ndashes: c.int) ---
	canvas_set_dash_offset :: proc(canvas: ^canvas_t, offset: f32) ---
	canvas_set_fill_rule :: proc(canvas: ^canvas_t, winding: fill_rule_t) ---
	canvas_set_font :: proc(canvas: ^canvas_t, face: ^font_face_t, size: f32) ---
	canvas_set_font_face :: proc(canvas: ^canvas_t, face: ^font_face_t) ---
	canvas_set_font_size :: proc(canvas: ^canvas_t, size: f32) ---
	canvas_set_linear_gradient :: proc(canvas: ^canvas_t, x1: f32, y1: f32, x2: f32, y2: f32, spread: spread_method_t, stops: ^gradient_stop_t, nstops: c.int, _matrix: ^matrix_t) ---
	canvas_set_line_cap :: proc(canvas: ^canvas_t, line_cap: line_cap_t) ---
	canvas_set_line_join :: proc(canvas: ^canvas_t, line_join: line_join_t) ---
	canvas_set_line_width :: proc(canvas: ^canvas_t, line_width: f32) ---
	canvas_set_matrix :: proc(canvas: ^canvas_t, _matrix: ^matrix_t) ---
	canvas_set_miter_limit :: proc(canvas: ^canvas_t, miter_limit: f32) ---
	canvas_set_opacity :: proc(canvas: ^canvas_t, opacity: f32) ---
	canvas_set_operator :: proc(canvas: ^canvas_t, op: operator_t) ---
	canvas_set_paint :: proc(canvas: ^canvas_t, paint: ^paint_t) ---
	canvas_set_radial_gradient :: proc(canvas: ^canvas_t, cx: f32, cy: f32, cr: f32, fx: f32, fy: f32, fr: f32, spread: spread_method_t, stops: ^gradient_stop_t, nstops: c.int, _matrix: ^matrix_t) ---
	canvas_set_rgb :: proc(canvas: ^canvas_t, r: f32, g: f32, b: f32) ---
	canvas_set_rgba :: proc(canvas: ^canvas_t, r: f32, g: f32, b: f32, a: f32) ---
	canvas_set_texture :: proc(canvas: ^canvas_t, surface: ^surface_t, type: texture_type_t, opacity: f32, _matrix: ^matrix_t) ---
	canvas_shear :: proc(canvas: ^canvas_t, shx: f32, shy: f32) ---
	canvas_stroke :: proc(canvas: ^canvas_t) ---
	canvas_stroke_extents :: proc(canvas: ^canvas_t, extents: ^rect_t) ---
	canvas_stroke_path :: proc(canvas: ^canvas_t, path: ^path_t) ---
	canvas_stroke_preserve :: proc(canvas: ^canvas_t) ---
	canvas_stroke_rect :: proc(canvas: ^canvas_t, x: f32, y: f32, w: f32, h: f32) ---
	canvas_stroke_text :: proc(canvas: ^canvas_t, text: rawptr, length: c.int, encoding: text_encoding_t, x: f32, y: f32) -> f32 ---
	canvas_text_extents :: proc(canvas: ^canvas_t, text: rawptr, length: c.int, encoding: text_encoding_t, extents: ^rect_t) -> f32 ---
	canvas_transform :: proc(canvas: ^canvas_t, _matrix: ^matrix_t) ---
	canvas_translate :: proc(canvas: ^canvas_t, tx: f32, ty: f32) ---
	version :: proc() -> c.int ---
	version_string :: proc() -> cstring ---
	font_face_destroy :: proc(face: ^font_face_t) ---
	font_face_get_glyph_metrics :: proc(face: ^font_face_t, size: f32, codepoint: codepoint_t, advance_width: ^f32, left_side_bearing: ^f32, extents: ^rect_t) ---
	font_face_get_glyph_path :: proc(face: ^font_face_t, size: f32, x: f32, y: f32, codepoint: codepoint_t, path: ^path_t) -> f32 ---
	font_face_get_metrics :: proc(face: ^font_face_t, size: f32, ascent: ^f32, descent: ^f32, line_gap: ^f32, extents: ^rect_t) ---
	font_face_get_reference_count :: proc(face: ^font_face_t) -> c.int ---
	font_face_load_from_data :: proc(data: rawptr, length: c.uint, ttcindex: c.int, destroy_func: destroy_func_t, closure: rawptr) -> ^font_face_t ---
	font_face_load_from_file :: proc(filename: cstring, ttcindex: c.int) -> ^font_face_t ---
	font_face_reference :: proc(face: ^font_face_t) -> ^font_face_t ---
	font_face_text_extents :: proc(face: ^font_face_t, size: f32, text: rawptr, length: c.int, encoding: text_encoding_t, extents: ^rect_t) -> f32 ---
	font_face_traverse_glyph_path :: proc(face: ^font_face_t, size: f32, x: f32, y: f32, codepoint: codepoint_t, traverse_func: path_traverse_func_t, closure: rawptr) -> f32 ---
	text_iterator_has_next :: proc(it: ^text_iterator_t) -> bool ---
	text_iterator_init :: proc(it: ^text_iterator_t, text: rawptr, length: c.int, encoding: text_encoding_t) ---
	text_iterator_next :: proc(it: ^text_iterator_t) -> codepoint_t ---
	matrix_init :: proc(_matrix: ^matrix_t, a: f32, b: f32, _c: f32, d: f32, e: f32, f: f32) ---
	color_init_argb32 :: proc(color: ^color_t, value: c.uint) ---
	color_parse :: proc(color: ^color_t, data: cstring, length: c.int) -> c.int ---
	color_to_argb32 :: proc(color: ^color_t) -> c.uint ---
	matrix_init_identity :: proc(_matrix: ^matrix_t) ---
	matrix_init_rotate :: proc(_matrix: ^matrix_t, angle: f32) ---
	matrix_init_scale :: proc(_matrix: ^matrix_t, sx: f32, sy: f32) ---
	matrix_init_shear :: proc(_matrix: ^matrix_t, shx: f32, shy: f32) ---
	matrix_init_translate :: proc(_matrix: ^matrix_t, tx: f32, ty: f32) ---
	matrix_invert :: proc(_matrix: ^matrix_t, inverse: ^matrix_t) -> bool ---
	matrix_map :: proc(_matrix: ^matrix_t, x: f32, y: f32, xx: ^f32, yy: ^f32) ---
	matrix_map_point :: proc(_matrix: ^matrix_t, src: ^point_t, dst: ^point_t) ---
	matrix_map_points :: proc(_matrix: ^matrix_t, src: ^point_t, dst: ^point_t, count: c.int) ---
	matrix_map_rect :: proc(_matrix: ^matrix_t, src: ^rect_t, dst: ^rect_t) ---
	matrix_multiply :: proc(_matrix: ^matrix_t, left: ^matrix_t, right: ^matrix_t) ---
	matrix_parse :: proc(_matrix: ^matrix_t, data: cstring, length: c.int) -> bool ---
	matrix_rotate :: proc(_matrix: ^matrix_t, angle: f32) ---
	matrix_scale :: proc(_matrix: ^matrix_t, sx: f32, sy: f32) ---
	matrix_shear :: proc(_matrix: ^matrix_t, shx: f32, shy: f32) ---
	matrix_translate :: proc(_matrix: ^matrix_t, tx: f32, ty: f32) ---
	color_init_hsl :: proc(color: ^color_t, h: f32, s: f32, l: f32) ---
	color_init_hsla :: proc(color: ^color_t, h: f32, s: f32, l: f32, a: f32) ---
	color_init_rgb :: proc(color: ^color_t, r: f32, g: f32, b: f32) ---
	color_init_rgb8 :: proc(color: ^color_t, r: c.int, g: c.int, b: c.int) ---
	color_init_rgba :: proc(color: ^color_t, r: f32, g: f32, b: f32, a: f32) ---
	color_init_rgba32 :: proc(color: ^color_t, value: c.uint) ---
	color_init_rgba8 :: proc(color: ^color_t, r: c.int, g: c.int, b: c.int, a: c.int) ---
	color_to_rgba32 :: proc(color: ^color_t) -> c.uint ---
	paint_create_color :: proc(color: ^color_t) -> ^paint_t ---
	paint_create_linear_gradient :: proc() ---
	paint_create_radial_gradient :: proc(cx: f32, cy: f32, cr: f32, fx: f32, fy: f32, fr: f32, spread: spread_method_t, stops: ^gradient_stop_t, nstops: c.int, _matrix: ^matrix_t) -> ^paint_t ---
	paint_create_rgb :: proc(r: f32, g: f32, b: f32) -> ^paint_t ---
	paint_create_rgba :: proc(r: f32, g: f32, b: f32, a: f32) -> ^paint_t ---
	paint_create_texture :: proc(surface: ^surface_t, type: texture_type_t, opacity: f32, _matrix: ^matrix_t) -> ^paint_t ---
	paint_destroy :: proc(paint: ^paint_t) ---
	paint_get_reference_count :: proc(paint: ^paint_t) -> c.int ---
	paint_reference :: proc(paint: ^paint_t) -> ^paint_t ---
	path_add_arc :: proc(path: ^path_t, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, ccw: bool) ---
	path_add_circle :: proc(path: ^path_t, cx: f32, cy: f32, r: f32) ---
	path_add_ellipse :: proc(path: ^path_t, cx: f32, cy: f32, rx: f32, ry: f32) ---
	path_add_round_rect :: proc(path: ^path_t, x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) ---
	path_arc_to :: proc(path: ^path_t, rx: f32, ry: f32, angle: f32, large_arc_flag: bool, sweep_flag: bool, x: f32, y: f32) ---
	path_clone :: proc(path: ^path_t) -> ^path_t ---
	path_clone_dashed :: proc(path: ^path_t, offset: f32, dashes: ^f32, ndashes: c.int) -> ^path_t ---
	path_clone_flatten :: proc(path: ^path_t) -> ^path_t ---
	path_close :: proc(path: ^path_t) ---
	path_create :: proc() -> ^path_t ---
	path_cubic_to :: proc(path: ^path_t, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32) ---
	path_destroy :: proc(path: ^path_t) ---
	path_extents :: proc(path: ^path_t, extents: ^rect_t, tight: bool) -> f32 ---
	path_get_current_point :: proc(path: ^path_t, x: ^f32, y: ^f32) ---
	path_get_elements :: proc(path: ^path_t, elements: ^^path_element_t) -> c.int ---
	path_get_reference_count :: proc(path: ^path_t) -> c.int ---
	path_iterator_has_next :: proc(it: ^path_iterator_t) -> bool ---
	path_iterator_init :: proc(it: ^path_iterator_t, path: ^path_t) ---
	path_iterator_next :: proc(it: ^path_iterator_t, points: ^point_t) -> path_command_t ---
	path_length :: proc(path: ^path_t) -> f32 ---
	path_line_to :: proc(path: ^path_t, x: f32, y: f32) ---
	path_move_to :: proc(path: ^path_t, x: f32, y: f32) ---
	path_parse :: proc(path: ^path_t, data: cstring, length: c.int) -> bool ---
	path_quad_to :: proc(path: ^path_t, x1: f32, y1: f32, x2: f32, y2: f32) ---
	path_reference :: proc(path: ^path_t) -> ^path_t ---
	path_reserve :: proc(path: ^path_t, count: c.int) ---
	path_reset :: proc(path: ^path_t) ---
	path_transform :: proc(path: ^path_t, _matrix: ^matrix_t) ---
	path_traverse :: proc(path: ^path_t, traverse_func: path_traverse_func_t, closure: rawptr) ---
	path_traverse_dashed :: proc(path: ^path_t, offset: f32, dashes: ^f32, ndashes: c.int, traverse_func: path_traverse_func_t, closure: rawptr) ---
	path_traverse_flatten :: proc(path: ^path_t, traverse_func: path_traverse_func_t, closure: rawptr) ---
	convert_argb_to_rgba :: proc(dst: ^c.uchar, src: ^c.uchar, width: c.int, height: c.int, stride: c.int) ---
	convert_rgba_to_argb :: proc(dst: ^c.uchar, src: ^c.uchar, width: c.int, height: c.int, stride: c.int) ---
	surface_clear :: proc(surface: ^surface_t, color: ^color_t) ---
	surface_create :: proc(width: c.int, height: c.int) -> ^surface_t ---
	surface_create_for_data :: proc(data: ^c.uchar, width: c.int, height: c.int, stride: c.int) -> ^surface_t ---
	surface_destroy :: proc(surface: ^surface_t) ---
	surface_get_reference_count :: proc(surface: ^surface_t) -> c.int ---
	surface_get_data :: proc(surface: ^surface_t) -> ^c.uchar ---
	surface_get_stride :: proc(surface: ^surface_t) -> c.int ---
	surface_get_height :: proc(surface: ^surface_t) -> c.int ---
	surface_get_width :: proc(surface: ^surface_t) -> c.int ---
	surface_load_from_image_base64 :: proc(data: cstring, length: c.int) -> ^surface_t ---
	surface_load_from_image_data :: proc(data: rawptr, length: c.int) -> ^surface_t ---
	surface_load_from_image_file :: proc(filename: cstring) -> ^surface_t ---
	surface_reference :: proc(surface: ^surface_t) -> ^surface_t ---
	surface_write_to_jpg :: proc(surface: ^surface_t, filename: cstring, quality: c.int) -> bool ---
	surface_write_to_jpg_stream :: proc(surface: ^surface_t, write_func: write_func_t, closure: rawptr, quality: c.int) -> bool ---
	surface_write_to_png :: proc(surface: ^surface_t, filename: cstring) -> bool ---
	surface_write_to_png_stream :: proc(surface: ^surface_t, write_func: write_func_t, closure: rawptr) -> bool ---
}
