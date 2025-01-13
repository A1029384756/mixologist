package common

Message :: union {
	Volume,
	Program,
}

Volume :: struct {
	act: enum {
		Set,
		Shift,
	},
	val: f32,
}

Program :: struct {
	act: enum {
		Add,
		Remove,
	},
	val: string,
}
