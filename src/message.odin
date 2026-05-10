package mixologist

import "core:strings"
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
	Toggle,
	Volume,
	Program,
	Settings,
}

MessageChan :: chan.Chan(Message)
message_chan_flush :: proc(msgchan: MessageChan) {
	for msg in chan.try_recv(msgchan) {
		#partial switch msg.kind {
		case .Rule, .Program:
			list_string_destroy(msg.list)
		}
	}
}

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
list_string_clone :: proc(ls: ListString) -> ListString {
	res := ls
	switch ls.kind {
	case .Add, .Remove:
		res.val = strings.clone(res.val)
	case .Update:
		res.mod.prev = strings.clone(res.mod.prev)
		res.mod.curr = strings.clone(res.mod.curr)
	}
	return res
}
list_string_destroy :: proc(ls: ListString) {
	switch ls.kind {
	case .Add, .Remove:
		delete(ls.val)
	case .Update:
		delete(ls.mod.curr)
		delete(ls.mod.prev)
	}
}
