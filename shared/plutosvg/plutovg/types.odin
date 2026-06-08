package plutovg

import "core:c"

PLUTOVG_PI :: 3.14159265358979323846
PLUTOVG_TWO_PI :: 6.28318530717958647693
PLUTOVG_HALF_PI :: 1.57079632679489661923
PLUTOVG_SQRT2 :: 1.41421356237309504880
PLUTOVG_KAPPA :: 0.55228474983079339840

destroy_func_t :: proc "c" (_: rawptr)
write_func_t :: proc "c" (_: rawptr, _: rawptr, _: c.int)

point_t :: struct {
	x: f32,
	y: f32,
}

PLUTOVG_EMPTY_POINT :: (point_t){0, 0}

rect_t :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

PLUTOVG_EMPTY_RECT :: (rect_t){0, 0, 0, 0}

matrix_t :: struct {
	a:  f32,
	b:  f32,
	_c: f32,
	d:  f32,
	e:  f32,
	f:  f32,
}

PLUTOVG_IDENTITY_MATRIX :: (matrix_t){1, 0, 0, 1, 0, 0}

path_command_t :: enum c.int {
	MOVE_TO,
	LINE_TO,
	CUBIC_TO,
	CLOSE,
}

path_element_t :: struct #raw_union {
	header: struct {
		command: path_command_t,
		length:  c.int,
	},
	point:  point_t, ///< A coordinate point in the path.
}

path_iterator_t :: struct {
	elements: ^path_element_t,
	size:     c.int,
	index:    c.int,
}

path_traverse_func_t :: proc "c" (_: rawptr, _: path_command_t, _: ^point_t, _: c.int)

text_encoding_t :: enum c.int {
	LATIN1,
	UTF8,
	UTF16,
	UTF32,
}

text_iterator_t :: struct {
	text:     rawptr,
	length:   c.int,
	encoding: text_encoding_t,
	index:    c.int,
}

codepoint_t :: c.uint

color_t :: struct {
	r: f32,
	g: f32,
	b: f32,
	a: f32,
}

PLUTOVG_BLACK_COLOR :: (color_t){0, 0, 0, 1}
PLUTOVG_WHITE_COLOR :: (color_t){1, 1, 1, 1}
PLUTOVG_RED_COLOR :: (color_t){1, 0, 0, 1}
PLUTOVG_GREEN_COLOR :: (color_t){0, 1, 0, 1}
PLUTOVG_BLUE_COLOR :: (color_t){0, 0, 1, 1}
PLUTOVG_YELLOW_COLOR :: (color_t){1, 1, 0, 1}
PLUTOVG_CYAN_COLOR :: (color_t){0, 1, 1, 1}
PLUTOVG_MAGENTA_COLOR :: (color_t){1, 0, 1, 1}

texture_type_t :: enum c.int {
	PLAIN,
	TILED,
}

spread_method_t :: enum c.int {
	PAD,
	REFLECT,
	REPEAT,
}

gradient_stop_t :: struct {
	offset: f32,
	color:  color_t,
}

fill_rule_t :: enum c.int {
	NON_ZERO,
	EVEN_ODD,
}

operator_t :: enum c.int {
	CLEAR,
	SRC,
	DST,
	SRC_OVER,
	DST_OVER,
	SRC_IN,
	DST_IN,
	SRC_OUT,
	DST_OUT,
	SRC_ATOP,
	DST_ATOP,
	XOR,
}

line_cap_t :: enum c.int {
	BUTT,
	ROUND,
	SQUARE,
}

line_join_t :: enum c.int {
	MITER,
	ROUND,
	BEVEL,
}

surface_t :: struct {
	ref_count: c.int,
	width:     c.int,
	height:    c.int,
	stride:    c.int,
	data:      ^c.uchar,
}

path_t :: struct {
	ref_count:    c.int,
	num_points:   c.int,
	num_contours: c.int,
	num_curves:   c.int,
	start_point:  point_t,
	elements:     struct {
		data:     ^path_element_t,
		size:     c.int,
		capacity: c.int,
	},
}

