package sse_tests

import sse ".."
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"

// expect_encoded checks that encode_message turns `msg` into exactly `want`.
expect_encoded :: proc(t: ^testing.T, msg: sse.Message, want: string, loc := #caller_location) {
	text, err := sse.encode_message(msg)
	defer delete(text)
	testing.expectf(t, err == nil, "encode_message failed: %v", err, loc = loc)
	testing.expectf(t, text == want, "encode_message = %q, want %q", text, want, loc = loc)
}

@(test)
test_encode_data_only :: proc(t: ^testing.T) {
	expect_encoded(t, {data = "hello"}, "data: hello\n\n")
}

@(test)
test_encode_all_fields :: proc(t: ^testing.T) {
	expect_encoded(t, {type = "update", id = "42", retry = 5000, data = "x"}, "event: update\nid: 42\nretry: 5000\ndata: x\n\n")
}

@(test)
test_encode_splits_every_line_ending :: proc(t: ^testing.T) {
	expect_encoded(t, {data = "a\nb\r\nc\rd"}, "data: a\ndata: b\ndata: c\ndata: d\n\n")
}

@(test)
test_encode_empty_data_still_dispatches :: proc(t: ^testing.T) {
	expect_encoded(t, {}, "data:\n\n")
	expect_encoded(t, {data = "\n"}, "data:\ndata:\n\n")
}

@(test)
test_encode_keeps_leading_space :: proc(t: ^testing.T) {
	// The parser strips one space after the colon, so the encoder adds one.
	expect_encoded(t, {data = " x"}, "data:  x\n\n")
}

@(test)
test_encode_rejects_newline_in_type :: proc(t: ^testing.T) {
	text, err := sse.encode_message({type = "a\nb", data = "x"})
	testing.expect_value(t, text, "")
	testing.expect_value(t, err, sse.Error(sse.Encode_Error.Invalid_Event_Type))
}

@(test)
test_encode_rejects_bad_ids :: proc(t: ^testing.T) {
	for id in ([]string{"a\nb", "a\rb", "a\x00b"}) {
		err := sse.validate_message({id = id})
		testing.expect_value(t, err, sse.Error(sse.Encode_Error.Invalid_Id))
	}
	testing.expect_value(t, sse.validate_message({type = "ok", id = "ok", data = "\n\r"}), nil)
}

@(test)
test_write_message_writes_nothing_when_invalid :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	err := sse.write_message(strings.to_writer(&b), {id = "\n", data = "x"})
	testing.expect_value(t, err, sse.Error(sse.Encode_Error.Invalid_Id))
	testing.expect_value(t, strings.builder_len(b), 0)
}

@(test)
test_write_comment_lines :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)
	testing.expect_value(t, sse.write_comment(w, ""), nil)
	testing.expect_value(t, sse.write_comment(w, "ping"), nil)
	testing.expect_value(t, sse.write_comment(w, "a\r\nb"), nil)
	testing.expect_value(t, strings.to_string(b), ":\n: ping\n: a\n: b\n")
}

@(test)
test_write_id_and_retry :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)
	testing.expect_value(t, sse.write_retry(w, 0), nil)
	testing.expect_value(t, sse.write_id(w, "7"), nil)
	testing.expect_value(t, sse.write_id(w, ""), nil)
	testing.expect_value(t, sse.write_id(w, "x\ny"), sse.Error(sse.Encode_Error.Invalid_Id))
	testing.expect_value(t, strings.to_string(b), "retry: 0\nid: 7\n\nid:\n\n")
}

@(test)
test_write_id_updates_parser_without_event :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, sse.write_id(strings.to_writer(&b), "resume-1"), nil)

	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)
	testing.expect_value(t, sse.parser_feed(&p, b.buf[:]), nil)
	testing.expect_value(t, sse.parser_pending(&p), 0)
	testing.expect_value(t, sse.parser_last_event_id(&p), "resume-1")
}

@(test)
test_encode_then_parse_round_trips :: proc(t: ^testing.T) {
	messages := []sse.Message {
		{data = "plain"},
		{type = "multi", id = "1", data = "line one\nline two\r\nline three"},
		{data = ""},
		{data = "  indented\n\ttabbed"},
		{type = "unicode", id = "é", data = "日本 🎉"},
		{data = "trailing newline\n"},
	}
	want := []Want {
		{"message", "plain", ""},
		{"multi", "line one\nline two\nline three", "1"},
		{"message", "", "1"},
		{"message", "  indented\n\ttabbed", "1"},
		{"unicode", "日本 🎉", "é"},
		{"message", "trailing newline\n", "é"},
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for msg in messages {
		testing.expect_value(t, sse.write_message(strings.to_writer(&b), msg), nil)
	}
	expect_parse(t, strings.to_string(b), want)
}

// failing_writer rejects every write, to check that io errors propagate.
failing_writer :: proc() -> io.Writer {
	fail :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		if mode == .Query {
			return io.query_utility({.Write, .Query})
		}
		return 0, .Unexpected_EOF
	}
	return io.Stream{procedure = fail}
}

@(test)
test_write_message_reports_io_error :: proc(t: ^testing.T) {
	err := sse.write_message(failing_writer(), {data = "x"})
	testing.expect_value(t, err, sse.Error(io.Error.Unexpected_EOF))
	testing.expect_value(t, sse.write_comment(failing_writer(), "x"), sse.Error(io.Error.Unexpected_EOF))
}

@(test)
test_encode_message_does_not_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	text, err := sse.encode_message({type = "e", data = "a\nb"}, alloc)
	testing.expect_value(t, err, nil)
	delete(text, alloc)
	_, err = sse.encode_message({type = "\n"}, alloc)
	testing.expect_value(t, err, sse.Error(sse.Encode_Error.Invalid_Event_Type))
	expect_no_leaks(t, &track)
}

@(test)
test_encode_message_reports_allocator_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	big, _ := strings.repeat("line\n", 100)
	defer delete(big)
	for budget in 0 ..< 3 {
		limited := Limited_Allocator{backing = mem.tracking_allocator(&track), remaining = budget}
		text, err := sse.encode_message({data = big}, limited_allocator(&limited))
		if err == nil {
			delete(text, limited_allocator(&limited))
			continue
		}
		testing.expect_value(t, err, sse.Error(mem.Allocator_Error.Out_Of_Memory))
		expect_no_leaks(t, &track)
	}
	expect_no_leaks(t, &track)
}
