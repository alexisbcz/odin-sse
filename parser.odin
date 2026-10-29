package sse

import "base:runtime"
import "core:unicode/utf8"

/*
Parser_Options limits how much memory a Parser may hold for one stream.
A zero value means no limit.

- max_line_size: the longest line, in bytes, before parser_feed returns `.Line_Too_Long`.
- max_data_size: the largest data buffer of one event before parser_feed returns `.Event_Too_Large`.
*/
Parser_Options :: struct {
	max_line_size: int,
	max_data_size: int,
}

/*
Parser is an incremental `text/event-stream` parser.

Create one with parser_init, push bytes with parser_feed, pull events with
parser_next and release it with parser_destroy. Feed chunks of any size: a
chunk may end in the middle of a line, a UTF-8 sequence, a CRLF pair or the
byte order mark.

A Parser is safe to use from one thread at a time.
*/
Parser :: struct {
	allocator:     runtime.Allocator,
	options:       Parser_Options,
	// Bytes of a line that has not ended yet.
	line:          [dynamic]byte,
	// Replacement output when a line holds invalid UTF-8.
	scratch:       [dynamic]byte,
	data:          [dynamic]byte,
	event_type:    [dynamic]byte,
	id_buffer:     [dynamic]byte,
	last_event_id: [dynamic]byte,
	queue:         [dynamic]Event,
	head:          int,
	current:       Event,
	has_current:   bool,
	retry_ms:      u64,
	has_retry:     bool,
	// How many bytes of a possible leading byte order mark were seen.
	bom_seen:      int,
	started:       bool,
	pending_cr:    bool,
	err:           Error,
}

@(private = "file", rodata)
BOM := [3]byte{0xEF, 0xBB, 0xBF}

/*
parser_init prepares `p` for a new stream. It allocates nothing until bytes
arrive. Every later allocation uses `allocator`. Call parser_destroy when done.
*/
parser_init :: proc(p: ^Parser, options := Parser_Options{}, allocator := context.allocator) {
	p^ = {}
	p.allocator = allocator
	p.options = options
	p.line.allocator = allocator
	p.scratch.allocator = allocator
	p.data.allocator = allocator
	p.event_type.allocator = allocator
	p.id_buffer.allocator = allocator
	p.last_event_id.allocator = allocator
	p.queue.allocator = allocator
}

// parser_destroy frees every buffer and every undelivered event. The parser is zeroed.
parser_destroy :: proc(p: ^Parser) {
	release_current(p)
	for &ev in p.queue[p.head:] {
		event_destroy(&ev, p.allocator)
	}
	delete(p.queue)
	delete(p.line)
	delete(p.scratch)
	delete(p.data)
	delete(p.event_type)
	delete(p.id_buffer)
	delete(p.last_event_id)
	p^ = {}
}

/*
parser_reset prepares `p` for a new connection or marks the end of a stream.

As the spec requires at the end of a stream, it discards the unfinished line
and the event being built, so an event without its closing blank line is never
dispatched. It also re-arms byte order mark detection and clears a stored
error. Queued events, the last event ID and the retry value survive.
*/
parser_reset :: proc(p: ^Parser) {
	clear(&p.line)
	clear(&p.data)
	clear(&p.event_type)
	clear(&p.id_buffer)
	p.bom_seen = 0
	p.started = false
	p.pending_cr = false
	p.err = nil
}

/*
parser_feed parses `chunk` and queues every event it completes.

Inputs:
- p: an initialized Parser.
- chunk: the next bytes of the stream. The parser copies what it keeps.

Returns:
- err: `.Line_Too_Long` or `.Event_Too_Large` when a limit is crossed, or an
  allocator error. After an error the parser returns the same error from every
  feed until parser_reset. Events queued before the error stay available.
*/
parser_feed :: proc(p: ^Parser, chunk: []byte) -> (err: Error) {
	if p.err != nil {
		return p.err
	}
	defer if err != nil {
		p.err = err
	}

	rest := chunk
	if !p.started {
		rest = skip_bom(p, rest) or_return
		if !p.started {
			return nil
		}
	}
	return feed_bytes(p, rest)
}

/*
parser_next returns the oldest queued event.

The returned strings borrow the parser and stay valid until the next call to
parser_next or parser_destroy.
Use it as an iterator: `for ev in sse.parser_next(&p) { ... }`.

Returns:
- ev: the event, valid until the next parser_next call.
- ok: false when the queue is empty.
*/
parser_next :: proc(p: ^Parser) -> (ev: Event, ok: bool) {
	release_current(p)
	if p.head >= len(p.queue) {
		return {}, false
	}
	ev = p.queue[p.head]
	p.queue[p.head] = {}
	p.head += 1
	if p.head == len(p.queue) {
		clear(&p.queue)
		p.head = 0
	}
	p.current = ev
	p.has_current = true
	return ev, true
}

