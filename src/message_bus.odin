package mixologist

import "base:runtime"
import "core:log"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sync/chan"

Message :: struct {
	sender:     Component,
	topic:      Topic,
	using data: struct #raw_union {
		volume:   Volume,
		list:     ListString,
		settings: Settings,
	},
	refcount:   int,
}
message_unref :: proc(msg: ^Message) {
	if sync.atomic_sub_explicit(&msg.refcount, 1, .Relaxed) == 1 {
		sync.atomic_thread_fence(.Acquire)
		message_destroy(msg)
		free(msg, context.allocator)
	}
}
message_destroy :: proc(msg: ^Message) {
	_liststring_destroy :: proc(ls: ListString) {
		switch ls.kind {
		case .Add, .Remove:
			if len(ls.val) > 0 do delete(ls.val)
		case .Update:
			if len(ls.mod.curr) > 0 do delete(ls.mod.curr)
			if len(ls.mod.prev) > 0 do delete(ls.mod.prev)
		}
	}
	#partial switch msg.topic {
	case .Rule, .Program:
		_liststring_destroy(ListString(msg.list))
	}
}

Component :: enum {
	None,
	Gui,
	Ipc,
	Daemon,
	FileManager,
	GlobalShortcuts,
}
Topic :: enum {
	Quit,
	Wake,
	Rule,
	Volume,
	Program,
	Settings,
}
Topics :: bit_set[Topic]
AllTopics :: Topics{.Quit, .Wake, .Rule, .Volume, .Program, .Settings}

Volume :: struct {
	kind: enum {
		Add,
		Set,
		Get,
	},
	data: f32,
}
ListString :: struct {
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
Subscriber :: struct {
	messages: chan.Chan(^Message),
	topics:   Topics,
	id:       Component,
}

SUBSCRIBER_CHAN_CAP :: 128
subscriber_init :: proc(s: ^Subscriber, c: Component, t: Topics, allocator := context.allocator) {
	s.id = c
	s.topics = t
	err: runtime.Allocator_Error
	s.messages, err = chan.create(chan.Chan(^Message), SUBSCRIBER_CHAN_CAP, allocator)
	if err != nil {
		log.panic(err)
	}
}
subscriber_destroy :: proc(s: ^Subscriber) {
	chan.close(s.messages)
	chan.destroy(s.messages)
}
subscriber_poll :: proc(s: ^Subscriber) -> (msg: ^Message, ok: bool) {
	return chan.recv(s.messages)
}
subscriber_try_poll :: proc(s: ^Subscriber) -> (msg: ^Message, ok: bool) {
	return chan.try_recv(s.messages)
}
subscriber_flush :: proc(s: ^Subscriber) {
	for msg in chan.try_recv(s.messages) {
		message_unref(msg)
	}
}

bus: Bus
Bus :: struct {
	subs: [dynamic]Subscriber,
	mu:   sync.Mutex,
}
bus_init :: proc() {
	bus.subs = make([dynamic]Subscriber, 0, 8)
}
bus_deinit :: proc() {
	delete(bus.subs)
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
bus_publish :: proc(
	b: ^Bus,
	_msg: Message,
	allocator := context.allocator,
	loc := #caller_location,
) {
	log.debugf("publishing to bus from: %v", loc)
	sync.lock(&b.mu)
	snapshot := slice.clone(b.subs[:], context.temp_allocator)
	sync.unlock(&b.mu)

	eligible := 0
	for s in snapshot {
		if _msg.topic not_in s.topics do continue
		if s.id == _msg.sender do continue
		eligible += 1
	}
	if eligible == 0 do return

	// todo slab allocate and free list
	msg := new(Message, allocator)
	msg^ = _msg
	#partial switch msg.topic {
	case .Rule, .Program:
		switch msg.list.kind {
		case .Add, .Remove:
			if msg.list.val != "" {
				msg.list.val = strings.clone(msg.list.val)
			}
		case .Update:
			if msg.list.mod.prev != "" {
				msg.list.mod.prev = strings.clone(msg.list.mod.prev)
			}
			if msg.list.mod.curr != "" {
				msg.list.mod.curr = strings.clone(msg.list.mod.curr)
			}
		}
	}

	for s in snapshot {
		if msg.topic not_in s.topics do continue
		if s.id == msg.sender do continue
		sync.atomic_add_explicit(&msg.refcount, 1, .Relaxed)
		chan.send(s.messages, msg)
	}
}
