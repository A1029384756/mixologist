package sdl3_ttf

HashTable :: struct {
}

// PROCEDURES
// ----------
HashTable_HashFn :: #type proc "c" (key: rawptr, data: rawptr) -> Uint32
HashTable_KeyMatchFn :: #type proc "c" (a: rawptr, b: rawptr, data: rawptr) -> bool
HashTable_NukeFn :: #type proc "c" (key: rawptr, value: rawptr, data: rawptr)

@(default_calling_convention = "c", link_prefix = "SDL_")
foreign lib {
	CreateHashTable :: proc(data: rawptr, num_buckets: Uint32, hashfn: HashTable_HashFn, keymatchfn: HashTable_KeyMatchFn, nukefn: HashTable_NukeFn, threadsafe: bool, stackable: bool) -> ^HashTable ---
	EmptyHashTable :: proc(table: ^HashTable) ---
	DestroyHashTable :: proc(table: ^HashTable) ---

	InsertIntoHashTable :: proc(table: ^HashTable, key: rawptr, value: rawptr) -> bool ---
	RemoveFromHashTable :: proc(table: ^HashTable, key: rawptr) -> bool ---
	FindInHashTable :: proc(table: ^HashTable, key: rawptr, _value: [^]rawptr) -> bool --- // TODO(devon): Check _value to determine if this is the correct type
	HashTableEmpty :: proc(table: ^HashTable) -> bool ---
	IterateHashTableKey :: proc(table: ^HashTable, key: rawptr, _value: [^]rawptr, iter: [^]rawptr) -> bool --- // TODO(devon): Check _value to determine if this is the correct type
	IterateHashTable :: proc(table: ^HashTable, _key: [^]rawptr, _value: [^]rawptr, iter: [^]rawptr) -> bool --- // TODO(devon): Check _value to determine if this is the correct type

	HashPointer :: proc(key: rawptr, unused: rawptr) -> Uint32 ---
	KeyMatchPointer :: proc(a: rawptr, b: rawptr, unused: rawptr) -> bool ---

	HashString :: proc(key: rawptr, unused: rawptr) -> Uint32 ---
	KeyMatchString :: proc(a: rawptr, b: rawptr, unused: rawptr) -> bool ---

	HashID :: proc(key: rawptr, unused: rawptr) -> Uint32 ---
	KeyMatchID :: proc(a: rawptr, b: rawptr, unused: rawptr) -> bool ---

	NukeFreeKey :: proc(key: rawptr, value: rawptr, unused: rawptr) ---
	NukeFreeValue :: proc(key: rawptr, value: rawptr, unused: rawptr) ---
}