// parser_pending returns how many events wait in the queue.
parser_pending :: proc(p: ^Parser) -> int {
	return len(p.queue) - p.head
}

/*
parser_last_event_id returns the event source's last event ID string: the id
buffer as it stood at the most recent dispatch. Send it in the
`Last-Event-ID` header when reconnecting, unless it is empty. The string
borrows the parser and changes on the next parser_feed.
*/
parser_last_event_id :: proc(p: ^Parser) -> string {
	return string(p.last_event_id[:])
}

/*
parser_retry returns the reconnection time, in milliseconds, from the most
recent valid `retry` field. `ok` is false when the stream never sent one.
*/
parser_retry :: proc(p: ^Parser) -> (ms: u64, ok: bool) {
	return p.retry_ms, p.has_retry
}

/*
parse_all parses a complete stream held in memory.

As at the end of any stream, a final event without its closing blank line is
dropped.

Returns:
- events: every dispatched event, owned by the caller; free them with
  `events_destroy(events, allocator)`.
- err: a Parse_Error or an allocator error. On error nothing is left allocated.
*/
parse_all :: proc(text: string, options := Parser_Options{}, allocator := context.allocator) -> (events: []Event, err: Error) {
	p: Parser
	parser_init(&p, options, allocator)
	defer parser_destroy(&p)
	parser_feed(&p, transmute([]byte)text) or_return

	events = make([]Event, parser_pending(&p), allocator) or_return
	// The queued events are already owned copies, so move them out.
	for &ev in events {
		ev = p.queue[p.head]
		p.queue[p.head] = {}
		p.head += 1
	}
	return events, nil
}

@(private = "file")
release_current :: proc(p: ^Parser) {
	if p.has_current {
		event_destroy(&p.current, p.allocator)
		p.has_current = false
	}
}

// skip_bom drops one leading byte order mark, which may span several chunks.
@(private = "file")
skip_bom :: proc(p: ^Parser, chunk: []byte) -> (rest: []byte, err: Error) {
	i := 0
	for i < len(chunk) && p.bom_seen < len(BOM) {
		if chunk[i] != BOM[p.bom_seen] {
			// Not a byte order mark: replay the bytes held back so far.
			held := p.bom_seen
			p.started = true
			p.bom_seen = 0
			feed_bytes(p, BOM[:held]) or_return
			return chunk[i:], nil
		}
		p.bom_seen += 1
		i += 1
	}
	if p.bom_seen == len(BOM) {
		p.started = true
		p.bom_seen = 0
	}
	return chunk[i:], nil
}

// feed_bytes splits `chunk` into lines on CR, LF and CRLF.
@(private = "file")
feed_bytes :: proc(p: ^Parser, chunk: []byte) -> Error {
	if len(chunk) == 0 {
		return nil
	}
	start := 0
	if p.pending_cr {
		p.pending_cr = false
		if chunk[0] == '\n' {
			start = 1
		}
	}
	for i := start; i < len(chunk); i += 1 {
		c := chunk[i]
		if c != '\r' && c != '\n' {
			continue
		}
		segment := chunk[start:i]
		if len(p.line) > 0 {
			check_line_size(p, len(p.line) + len(segment)) or_return
			append(&p.line, ..segment) or_return
			process_line(p, p.line[:]) or_return
			clear(&p.line)
		} else {
			check_line_size(p, len(segment)) or_return
			process_line(p, segment) or_return
		}
		if c == '\r' {
			if i + 1 < len(chunk) {
				if chunk[i + 1] == '\n' {
					i += 1
				}
			} else {
				p.pending_cr = true
			}
		}
		start = i + 1
	}
	if start < len(chunk) {
		tail := chunk[start:]
		check_line_size(p, len(p.line) + len(tail)) or_return
		append(&p.line, ..tail) or_return
	}
	return nil
}

@(private = "file")
check_line_size :: proc(p: ^Parser, size: int) -> Error {
	if p.options.max_line_size > 0 && size > p.options.max_line_size {
		return .Line_Too_Long
	}
	return nil
}

