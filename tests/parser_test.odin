package sse_tests

import sse ".."
import "core:mem"
import "core:testing"

// The first group follows the examples in WHATWG HTML section 9.2.4 and 9.2.6.

@(test)
test_spec_stock_example_joins_data_lines :: proc(t: ^testing.T) {
	expect_parse(t, "data: YHOO\ndata: +2\ndata: 10\n\n", {{"message", "YHOO\n+2\n10", ""}})
}

@(test)
test_spec_comment_and_id_example :: proc(t: ^testing.T) {
	input := ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n"
	expect_parse(t, input, {{"message", "first event", "1"}, {"message", "second event", ""}, {"message", " third event", ""}})
}

@(test)
test_spec_empty_data_example :: proc(t: ^testing.T) {
	// Two events: "" and "\n". The final "data:" has no blank line and is dropped.
	expect_parse(t, "data\n\ndata\ndata\n\ndata:", {{"message", "", ""}, {"message", "\n", ""}})
}

@(test)
test_spec_space_after_colon_is_optional :: proc(t: ^testing.T) {
	expect_parse(t, "data:test\n\ndata: test\n\n", {{"message", "test", ""}, {"message", "test", ""}})
}

@(test)
test_only_one_leading_space_is_stripped :: proc(t: ^testing.T) {
	expect_parse(t, "data:   x\n\n", {{"message", "  x", ""}})
}

@(test)
test_tab_after_colon_is_kept :: proc(t: ^testing.T) {
	expect_parse(t, "data:\tx\n\n", {{"message", "\tx", ""}})
}

@(test)
test_event_field_sets_type :: proc(t: ^testing.T) {
	expect_parse(t, "event: add\ndata: 73857293\n\nevent: remove\ndata: 2153\n\n", {{"add", "73857293", ""}, {"remove", "2153", ""}})
}

@(test)
test_event_type_resets_after_dispatch :: proc(t: ^testing.T) {
	expect_parse(t, "event: a\ndata: 1\n\ndata: 2\n\n", {{"a", "1", ""}, {"message", "2", ""}})
}

@(test)
test_empty_event_field_means_message :: proc(t: ^testing.T) {
	expect_parse(t, "event:\ndata: x\n\n", {{"message", "x", ""}})
}

@(test)
test_later_event_field_wins :: proc(t: ^testing.T) {
	expect_parse(t, "event: a\nevent: b\ndata: x\n\n", {{"b", "x", ""}})
}

@(test)
test_block_without_data_is_not_dispatched :: proc(t: ^testing.T) {
	expect_parse(t, "event: ping\n\nid: 7\n\n", {})
}

@(test)
test_event_type_of_undispatched_block_is_cleared :: proc(t: ^testing.T) {
	expect_parse(t, "event: ping\n\ndata: x\n\n", {{"message", "x", ""}})
}

@(test)
test_id_persists_across_events :: proc(t: ^testing.T) {
	expect_parse(t, "id: 5\ndata: a\n\ndata: b\n\n", {{"message", "a", "5"}, {"message", "b", "5"}})
}

@(test)
test_id_with_null_is_ignored :: proc(t: ^testing.T) {
	expect_parse(t, "id: 1\ndata: a\n\nid: 2\x003\ndata: b\n\n", {{"message", "a", "1"}, {"message", "b", "1"}})
}

@(test)
test_id_keeps_inner_and_trailing_spaces :: proc(t: ^testing.T) {
	expect_parse(t, "id:  a b \ndata: x\n\n", {{"message", "x", " a b "}})
}

@(test)
test_last_event_id_updates_without_dispatch :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("id: 42\n\n")), nil)
	testing.expect_value(t, sse.parser_pending(&p), 0)
	testing.expect_value(t, sse.parser_last_event_id(&p), "42")
}

@(test)
test_last_event_id_waits_for_blank_line :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("id: 1\n\nid: 2\n")), nil)
	testing.expect_value(t, sse.parser_last_event_id(&p), "1")
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("\n")), nil)
	testing.expect_value(t, sse.parser_last_event_id(&p), "2")
}

@(test)
test_retry_sets_reconnection_time :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	_, has := sse.parser_retry(&p)
	testing.expect(t, !has, "no retry before the field arrives")
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("retry: 1500\n")), nil)
	ms, ok := sse.parser_retry(&p)
	testing.expect(t, ok)
	testing.expect_value(t, ms, 1500)
}

