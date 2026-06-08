package xdg_desktop_portals

import "core:os"

_string_subst_bytes :: proc(input: string, og, replacement: byte) {
	input_bytes := transmute([]u8)input
	for &input_byte in input_bytes {
		if input_byte == og do input_byte = replacement
	}
}

is_flatpak :: proc() -> bool {
	return os.exists("/.flatpak-info")
}
