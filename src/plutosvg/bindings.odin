package plutosvg

import "core:c"

foreign import plutosvg "system:plutosvg"

@(default_calling_convention = "c", link_prefix = "plutosvg_")
foreign plutosvg {
	document_destroy :: proc(document: ^document_t) ---
	document_extents :: proc(document: ^document_t, id: cstring, extents: ^rect_t) -> bool ---
	document_get_height :: proc(document: ^document_t) -> f32 ---
	document_get_width :: proc(document: ^document_t) -> f32 ---
	document_load_from_data :: proc(data: [^]u8, length: c.int, width: f32, height: f32, destroy_func: destroy_func_t, closure: rawptr) -> ^document_t ---
	document_load_from_file :: proc(filename: cstring, width: f32, height: f32) -> ^document_t ---
	document_render :: proc(document: ^document_t, id: cstring, canvas: ^canvas_t, current_color: ^color_t, palette_func: palette_func_t, closure: rawptr) -> bool ---
	document_render_to_surface :: proc(document: ^document_t, id: cstring, width: c.int, height: c.int, current_color: ^color_t, palette_func: palette_func_t, closure: rawptr) -> ^surface_t ---
	ft_svg_hooks :: proc() -> rawptr ---
	version :: proc() -> c.int ---
	version_string :: proc() -> cstring ---
}
