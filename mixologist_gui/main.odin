package mixologist_gui

// import "../common"
// import pw "../pipewire"
import sdl "vendor:sdl2"
// import "vendor:sdl2/ttf"

main :: proc() {
	sdl.Init({.TIMER, .VIDEO})
	win := sdl.CreateWindow(
		"Mixologist",
		sdl.WINDOWPOS_UNDEFINED,
		sdl.WINDOWPOS_UNDEFINED,
		600,
		800,
		{},
	)
	assert(win != nil, sdl.GetErrorString())
	defer sdl.DestroyWindow(win)

	renderer := sdl.CreateRenderer(win, -1, {.ACCELERATED, .PRESENTVSYNC})
	assert(renderer != nil, sdl.GetErrorString())
	defer sdl.DestroyRenderer(renderer)

	for {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				return
			case .KEYDOWN:
				if event.key.keysym.scancode == sdl.SCANCODE_ESCAPE {
					return
				}
			}
		}

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 0)
		sdl.RenderClear(renderer)

		sdl.SetRenderDrawColor(renderer, 255, 0, 0, 255)
		sdl.RenderFillRect(renderer, &{10, 100, 200, 200})
		sdl.RenderPresent(renderer)
	}
}