@(test)
test_retry_rejects_non_digits :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	input := "retry: 100\nretry: 12a\nretry: -5\nretry: 1.5\nretry:\nretry:  7\nretry: 99999999999999999999999\n"
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)input), nil)
	ms, ok := sse.parser_retry(&p)
	testing.expect(t, ok)
	testing.expect_value(t, ms, 100)
}

@(test)
test_retry_does_not_dispatch :: proc(t: ^testing.T) {
	expect_parse(t, "retry: 10\n\n", {})
}

@(test)
test_unknown_fields_are_ignored :: proc(t: ^testing.T) {
	expect_parse(t, "foo: bar\nDATA: loud\nData: x\ndata: ok\n\n", {{"message", "ok", ""}})
}

@(test)
test_field_without_colon_has_empty_value :: proc(t: ^testing.T) {
	expect_parse(t, "data\ndata\n\n", {{"message", "\n", ""}})
}

@(test)
test_colon_in_value_is_kept :: proc(t: ^testing.T) {
	expect_parse(t, "data: a: b:c\n\n", {{"message", "a: b:c", ""}})
}

@(test)
test_field_name_with_space_is_unknown :: proc(t: ^testing.T) {
	expect_parse(t, "data : x\n data: y\ndata: z\n\n", {{"message", "z", ""}})
}

@(test)
test_comments_are_ignored :: proc(t: ^testing.T) {
	expect_parse(t, ":\n: keep-alive\n:data: no\ndata: yes\n:\n\n", {{"message", "yes", ""}})
}

@(test)
test_crlf_line_endings :: proc(t: ^testing.T) {
	expect_parse(t, "event: e\r\ndata: a\r\ndata: b\r\n\r\n", {{"e", "a\nb", ""}})
}

@(test)
test_cr_line_endings :: proc(t: ^testing.T) {
	expect_parse(t, "data: a\rdata: b\r\r", {{"message", "a\nb", ""}})
}

@(test)
test_mixed_line_endings :: proc(t: ^testing.T) {
	expect_parse(t, "data: a\r\ndata: b\ndata: c\r\rdata: d\n\r\n", {{"message", "a\nb\nc", ""}, {"message", "d", ""}})
}

@(test)
test_lf_cr_is_two_line_endings :: proc(t: ^testing.T) {
	// LF then CR ends two lines, so the second one is blank and dispatches.
	expect_parse(t, "data: a\n\rdata: b\n\n", {{"message", "a", ""}, {"message", "b", ""}})
}

@(test)
test_leading_bom_is_skipped :: proc(t: ^testing.T) {
	expect_parse(t, "\xEF\xBB\xBFdata: x\n\n", {{"message", "x", ""}})
}

@(test)
test_only_one_bom_is_skipped :: proc(t: ^testing.T) {
	// The second BOM makes the field name "\uFEFFdata", which is unknown.
	expect_parse(t, "\xEF\xBB\xBF\xEF\xBB\xBFdata: x\n\ndata: y\n\n", {{"message", "y", ""}})
}

@(test)
test_bom_after_start_is_data :: proc(t: ^testing.T) {
	expect_parse(t, "data: \xEF\xBB\xBFx\n\n", {{"message", "\uFEFFx", ""}})
}

@(test)
test_partial_bom_prefix_is_replayed :: proc(t: ^testing.T) {
	// EF BB followed by 'd' is not a BOM. The bytes decode to U+FFFD and form an unknown field.
	expect_parse(t, "\xEF\xBBdata: x\n\ndata: y\n\n", {{"message", "y", ""}})
	expect_parse(t, "\xEFdata: x\n\n", {})
}

@(test)
test_bom_split_across_chunks :: proc(t: ^testing.T) {
	events := feed_in_chunks(t, "\xEF\xBB\xBFdata: x\n\n", 1)
	defer sse.events_destroy(events)
	expect_events(t, events, {{"message", "x", ""}})
}

@(test)
test_invalid_utf8_becomes_replacement_character :: proc(t: ^testing.T) {
	expect_parse(t, "data: a\xFFb\n\n", {{"message", "a\uFFFDb", ""}})
}

@(test)
test_truncated_utf8_is_one_replacement_character :: proc(t: ^testing.T) {
	// F0 9F 98 is the first three bytes of a four-byte sequence: one maximal subpart.
	expect_parse(t, "data: \xF0\x9F\x98!\n\n", {{"message", "\uFFFD!", ""}})
}

