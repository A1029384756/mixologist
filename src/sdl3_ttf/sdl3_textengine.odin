package sdl3_ttf

import "core:c"

// ENUM
// ----------
DrawCommand :: enum (c.int) {
	NOOP,
	FILL,
	COPY,
}

// STRUCTS
// ----------
FillOperation :: struct {
	cmd:  DrawCommand,
	rect: Rect,
}

CopyOperation :: struct {
	cmd:         DrawCommand,
	text_offset: c.int,
	glyph_font:  [^]Font,
	glyph_index: Uint32,
	src:         Rect,
	dst:         Rect,
	reserved:    rawptr,
}

DrawOperation :: struct #raw_union {
	cmd:  DrawCommand,
	fill: FillOperation,
	copy: CopyOperation,
}

TextLayout :: struct {
}

TextData :: struct {
	font:                ^Font,
	color:               Color,
	needs_layout_update: bool,
	layout:              ^TextLayout,
	x:                   c.int,
	y:                   c.int,
	w:                   c.int,
	h:                   c.int,
	num_ops:             c.int,
	ops:                 [^]DrawOperation,
	num_clusters:        c.int,
	clusters:            [^]SubString,
	props:               PropertiesID,
	needs_engine_update: bool,
	engine:              ^TextEngine,
	engine_text:         rawptr,
}

TextEngine :: struct {
	version:      Uint32,
	userdata:     rawptr,
	create_text:  proc "c" (userdata: rawptr, text: ^Text),
	destroy_text: proc "c" (userdata: rawptr, text: ^Text),
}

#assert(
	(size_of(TextEngine) == 16 && size_of(rawptr) == 4) ||
	(size_of(TextEngine) == 32 && size_of(rawptr) == 8),
)
