# odin-sse

[![CI](https://github.com/alexisbcz/odin-sse/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-sse/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Server-Sent Events for Odin: an incremental parser that follows the WHATWG rules byte for byte, an encoder for servers, and a reconnection helper for clients.

- The parser accepts chunks of any size, so a chunk may end inside a line, a UTF-8 sequence, a CRLF pair or the byte order mark.
- It applies the spec's rules for `data`, `event`, `id` and `retry`, comments, CR, LF and CRLF line endings, one leading byte order mark and U+FFFD replacement of invalid UTF-8.
- Optional limits on line and event size keep a hostile server from growing memory without bound.
- The encoder splits multi-line data and refuses ids and event types that would break the framing.
- `Reconnect` tracks the last event ID, the server's `retry` value and an optional exponential backoff with jitter.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-sse libs/sse
```

```odin
import sse "libs/sse"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-sse ~/odin-shared/sse
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import sse "shared:sse"
```

## Quick start

Parse a stream as bytes arrive, for example from a socket:

```odin
package main

import "core:fmt"
import sse "shared:sse"

main :: proc() {
	p: sse.Parser
	sse.parser_init(&p, {max_line_size = 64 * 1024})
	defer sse.parser_destroy(&p)

	chunks := []string{"event: price\nid: 1\nda", "ta: YHOO\ndata: +2\r\n\r\n"}
	for chunk in chunks {
		if err := sse.parser_feed(&p, transmute([]byte)chunk); err != nil {
			fmt.eprintln("parse failed:", err)
			return
		}
		for ev in sse.parser_next(&p) {
			// Prints: price 1 "YHOO\n+2"
			fmt.printfln("%s %s %q", ev.type, ev.id, ev.data)
		}
	}
}
```

Write events from a server into any `io.Writer`:

```odin
package main

import "core:fmt"
import "core:strings"
import sse "shared:sse"

main :: proc() {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)

	_ = sse.write_comment(w, "keep-alive")
	if err := sse.write_message(w, {type = "price", id = "1", retry = 2000, data = "YHOO\n+2"}); err != nil {
		fmt.eprintln("encode failed:", err)
		return
	}
	fmt.print(strings.to_string(b))
}
```

That program prints:

```text
: keep-alive
event: price
id: 1
retry: 2000
data: YHOO
data: +2

```

Plan a reconnect after the connection drops:

```odin
package main

import "core:fmt"
import "core:time"
import sse "shared:sse"

main :: proc() {
	p: sse.Parser
	sse.parser_init(&p)
	defer sse.parser_destroy(&p)
	_ = sse.parser_feed(&p, transmute([]byte)string("retry: 500\nid: 7\ndata: x\n\n"))

	r: sse.Reconnect
	sse.reconnect_init(&r, {multiplier = 2, max_delay = 30 * time.Second, jitter = 0.2})
	defer sse.reconnect_destroy(&r)
	if err := sse.reconnect_sync(&r, &p); err != nil {
		return
	}

	delay, ok := sse.reconnect_next_delay(&r)
	if ok {
		fmt.println("wait", delay, "then send", sse.LAST_EVENT_ID_HEADER, sse.reconnect_last_event_id(&r))
	}
}
```

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `parser_init(p, options, allocator)` | Prepare a `Parser`, with optional size limits | No | `parser_destroy` |
| `parser_feed(p, chunk)` | Parse the next bytes and queue finished events | Yes | `parser_destroy` |
| `parser_next(p)` | Pop the oldest event; usable as a `for` iterator | No | Not needed; valid until the next call |
| `parser_pending(p)` | Count queued events | No | Not needed |
| `parser_last_event_id(p)` | The last event ID string for `Last-Event-ID` | No | Not needed; borrows the parser |
| `parser_retry(p)` | The latest valid `retry` value in milliseconds | No | Not needed |
| `parser_reset(p)` | Start a new connection or mark the end of a stream | No | Not needed |
| `parse_all(text, options, allocator)` | Parse a whole stream held in memory | Yes | `events_destroy` |
| `event_clone(ev, allocator)` | Keep an `Event` past the next `parser_next` | Yes | `event_destroy` |
| `write_message(w, msg)` | Write one `Message` frame to an `io.Writer` | No | Not needed |
| `encode_message(msg, allocator)` | Return one frame as a string | Yes | `delete` |
| `write_comment(w, text)` | Write comment lines, for example keep-alive pings | No | Not needed |
| `write_id(w, id)` and `write_retry(w, ms)` | Update the client's ID or reconnection time alone | No | Not needed |
| `validate_message(msg)` | Check a message before writing it | No | Not needed |
| `reconnect_init(r, options, allocator)` | Prepare a `Reconnect` with backoff options | No | `reconnect_destroy` |
| `reconnect_sync(r, p)` | Copy the last event ID and `retry` from a parser | Yes | `reconnect_destroy` |
| `reconnect_next_delay(r)` | Count a failed attempt and return the wait | No | Not needed |
| `reconnect_connected(r)` | Reset the attempt count after success | No | Not needed |
| `check_response(status, content_type)` | Apply the spec's rule to open or fail a response | No | Not needed |
| `is_event_stream(content_type)` | Match `text/event-stream`, ignoring parameters and case | No | Not needed |
| `Error` | Union of `Parse_Error`, `Encode_Error`, `io.Error` and `runtime.Allocator_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
odin run examples/server   # then: curl -N http://127.0.0.1:8080/
```

## Design notes

- Events from `parser_next` borrow the parser until the next call, so a loop over a busy stream allocates once per event and frees it on the next step. Call `event_clone` to keep one.
- The last event ID updates at every blank line, even one that dispatches no event, as the spec says. Read it with `parser_last_event_id`, not from the last event.
- `parser_reset` follows the spec at the end of a stream: the parser drops an event that lacks its closing blank line. A new stream also starts with an empty ID buffer, so its first dispatch without an `id` field clears the last event ID.
- `retry` values must be ASCII digits only. The parser ignores values that don't fit in a `u64`.
- After `Line_Too_Long` or `Event_Too_Large` the parser returns the same error until `parser_reset`, because the stream is no longer in a known state.
- Every allocating procedure takes `allocator := context.allocator` and says who owns the result. The library never panics on bad input.
- The package keeps no global mutable state. Each `Parser` and `Reconnect` is safe to use from one thread at a time. Jitter draws from `context.random_generator`.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
vale sync && vale *.md
```

The tests port the examples from section 9.2 of the WHATWG HTML standard, feed one stream at every chunk size, and fail allocations one by one to prove that error paths free everything.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