@(test)
test_surrogate_bytes_are_replaced :: proc(t: ^testing.T) {
	// ED A0 80 would encode U+D800. ED is a lone lead byte, A0 and 80 are stray continuations.
	expect_parse(t, "data: \xED\xA0\x80\n\n", {{"message", "\uFFFD\uFFFD\uFFFD", ""}})
}

@(test)
test_overlong_encoding_is_replaced :: proc(t: ^testing.T) {
	expect_parse(t, "data: \xC0\xAF\n\n", {{"message", "\uFFFD\uFFFD", ""}})
}

@(test)
test_valid_multibyte_text_is_kept :: proc(t: ^testing.T) {
	expect_parse(t, "event: café\ndata: 日本 🎉\n\n", {{"café", "日本 🎉", ""}})
}

@(test)
test_null_in_data_is_kept :: proc(t: ^testing.T) {
	expect_parse(t, "data: a\x00b\n\n", {{"message", "a\x00b", ""}})
}

@(test)
test_unterminated_event_is_dropped_at_end :: proc(t: ^testing.T) {
	expect_parse(t, "data: a\n\ndata: b\n", {{"message", "a", ""}})
}

@(test)
test_empty_stream_has_no_events :: proc(t: ^testing.T) {
	expect_parse(t, "", {})
	expect_parse(t, "\n\n\n", {})
}

@(test)
test_every_chunk_size_gives_same_events :: proc(t: ^testing.T) {
	input := "\xEF\xBB\xBF: hi\r\nevent: a\r\nid: 1\r\ndata: x\xF0\x9F\x8E\x89y\r\ndata\r\n\r\ndata: second\rid: 2\r\rdata: \xF0\x9F\x98\n\n"
	want := []Want{{"a", "x🎉y\n", "1"}, {"message", "second", "2"}, {"message", "\uFFFD", "2"}}
	for size in 1 ..= len(input) {
		events := feed_in_chunks(t, input, size)
		expect_events(t, events, want)
		sse.events_destroy(events)
	}
}

@(test)
test_crlf_split_between_chunks_is_one_line_ending :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: a\r")), nil)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("\ndata: b\r\n\r\n")), nil)
	ev, ok := sse.parser_next(&p)
	testing.expect(t, ok)
	testing.expect_value(t, ev.data, "a\nb")
	_, ok = sse.parser_next(&p)
	testing.expect(t, !ok, "the LF after a chunk-final CR must not end another line")
}

@(test)
test_empty_chunks_are_harmless :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, nil), nil)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: a\r")), nil)
	testing.expect_value(t, sse.parser_feed(&p, nil), nil)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("\n\n")), nil)
	testing.expect_value(t, sse.parser_pending(&p), 1)
}

@(test)
test_parser_next_iterates_in_order :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: 1\n\ndata: 2\n\ndata: 3\n\n")), nil)
	testing.expect_value(t, sse.parser_pending(&p), 3)
	seen: [dynamic]string
	defer delete(seen)
	for ev in sse.parser_next(&p) {
		append(&seen, ev.data)
		break
	}
	testing.expect_value(t, sse.parser_pending(&p), 2)
	for ev in sse.parser_next(&p) {
		testing.expect(t, ev.type == "message")
	}
	testing.expect_value(t, sse.parser_pending(&p), 0)
}

@(test)
test_reset_discards_partial_event_and_rearms_bom :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("id: 9\ndata: x\n\nevent: e\ndata: partial\nda")), nil)
	sse.parser_reset(&p)
	testing.expect_value(t, sse.parser_last_event_id(&p), "9")
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("\xEF\xBB\xBFta: fresh\n\n")), nil)

	ev, ok := sse.parser_next(&p)
	testing.expect(t, ok)
	testing.expect_value(t, ev.data, "x")
	// "ta: fresh" is an unknown field, so nothing from the partial "da" line survives.
	_, ok = sse.parser_next(&p)
	testing.expect(t, !ok, "the partial event must not be dispatched")
}

@(test)
test_reset_clears_id_buffer_for_new_stream :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("id: 3\ndata: a\n\n")), nil)
	sse.parser_reset(&p)
	// A new stream starts with an empty id buffer, so its first dispatch clears the ID.
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: b\n\n")), nil)
	testing.expect_value(t, sse.parser_last_event_id(&p), "")
}

