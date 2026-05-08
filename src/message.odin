package mixologist

import "core:sync/chan"

Message :: struct {
	kind:       MessageKind,
	using data: struct {
		volume:   Volume,
		list:     ListString,
		settings: Settings,
	},
	refcount:   int,
}
MessageKind :: enum {
	Wake,
	Rule,
	Volume,
	Program,
	Settings,
}

MessageChan :: chan.Chan(Message)

Volume :: struct {
	kind: enum {
		Add,
		Set,
		Get,
	},
	val:  f32,
}
ListString :: struct {
	kind:       enum {
		Add,
		Remove,
		Update,
	},
	using data: struct {
		val: string,
		mod: struct {
			prev, curr: string,
		},
	},
}
