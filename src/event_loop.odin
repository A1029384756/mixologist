package mixologist

import "base:intrinsics"
import "core:sys/linux"

Loop :: struct($T: typeid) where intrinsics.type_is_enum(T) && size_of(T) == size_of(int) {
	fd:           linux.Fd,
	event_count:  int,
	event_cursor: int,
	event_buf:    [128]linux.EPoll_Event,
}

LoopOps :: bit_set[enum {
	Read,
	Write,
}]

LoopRegistration :: struct(
	$T: typeid
) where intrinsics.type_is_enum(T) &&
	size_of(T) == size_of(int) {
	id:     T,
	ops:    LoopOps,
	handle: linux.Fd,
}

loop_init :: proc(loop: ^Loop($T)) -> bool {
	fd, err := linux.epoll_create1({})
	if err != nil {return false}
	loop.fd = fd
	return true
}

loop_register :: proc(loop: ^Loop($T), reg: LoopRegistration(T)) -> bool {
	event_new :: proc(id: $T, ops: LoopOps) -> linux.EPoll_Event {
		events := linux.EPoll_Event_Set{.HUP}
		if .Read in ops {events += {.IN}}
		if .Write in ops {events += {.OUT}}
		return linux.EPoll_Event{events = events, data = {ptr = transmute(rawptr)id}}
	}

	event := event_new(reg.id, reg.ops)
	err := linux.epoll_ctl(loop.fd, .ADD, reg.handle, &event)
	return err == nil
}

loop_poll :: proc(loop: ^Loop($T), timeout: int) -> (T, bool) {
	if loop.event_cursor >= loop.event_count {
		num_events, errno := linux.epoll_wait(
			loop.fd,
			raw_data(loop.event_buf[:]),
			len(loop.event_buf),
			i32(timeout),
		)
		loop.event_count = int(num_events)
		loop.event_cursor = 0

		if errno != nil {return {}, false}
		if num_events == 0 {return {}, false}
	}
	for {
		event := loop.event_buf[loop.event_cursor]
		loop.event_cursor += 1
		id := transmute(T)event.data.ptr
		return id, true
	}
}
