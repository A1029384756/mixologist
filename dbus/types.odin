package dbus

import "core:c"

bool_t :: b32

EightByteStruct :: struct {
	first32:  c.uint32_t,
	second32: c.uint32_t,
}

BasicValue :: struct #raw_union {
	bytes:    [8]byte,
	int16:    c.int16_t,
	uint16:   c.uint16_t,
	int32:    c.int32_t,
	uint32:   c.uint32_t,
	bool_val: bool_t,
	int64:    c.int64_t,
	uint64:   c.uint64_t,
	eight:    EightByteStruct,
	dbl:      c.double,
	byt:      byte,
	str:      cstring,
	fd:       c.int,
}

Type :: enum c.int {
	/** Type code that is never equal to a legitimate type code */
	INVALID     = 0,
	/* Primitive types */
	/** Type code marking an 8-bit unsigned integer */
	BYTE        = 'y',
	/** Type code marking a boolean */
	BOOLEAN     = 'b',
	/** Type code marking a 16-bit signed integer */
	INT16       = 'n',
	/** Type code marking a 16-bit unsigned integer */
	UINT16      = 'q',
	/** Type code marking a 32-bit signed integer */
	INT32       = 'i',
	/** Type code marking a 32-bit unsigned integer */
	UINT32      = 'u',
	/** Type code marking a 64-bit signed integer */
	INT64       = 'x',
	/** Type code marking a 64-bit unsigned integer */
	UINT64      = 't',
	/** Type code marking an 8-byte double in IEEE 754 format */
	DOUBLE      = 'd',
	/** Type code marking a UTF-8 encoded, nul-terminated Unicode string */
	STRING      = 's',
	/** Type code marking a D-Bus object path */
	OBJECT_PATH = 'o',
	/** Type code marking a D-Bus type signature */
	SIGNATURE   = 'g',
	/** Type code marking a unix file descriptor */
	UNIX_FD     = 'h',

	/* Compound types */
	/** Type code marking a D-Bus array type */
	ARRAY       = 'a',
	/** Type code marking a D-Bus variant type */
	VARIANT     = 'v',

	/** STRUCT and DICT_ENTRY are sort of special since their codes can't
	 * appear in a type string, instead
	 * DBUS_STRUCT_BEGIN_CHAR/DBUS_DICT_ENTRY_BEGIN_CHAR have to appear
	 */
	/** Type code used to represent a struct; however, this type code does not appear
	 * in type signatures, instead #DBUS_STRUCT_BEGIN_CHAR and #DBUS_STRUCT_END_CHAR will
	 * appear in a signature.
	 */
	STRUCT      = 'r',
	/** Type code used to represent a dict entry; however, this type code does not appear
	 * in type signatures, instead #DBUS_DICT_ENTRY_BEGIN_CHAR and #DBUS_DICT_ENTRY_END_CHAR will
	 * appear in a signature.
	 */
	DICT_ENTRY  = 'e',
}

/** Does not include #DBUS_TYPE_INVALID, #DBUS_STRUCT_BEGIN_CHAR, #DBUS_STRUCT_END_CHAR,
 * #DBUS_DICT_ENTRY_BEGIN_CHAR, or #DBUS_DICT_ENTRY_END_CHAR - i.e. it is the number of
 * valid types, not the number of distinct characters that may appear in a type signature.
 */
NUMBER_OF_TYPES :: 16
