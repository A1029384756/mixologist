package mixologist

import "core:log"
import "core:slice"
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
list_string_modify :: proc(
	arr: ^[dynamic]string,
	ls: ListString,
	owned: bool,
	loc := #caller_location,
) {
	log.debugf("modifying list string by: %v", loc)
	switch ls.kind {
	case .Add:
		if owned {
			append(arr, ls.val)
		} else {
			append(arr, strings.clone(ls.val))
		}
	case .Remove:
		idx, found := slice.linear_search(arr[:], ls.val)
		if found {
			delete(arr[idx])
			ordered_remove(arr, idx)
		}
		if owned {
			delete(ls.val)
		}
	case .Update:
		prev := ls.mod.prev
		curr := ls.mod.curr
		defer if owned do delete(prev)
		idx, found := slice.linear_search(arr[:], prev)
		if found {
			delete(arr[idx])
			if owned {
				arr[idx] = curr
			} else {
				arr[idx] = strings.clone(curr)
			}
		} else {
			log.warnf("could not find list item %s, still inserting %s", prev, curr)
			if owned {
				append(arr, curr)
			} else {
				append(arr, strings.clone(curr))
			}
		}
	}
}
