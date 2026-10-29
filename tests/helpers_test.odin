// Package sse_tests holds the unit tests for sse. Run them with `odin test tests`.
package sse_tests

import sse ".."
import "core:mem"
import "core:testing"

// expect_no_leaks fails the test when the tracking allocator still holds allocations.
expect_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	testing.expectf(t, len(track.allocation_map) == 0, "leaked %d allocation(s)", len(track.allocation_map), loc = loc)
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad free(s)", len(track.bad_free_array), loc = loc)
}

// Limited_Allocator serves `remaining` allocations from `backing`, then fails every later one.
Limited_Allocator :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

limited_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	l := (^Limited_Allocator)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if l.remaining <= 0 {
			return nil, .Out_Of_Memory
		}
		l.remaining -= 1
	case .Free, .Free_All, .Query_Features, .Query_Info:
	}
	return l.backing.procedure(l.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// limited_allocator wraps `l` as an Allocator.
limited_allocator :: proc(l: ^Limited_Allocator) -> mem.Allocator {
	return {procedure = limited_allocator_proc, data = l}
}

// Want is the expected shape of one dispatched event.
Want :: struct {
	type: string,
	data: string,
	id:   string,
}

// expect_events checks that `got` matches `want` element by element.
expect_events :: proc(t: ^testing.T, got: []sse.Event, want: []Want, loc := #caller_location) {
	if !testing.expectf(t, len(got) == len(want), "got %d event(s), want %d: %v", len(got), len(want), got, loc = loc) {
		return
	}
	for w, i in want {
		g := got[i]
		testing.expectf(t, g.type == w.type, "event %d type = %q, want %q", i, g.type, w.type, loc = loc)
		testing.expectf(t, g.data == w.data, "event %d data = %q, want %q", i, g.data, w.data, loc = loc)
		testing.expectf(t, g.id == w.id, "event %d id = %q, want %q", i, g.id, w.id, loc = loc)
	}
}

// expect_parse runs parse_all on `input` and compares the result with `want`.
expect_parse :: proc(t: ^testing.T, input: string, want: []Want, loc := #caller_location) {
	events, err := sse.parse_all(input)
	defer sse.events_destroy(events)
	testing.expectf(t, err == nil, "parse_all(%q) failed: %v", input, err, loc = loc)
	expect_events(t, events, want, loc)
}

/*
feed_in_chunks feeds `input` to a fresh parser `size` bytes at a time, drains
every event as it appears and returns owned clones.
*/
feed_in_chunks :: proc(t: ^testing.T, input: string, size: int, allocator := context.allocator) -> []sse.Event {
	p: sse.Parser
	sse.parser_init(&p, {}, allocator)
	defer sse.parser_destroy(&p)

	out := make([dynamic]sse.Event, allocator)
	bytes := transmute([]byte)input
	for start := 0; start < len(bytes); start += size {
		end := min(start + size, len(bytes))
		err := sse.parser_feed(&p, bytes[start:end])
		testing.expectf(t, err == nil, "feed failed: %v", err)
		for ev in sse.parser_next(&p) {
			clone, cerr := sse.event_clone(ev, allocator)
			testing.expect_value(t, cerr, nil)
			append(&out, clone)
		}
	}
	return out[:]
}
