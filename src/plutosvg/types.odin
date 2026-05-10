package plutosvg

import "core:c"
import "plutovg"

rect_t :: plutovg.rect_t
destroy_func_t :: plutovg.destroy_func_t
canvas_t :: plutovg.canvas_t
color_t :: plutovg.color_t
surface_t :: plutovg.surface_t
path_t :: plutovg.path_t

palette_func_t :: proc "c" (_: rawptr, _: cstring, _: c.int, _: ^color_t) -> bool

string_t :: struct {
	data:   cstring,
	length: c.size_t,
}

attribute_t :: struct {
	id:    c.int,
	value: string_t,
	next:  ^attribute_t,
}

element_t :: struct {
	id:           c.int,
	parent:       ^element_t,
	last_child:   ^element_t,
	first_child:  ^element_t,
	next_sibling: ^element_t,
	attributes:   ^attribute_t,
}

heap_chunk_t :: struct {
	next: ^heap_chunk_t,
}

heap_t :: struct {
	chunk: ^heap_chunk_t,
	size:  c.size_t,
}

hashmap_entry_t :: struct {
	hash:  c.size_t,
	name:  string_t,
	value: rawptr,
	next:  ^hashmap_entry_t,
}

hashmap_t :: struct {
	buckets:  ^^hashmap_entry_t,
	size:     c.size_t,
	capacity: c.size_t,
}

document_t :: struct {
	heap:         ^heap_t,
	path:         ^path_t,
	id_cache:     ^hashmap_t,
	root_element: ^element_t,
	destroy_func: destroy_func_t,
	closure:      rawptr,
	width:        c.float,
	height:       c.float,
}
