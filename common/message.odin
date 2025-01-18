package common

Message :: union {
	Volume,
	Program,
}

Volume :: struct {
	act: enum {
		Set,
		Shift,
		Get,
		Subscribe,
	},
	val: f32,
}

Program :: struct {
	act: enum {
		Add,
		Remove,
		Subscribe,
	},
	val: string,
}