// process_line applies the spec's per-line rules to one complete line.
@(private = "file")
process_line :: proc(p: ^Parser, raw: []byte) -> Error {
	line := decode_utf8(p, raw) or_return
	if len(line) == 0 {
		return dispatch(p)
	}
	if line[0] == ':' {
		return nil
	}
	field, value := line, ""
	for i in 0 ..< len(line) {
		if line[i] == ':' {
			field = line[:i]
			value = line[i + 1:]
			if len(value) > 0 && value[0] == ' ' {
				value = value[1:]
			}
			break
		}
	}
	switch field {
	case "event":
		clear(&p.event_type)
		append(&p.event_type, value) or_return
	case "data":
		// The data of the finished event is everything buffered so far plus this value.
		if p.options.max_data_size > 0 && len(p.data) + len(value) > p.options.max_data_size {
			return .Event_Too_Large
		}
		append(&p.data, value) or_return
		append(&p.data, '\n') or_return
	case "id":
		for i in 0 ..< len(value) {
			if value[i] == 0 {
				return nil
			}
		}
		clear(&p.id_buffer)
		append(&p.id_buffer, value) or_return
	case "retry":
		if ms, ok := parse_retry(value); ok {
			p.retry_ms = ms
			p.has_retry = true
		}
	}
	return nil
}

// parse_retry accepts one or more ASCII digits that fit in a u64.
@(private = "file")
parse_retry :: proc(value: string) -> (ms: u64, ok: bool) {
	if len(value) == 0 {
		return 0, false
	}
	for i in 0 ..< len(value) {
		c := value[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		digit := u64(c - '0')
		if ms > (max(u64) - digit) / 10 {
			return 0, false
		}
		ms = ms * 10 + digit
	}
	return ms, true
}

// dispatch runs the spec's "dispatch the event" steps on a blank line.
@(private = "file")
dispatch :: proc(p: ^Parser) -> (err: Error) {
	clear(&p.last_event_id)
	append(&p.last_event_id, ..p.id_buffer[:]) or_return

	if len(p.data) == 0 {
		clear(&p.event_type)
		return nil
	}
	data := p.data[:len(p.data) - 1] // drop the final LF
	type := string(p.event_type[:]) if len(p.event_type) > 0 else DEFAULT_EVENT_TYPE

	ev := event_clone(Event{type = type, data = string(data), id = string(p.id_buffer[:])}, p.allocator) or_return
	if _, aerr := append(&p.queue, ev); aerr != nil {
		event_destroy(&ev, p.allocator)
		return aerr
	}
	clear(&p.data)
	clear(&p.event_type)
	return nil
}

/*
decode_utf8 returns `raw` as a string, replacing invalid sequences with U+FFFD
the way the WHATWG Encoding Standard's UTF-8 decoder does: each maximal
invalid subpart becomes one replacement character.
*/
@(private = "file")
decode_utf8 :: proc(p: ^Parser, raw: []byte) -> (s: string, err: Error) {
	if utf8.valid_string(string(raw)) {
		return string(raw), nil
	}
	clear(&p.scratch)
	needed, seen := 0, 0
	code_point: rune
	lower, upper: byte = 0x80, 0xBF
	for i := 0; i < len(raw); i += 1 {
		b := raw[i]
		if needed == 0 {
			switch b {
			case 0x00 ..= 0x7F:
				append(&p.scratch, b) or_return
			case 0xC2 ..= 0xDF:
				needed, code_point = 1, rune(b & 0x1F)
			case 0xE0 ..= 0xEF:
				if b == 0xE0 {
					lower = 0xA0
				} else if b == 0xED {
					upper = 0x9F
				}
				needed, code_point = 2, rune(b & 0x0F)
			case 0xF0 ..= 0xF4:
				if b == 0xF0 {
					lower = 0x90
				} else if b == 0xF4 {
					upper = 0x8F
				}
				needed, code_point = 3, rune(b & 0x07)
			case:
				append_rune(p, utf8.RUNE_ERROR) or_return
			}
			continue
		}
		if b < lower || b > upper {
			needed, seen, code_point = 0, 0, 0
			lower, upper = 0x80, 0xBF
			append_rune(p, utf8.RUNE_ERROR) or_return
			i -= 1 // process this byte again as a fresh start
			continue
		}
		lower, upper = 0x80, 0xBF
		code_point = code_point << 6 | rune(b & 0x3F)
		seen += 1
		if seen == needed {
			append_rune(p, code_point) or_return
			needed, seen, code_point = 0, 0, 0
		}
	}
	if needed != 0 {
		append_rune(p, utf8.RUNE_ERROR) or_return
	}
	return string(p.scratch[:]), nil
}

@(private = "file")
append_rune :: proc(p: ^Parser, r: rune) -> Error {
	bytes, n := utf8.encode_rune(r)
	_, err := append(&p.scratch, ..bytes[:n])
	return err
}
