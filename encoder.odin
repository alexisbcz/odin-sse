package sse

import "core:io"
import "core:strconv"
import "core:strings"

/*
Message is one event for a server to send.

- type: the `event` field; leave it empty for the default `message` type.
- data: the payload. Lines split on CR, LF or CRLF become separate `data` lines,
  so the client sees the same text with LF line endings.
- id: the `id` field; leave it empty to send none. To clear the client's last
  event ID, use write_id with an empty string.
- retry: when non-zero, a `retry` field with this many milliseconds.
*/
Message :: struct {
	type:  string,
	data:  string,
	id:    string,
	retry: u64,
}

/*
validate_message checks that `msg` can be framed without changing meaning.

Returns:
- err: `.Invalid_Event_Type` when the type holds CR or LF, `.Invalid_Id` when
  the id holds CR, LF or NULL, otherwise nil.
*/
validate_message :: proc(msg: Message) -> Error {
	if strings.contains_any(msg.type, "\r\n") {
		return .Invalid_Event_Type
	}
	return validate_id(msg.id)
}

/*
write_message writes `msg` as one complete event, ending with the blank line
that makes the client dispatch it. It validates first, so nothing is written
for an invalid message. Wrap a `strings.Builder` with `strings.to_writer` to
write into memory.

Returns:
- err: an Encode_Error from validate_message, or the writer's io.Error.
*/
write_message :: proc(w: io.Writer, msg: Message) -> (err: Error) {
	validate_message(msg) or_return
	if msg.type != "" {
		write_field(w, "event", msg.type) or_return
	}
	if msg.id != "" {
		write_field(w, "id", msg.id) or_return
	}
	if msg.retry != 0 {
		write_retry_field(w, msg.retry) or_return
	}
	data := msg.data
	for {
		line, rest, found := split_line(data)
		write_field(w, "data", line) or_return
		if !found {
			break
		}
		data = rest
	}
	return write_raw(w, "\n")
}

/*
encode_message returns `msg` framed as text.

Returns:
- text: the frame, owned by the caller; free it with `delete(text, allocator)`.
- err: an Encode_Error from validate_message, or an allocator error. On error nothing is left allocated.
*/
encode_message :: proc(msg: Message, allocator := context.allocator) -> (text: string, err: Error) {
	validate_message(msg) or_return
	b := strings.builder_make(0, 64 + len(msg.data), allocator) or_return
	if werr := write_message(strings.to_writer(&b), msg); werr != nil {
		strings.builder_destroy(&b)
		// A Builder only fails when it cannot grow.
		return "", .Out_Of_Memory
	}
	return strings.to_string(b), nil
}

/*
write_comment writes `text` as comment lines, which clients ignore. Servers
send comments, often empty ones, as keep-alive pings. Each line of `text`
becomes its own `:` line.
*/
write_comment :: proc(w: io.Writer, text: string) -> (err: Error) {
	rest := text
	for {
		line, next, found := split_line(rest)
		if line == "" {
			write_raw(w, ":\n") or_return
		} else {
			write_raw(w, ": ") or_return
			write_raw(w, line) or_return
			write_raw(w, "\n") or_return
		}
		if !found {
			return nil
		}
		rest = next
	}
}

// write_retry writes a lone `retry` field that sets the client's reconnection time.
write_retry :: proc(w: io.Writer, ms: u64) -> Error {
	return write_retry_field(w, ms)
}

/*
write_id writes a lone `id` field followed by a blank line. The client updates
its last event ID without dispatching an event. An empty `id` clears it.

Returns:
- err: `.Invalid_Id` when the id holds CR, LF or NULL, or the writer's io.Error.
*/
write_id :: proc(w: io.Writer, id: string) -> (err: Error) {
	validate_id(id) or_return
	write_field(w, "id", id) or_return
	return write_raw(w, "\n")
}

@(private = "file")
validate_id :: proc(id: string) -> Error {
	if strings.contains_any(id, "\r\n\x00") {
		return .Invalid_Id
	}
	return nil
}

// split_line cuts `s` at its first CR, LF or CRLF.
@(private = "file")
split_line :: proc(s: string) -> (line, rest: string, found: bool) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\n':
			return s[:i], s[i + 1:], true
		case '\r':
			if i + 1 < len(s) && s[i + 1] == '\n' {
				return s[:i], s[i + 2:], true
			}
			return s[:i], s[i + 1:], true
		}
	}
	return s, "", false
}

@(private = "file")
write_field :: proc(w: io.Writer, name, value: string) -> (err: Error) {
	write_raw(w, name) or_return
	if value == "" {
		return write_raw(w, ":\n")
	}
	write_raw(w, ": ") or_return
	write_raw(w, value) or_return
	return write_raw(w, "\n")
}

@(private = "file")
write_retry_field :: proc(w: io.Writer, ms: u64) -> Error {
	buf: [32]byte
	return write_field(w, "retry", strconv.write_uint(buf[:], ms, 10))
}

@(private = "file")
write_raw :: proc(w: io.Writer, s: string) -> Error {
	_, err := io.write_string(w, s)
	return err
}
