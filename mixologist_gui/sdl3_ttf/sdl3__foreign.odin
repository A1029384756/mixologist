package sdl3_ttf

when ODIN_OS == .Windows {
	@(export) foreign import lib { "SDL3_ttf.lib" }
} else {
	@(export) foreign import lib { "system:SDL3_ttf" }
}

