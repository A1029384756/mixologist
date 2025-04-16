package sdl3_ttf

GlyphHashTable_NukeFn :: #type proc "c" (balue: rawptr)

@(default_calling_convention = "c", link_prefix = "SDL_")
foreign lib {
	CrateGlyphHashTable :: proc(nukefn: GlyphHashTable_NukeFn) -> ^HashTable ---
	InsertIntoGlyphHashTable :: proc(table: ^HashTable, font: ^Font, glyph_index: Uint32, value: rawptr) -> bool ---
	FindInGlyphHashTable :: proc(table: ^HashTable, font: ^Font, glyph_index: Uint32, value: [^]rawptr) -> bool ---
	DestroyGlyphHashTable :: proc(table: ^HashTable) ---
}

