/*
Package sse implements Server-Sent Events as defined by the WHATWG HTML
Living Standard, section 9.2 "Server-sent events".

It has three parts:

- Parser: an incremental, allocation-aware parser for `text/event-stream`
  bodies. Feed it bytes as they arrive, in chunks of any size, and pull the
  dispatched events. It follows the spec's parsing rules exactly: one leading
  byte order mark is skipped, lines end in CR, LF or CRLF, invalid UTF-8 is
  replaced with U+FFFD, `data` lines join with LF, `id` values that contain
  NULL are ignored, and `retry` only accepts ASCII digits.
- Encoder: `write_message`, `encode_message`, `write_comment` and friends
  produce well-formed frames for servers, splitting multi-line data and
  rejecting event names and ids that would break the framing.
- Reconnect: a small state machine for clients that tracks the last event
  ID, the server's `retry` value and an optional exponential backoff.

Example:
	import sse "shared:sse"

	main :: proc() {
		p: sse.Parser
		sse.parser_init(&p)
		defer sse.parser_destroy(&p)

		_ = sse.parser_feed(&p, transmute([]byte)string("data: hello\n\n"))
		for ev in sse.parser_next(&p) {
			// ev.type == "message", ev.data == "hello"
		}
	}
*/
package sse

import "base:runtime"
import "core:io"
import "core:strings"

// MIME_TYPE is the media type of an event stream response.
MIME_TYPE :: "text/event-stream"

// LAST_EVENT_ID_HEADER is the request header a reconnecting client sends with the last event ID.
LAST_EVENT_ID_HEADER :: "Last-Event-ID"

// DEFAULT_EVENT_TYPE is the event type used when a block has no `event` field.
DEFAULT_EVENT_TYPE :: "message"

// Parse_Error lists the ways a Parser can reject a stream.
Parse_Error :: enum {
	None,
	// A single line grew past `Parser_Options.max_line_size` bytes.
	Line_Too_Long,
	// The data of one event grew past `Parser_Options.max_data_size` bytes.
	Event_Too_Large,
}

// Encode_Error lists the ways the encoder can refuse a message.
Encode_Error :: enum {
	None,
	// The event name contains CR or LF, which would end the field early.
	Invalid_Event_Type,
	// The id contains CR, LF or NULL. Clients ignore ids that contain NULL.
	Invalid_Id,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a variant, for example
`err == sse.Error(sse.Parse_Error.Line_Too_Long)`, or use a type switch.
*/
Error :: union #shared_nil {
	Parse_Error,
	Encode_Error,
	io.Error,
	runtime.Allocator_Error,
}

/*
Event is one dispatched event.

- type: the event type; `DEFAULT_EVENT_TYPE` when the block had no `event` field.
- data: the joined `data` lines, without the final LF.
- id: the last event ID at the time of dispatch, which may come from an earlier block.

An Event returned by parser_next borrows the parser's memory. Call event_clone
to keep it longer.
*/
Event :: struct {
	type: string,
	data: string,
	id:   string,
}

/*
event_clone copies every string of `ev`.

Returns:
- clone: an Event owned by the caller; free it with `event_destroy(&clone, allocator)`.
- err: an allocator error. On error nothing is left allocated.
*/
event_clone :: proc(ev: Event, allocator := context.allocator) -> (clone: Event, err: Error) {
	clone.type = strings.clone(ev.type, allocator) or_return
	defer if err != nil {
		delete(clone.type, allocator)
		clone = {}
	}
	clone.data = strings.clone(ev.data, allocator) or_return
	defer if err != nil {
		delete(clone.data, allocator)
	}
	clone.id = strings.clone(ev.id, allocator) or_return
	return
}

// event_destroy frees an Event made by event_clone or parse_all and zeroes it.
event_destroy :: proc(ev: ^Event, allocator := context.allocator) {
	delete(ev.type, allocator)
	delete(ev.data, allocator)
	delete(ev.id, allocator)
	ev^ = {}
}

// events_destroy frees every Event in `events`, then the slice itself.
events_destroy :: proc(events: []Event, allocator := context.allocator) {
	for &ev in events {
		event_destroy(&ev, allocator)
	}
	delete(events, allocator)
}