@(test)
test_line_limit_rejects_long_line :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p, {max_line_size = 8})
	defer sse.parser_destroy(&p)

	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: ok\n\n")), nil)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: ")), nil)
	err := sse.parser_feed(&p, transmute([]byte)string("too long"))
	testing.expect_value(t, err, sse.Error(sse.Parse_Error.Line_Too_Long))
	// The error sticks until reset, and earlier events stay readable.
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("\n")), sse.Error(sse.Parse_Error.Line_Too_Long))
	ev, ok := sse.parser_next(&p)
	testing.expect(t, ok)
	testing.expect_value(t, ev.data, "ok")
	sse.parser_reset(&p)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("data: b\n\n")), nil)
}

@(test)
test_line_limit_applies_to_complete_lines :: proc(t: ^testing.T) {
	_, err := sse.parse_all("data: 123456789\n\n", {max_line_size = 8})
	testing.expect_value(t, err, sse.Error(sse.Parse_Error.Line_Too_Long))
}

@(test)
test_data_limit_rejects_large_event :: proc(t: ^testing.T) {
	events, err := sse.parse_all("data: 1234\ndata: 5\n\n", {max_data_size = 6})
	defer sse.events_destroy(events)
	testing.expect_value(t, err, nil)
	expect_events(t, events, {{"message", "1234\n5", ""}})

	_, err = sse.parse_all("data: 1234\ndata: 56\n\n", {max_data_size = 6})
	testing.expect_value(t, err, sse.Error(sse.Parse_Error.Event_Too_Large))
}

@(test)
test_event_clone_outlives_parser :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)string("event: e\nid: 1\ndata: d\n\n")), nil)
	ev, _ := sse.parser_next(&p)
	clone, err := sse.event_clone(ev)
	sse.parser_destroy(&p)
	defer sse.event_destroy(&clone)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, clone, sse.Event{type = "e", data = "d", id = "1"})
}

@(test)
test_parser_does_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	p: sse.Parser
	sse.parser_init(&p, {}, alloc)
	input := "\xEF\xBB\xBFid: 1\nevent: e\ndata: a\xFF\n\ndata: queued\n\ndata: undelivered\n\ndata: partial"
	testing.expect_value(t, sse.parser_feed(&p, transmute([]byte)input), nil)
	_, _ = sse.parser_next(&p)
	_, _ = sse.parser_next(&p)
	sse.parser_destroy(&p)
	expect_no_leaks(t, &track)

	events, err := sse.parse_all(input, {}, alloc)
	testing.expect_value(t, err, nil)
	sse.events_destroy(events, alloc)
	expect_no_leaks(t, &track)
}

@(test)
test_parse_all_survives_every_allocation_failure :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	input := "id: 1\nevent: e\ndata: a\xFF\ndata: b\n\ndata: c\n\n"
	succeeded := false
	for budget in 0 ..< 64 {
		limited := Limited_Allocator{backing = mem.tracking_allocator(&track), remaining = budget}
		events, err := sse.parse_all(input, {}, limited_allocator(&limited))
		if err == nil {
			expect_events(t, events, {{"e", "a\uFFFD\nb", "1"}, {"message", "c", "1"}})
			sse.events_destroy(events, limited_allocator(&limited))
			succeeded = true
			expect_no_leaks(t, &track)
			break
		}
		testing.expect_value(t, err, sse.Error(mem.Allocator_Error.Out_Of_Memory))
		expect_no_leaks(t, &track)
	}
	testing.expect(t, succeeded, "parse_all never succeeded within the allocation budget")
}

@(test)
test_feed_reports_allocator_error :: proc(t: ^testing.T) {
	limited := Limited_Allocator{backing = context.allocator, remaining = 0}
	p: sse.Parser
	sse.parser_init(&p, {}, limited_allocator(&limited))
	defer sse.parser_destroy(&p)

	err := sse.parser_feed(&p, transmute([]byte)string("data: x\n\n"))
	testing.expect_value(t, err, sse.Error(mem.Allocator_Error.Out_Of_Memory))
}

// A consumer that always leaves one event queued must not make the queue grow without bound.
@(test)
test_queue_stays_bounded_with_backlog :: proc(t: ^testing.T) {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)

	frame := transmute([]byte)string("data: a\n\n")
	testing.expect_value(t, sse.parser_feed(&p, frame), nil)
	for _ in 0 ..< 1000 {
		testing.expect_value(t, sse.parser_feed(&p, frame), nil)
		ev, ok := sse.parser_next(&p)
		testing.expect(t, ok)
		testing.expect_value(t, ev.data, "a")
	}
	testing.expect_value(t, sse.parser_pending(&p), 1)
	testing.expectf(t, len(p.queue) <= 4, "queue holds %d slots for 1 pending event", len(p.queue))
}
