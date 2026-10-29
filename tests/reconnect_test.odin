package sse_tests

import sse ".."
import "core:mem"
import "core:testing"
import "core:time"

@(test)
test_reconnect_defaults_to_three_seconds :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r)
	defer sse.reconnect_destroy(&r)

	for _ in 0 ..< 5 {
		d, ok := sse.reconnect_next_delay(&r)
		testing.expect(t, ok)
		testing.expect_value(t, d, sse.DEFAULT_RECONNECT_DELAY)
	}
	testing.expect_value(t, sse.reconnect_attempts(&r), 5)
}

@(test)
test_reconnect_uses_initial_delay_then_retry :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {initial_delay = 250 * time.Millisecond})
	defer sse.reconnect_destroy(&r)

	d, _ := sse.reconnect_next_delay(&r)
	testing.expect_value(t, d, 250 * time.Millisecond)
	sse.reconnect_set_retry(&r, 1200)
	d, _ = sse.reconnect_next_delay(&r)
	testing.expect_value(t, d, 1200 * time.Millisecond)
}

@(test)
test_reconnect_exponential_backoff_with_cap :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {initial_delay = time.Second, multiplier = 2, max_delay = 5 * time.Second})
	defer sse.reconnect_destroy(&r)

	want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 5 * time.Second, 5 * time.Second}
	for w in want {
		d, ok := sse.reconnect_next_delay(&r)
		testing.expect(t, ok)
		testing.expect_value(t, d, w)
	}
}

@(test)
test_reconnect_connected_resets_backoff :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {initial_delay = time.Second, multiplier = 3})
	defer sse.reconnect_destroy(&r)

	_, _ = sse.reconnect_next_delay(&r)
	_, _ = sse.reconnect_next_delay(&r)
	sse.reconnect_connected(&r)
	testing.expect_value(t, sse.reconnect_attempts(&r), 0)
	d, _ := sse.reconnect_next_delay(&r)
	testing.expect_value(t, d, time.Second)
}

@(test)
test_reconnect_gives_up_after_max_attempts :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {max_attempts = 2})
	defer sse.reconnect_destroy(&r)

	_, ok1 := sse.reconnect_next_delay(&r)
	_, ok2 := sse.reconnect_next_delay(&r)
	_, ok3 := sse.reconnect_next_delay(&r)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, !ok3, "third attempt must be refused")
}

@(test)
test_reconnect_jitter_stays_in_bounds :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {initial_delay = time.Second, jitter = 0.5})
	defer sse.reconnect_destroy(&r)

	for _ in 0 ..< 200 {
		d, _ := sse.reconnect_next_delay(&r)
		testing.expectf(t, d >= 500 * time.Millisecond && d <= time.Second, "delay %v out of bounds", d)
	}
}

@(test)
test_reconnect_huge_values_do_not_overflow :: proc(t: ^testing.T) {
	r: sse.Reconnect
	sse.reconnect_init(&r, {multiplier = 10})
	defer sse.reconnect_destroy(&r)

	sse.reconnect_set_retry(&r, max(u64))
	for _ in 0 ..< 40 {
		d, ok := sse.reconnect_next_delay(&r)
		testing.expect(t, ok)
		testing.expectf(t, d > 0, "delay %v must stay positive", d)
	}
}

@(test)
test_reconnect_sync_copies_parser_state :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	p: sse.Parser
	sse.parser_init(&p, {}, alloc)
	r: sse.Reconnect
	sse.reconnect_init(&r, {}, alloc)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("retry: 700\nid: abc\ndata: x\n\n")), nil)
	testing.expect_value(t, sse.reconnect_sync(&r, &p), nil)
	testing.expect_value(t, sse.reconnect_last_event_id(&r), "abc")
	d, _ := sse.reconnect_next_delay(&r)
	testing.expect_value(t, d, 700 * time.Millisecond)

	// The stored ID is a copy, so it survives the parser.
	sse.parser_destroy(&p)
	testing.expect_value(t, sse.reconnect_last_event_id(&r), "abc")
	testing.expect_value(t, sse.reconnect_set_last_event_id(&r, ""), nil)
	testing.expect_value(t, sse.reconnect_last_event_id(&r), "")
	sse.reconnect_destroy(&r)
	expect_no_leaks(t, &track)
}

@(test)
test_reconnect_keeps_old_id_on_allocator_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	limited := Limited_Allocator{backing = mem.tracking_allocator(&track), remaining = 1}
	r: sse.Reconnect
	sse.reconnect_init(&r, {}, limited_allocator(&limited))
	testing.expect_value(t, sse.reconnect_set_last_event_id(&r, "first"), nil)
	err := sse.reconnect_set_last_event_id(&r, "second")
	testing.expect_value(t, err, sse.Error(mem.Allocator_Error.Out_Of_Memory))
	testing.expect_value(t, sse.reconnect_last_event_id(&r), "first")
	sse.reconnect_destroy(&r)
	expect_no_leaks(t, &track)
}

@(test)
test_check_response_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, sse.check_response(200, "text/event-stream"), sse.Response_Verdict.Open)
	testing.expect_value(t, sse.check_response(200, "text/event-stream; charset=utf-8"), sse.Response_Verdict.Open)
	testing.expect_value(t, sse.check_response(204, "text/event-stream"), sse.Response_Verdict.Fail)
	testing.expect_value(t, sse.check_response(500, "text/event-stream"), sse.Response_Verdict.Fail)
	testing.expect_value(t, sse.check_response(200, "text/plain"), sse.Response_Verdict.Fail)
	testing.expect_value(t, sse.check_response(200, ""), sse.Response_Verdict.Fail)
}

@(test)
test_is_event_stream_parsing :: proc(t: ^testing.T) {
	testing.expect(t, sse.is_event_stream("Text/Event-Stream"))
	testing.expect(t, sse.is_event_stream("  text/event-stream ;charset=UTF-8"))
	testing.expect(t, !sse.is_event_stream("text/event-streams"))
	testing.expect(t, !sse.is_event_stream("text/event"))
	// Only ASCII letters fold: U+017F LATIN SMALL LETTER LONG S is not an "s".
	testing.expect(t, !sse.is_event_stream("text/event-ſtream"))
}
