package mixologist

import "base:runtime"
import "core:log"
import "core:slice"
import "core:sync"
import "core:sync/chan"

bus: Bus

Message :: struct {
	sender:     int,
	topic:      Topic,
	using data: struct #raw_union {
		rule:    Rule,
		volume:  Volume,
		program: Program,
	},
}
message_destroy :: proc(msg: Message) {
	_liststring_destroy :: proc(ls: _ListString) {
		if len(ls.val) > 0 do delete(ls.val)
		if len(ls.mod.curr) > 0 do delete(ls.mod.curr)
		if len(ls.mod.prev) > 0 do delete(ls.mod.prev)
	}
	#partial switch msg.topic {
	case .Rule, .Program:
		_liststring_destroy(_ListString(msg.rule))
	}
}

Topic :: enum {
	Quit,
	Wake,
	Rule,
	Volume,
	Program,
}
Topics :: bit_set[Topic]
AllTopics :: Topics{.Quit, .Wake, .Rule, .Volume, .Program}

Volume :: struct {
	kind: enum {
		Add,
		Set,
		Get,
	},
	data: f32,
}

_ListString :: struct {
	kind:       enum {
		Add,
		Remove,
		Update,
	},
	using data: struct #raw_union {
		val: string,
		mod: struct {
			prev, curr: string,
		},
	},
}
Program :: distinct _ListString
Rule :: distinct _ListString

Subscriber :: struct {
	messages: chan.Chan(Message),
	topics:   Topics,
	id:       int,
}
Bus :: struct {
	subs: [dynamic]Subscriber,
	mu:   sync.Mutex,
}

SUBSCRIBER_CHAN_CAP :: 128
subscriber_init :: proc(s: ^Subscriber, t: Topics, allocator := context.allocator) {
	s.topics = t
	err: runtime.Allocator_Error
	s.messages, err = chan.create(chan.Chan(Message), SUBSCRIBER_CHAN_CAP, allocator)
	if err != nil {
		log.panic(err)
	}
}
subscriber_destroy :: proc(s: ^Subscriber) {
	chan.close(s.messages)
	chan.destroy(s.messages)
}
subscriber_poll :: proc(s: ^Subscriber) -> (msg: Message, ok: bool) {
	return chan.recv(s.messages)
}
subscriber_flush :: proc(s: ^Subscriber) {
	for msg in chan.try_recv(s.messages) {
		message_destroy(msg)
	}
}

bus_subscribe :: proc(b: ^Bus, s: Subscriber) {
	s := s
	sync.guard(&b.mu)
	context.user_ptr = &s
	idx, already_subscribed := slice.linear_search_proc(b.subs[:], proc(sub: Subscriber) -> bool {
		s := cast(^Subscriber)context.user_ptr
		return s.messages == sub.messages
	})
	if already_subscribed {
		b.subs[idx] = s
	} else {
		append(&b.subs, s)
	}
}
bus_publish :: proc(b: ^Bus, msg: Message, allocator := context.allocator) {
	sync.lock(&b.mu)
	snapshot := slice.clone(b.subs[:], context.temp_allocator)
	sync.unlock(&b.mu)

	for s in snapshot {
		if msg.topic not_in s.topics do continue
		if s.id == msg.sender do continue
		// todo, memory management. clone strings
		chan.send(s.messages, msg)
	}
}