paint_t :: struct {
	ref_count: c.int,
	type:      paint_type_t,
}

solid_paint_t :: struct {
	base:  paint_t,
	color: color_t,
}

gradient_type_t :: enum c.int {
	LINEAR,
	RADIAL,
}

gradient_paint_t :: struct {
	base:    paint_t,
	type:    gradient_type_t,
	spread:  spread_method_t,
	_matrix: matrix_t,
	stops:   ^gradient_stop_t,
	nstops:  c.int,
	values:  [6]f32,
}

texture_paint_t :: struct {
	base:    paint_t,
	type:    texture_type_t,
	opacity: f32,
	_matrix: matrix_t,
	surface: ^surface_t,
}

span_t :: struct {
	x:        c.int,
	len:      c.int,
	y:        c.int,
	coverage: c.uchar,
}

span_buffer_t :: struct {
	spans: struct {
		data:     ^span_t,
		size:     c.int,
		capacity: c.int,
	},
	x:     c.int,
	y:     c.int,
	w:     c.int,
	h:     c.int,
}

stroke_dash_t :: struct {
	offset: f32,
	array:  struct {
		data:     ^f32,
		size:     c.int,
		capacity: c.int,
	},
}

stroke_style_t :: struct {
	width:       f32,
	cap:         line_cap_t,
	join:        line_join_t,
	miter_limit: f32,
}

stroke_data_t :: struct {
	style: stroke_style_t,
	dash:  stroke_dash_t,
}

state_t :: struct {
	paint:      ^paint_t,
	font_face:  ^font_face_t,
	color:      color_t,
	_matrix:    matrix_t,
	stroke:     stroke_data_t,
	clip_spans: span_buffer_t,
	winding:    fill_rule_t,
	op:         operator_t,
	font_size:  f32,
	opacity:    f32,
	clipping:   bool,
	next:       ^state_t,
}

canvas_t :: struct {
	ref_count:   c.int,
	surface:     ^surface_t,
	path:        ^path_t,
	state:       ^state_t,
	freed_state: ^state_t,
	clip_rect:   rect_t,
	clip_spans:  span_buffer_t,
	fill_spans:  span_buffer_t,
}

paint_type_t :: enum c.int {
	COLOR,
	GRADIENT,
	TEXTURE,
}

_buf :: struct {
	data:   [^]byte,
	cursor: c.int,
	size:   c.int,
}

vertex_type :: distinct c.short // can't use stbtt_int16 because that's not visible in the header file
stbtt_vertex :: struct {
	x, y, cx, cy, cx1, cy1: vertex_type,
	type, padding:          byte,
}

stbtt_fontinfo :: struct {
	userdata:                                      rawptr,
	data:                                          [^]byte,
	fontstart:                                     c.int,
	numGlyphs:                                     c.int,
	loca, head, glyf, hhea, hmtx, kern, gpos, svg: c.int,
	index_map:                                     c.int,
	indexToLocFormat:                              c.int,
	cff:                                           _buf,
	charstrings:                                   _buf,
	gsubrs:                                        _buf,
	subrs:                                         _buf,
	fontdicts:                                     _buf,
	fdselect:                                      _buf,
}

glyph_t :: struct {
	vertices:          ^stbtt_vertex,
	nvertices:         c.int,
	index:             c.int,
	advance_width:     c.int,
	left_side_bearing: c.int,
	x1:                c.int,
	y1:                c.int,
	x2:                c.int,
	y2:                c.int,
}

GLYPH_CACHE_SIZE :: 256

font_face_t :: struct {
	ref_count:    c.int,
	ascent:       c.int,
	descent:      c.int,
	line_gap:     c.int,
	x1:           c.int,
	y1:           c.int,
	x2:           c.int,
	y2:           c.int,
	info:         stbtt_fontinfo,
	glyphs:       ^^[GLYPH_CACHE_SIZE]glyph_t,
	destroy_func: destroy_func_t,
	closure:      rawptr,
}
