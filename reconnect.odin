package sse

import "base:runtime"
import "core:math/rand"
import "core:strings"
import "core:time"

// DEFAULT_RECONNECT_DELAY is the reconnection time used before the server sends `retry`.
DEFAULT_RECONNECT_DELAY :: 3 * time.Second

/*
Reconnect_Options tunes a Reconnect. The zero value waits
`DEFAULT_RECONNECT_DELAY`, or the server's `retry` value, before every
attempt, forever.

- initial_delay: the delay before the server sends `retry`; 0 means DEFAULT_RECONNECT_DELAY.
- multiplier: each failed attempt multiplies the delay by this; values of 1 or less keep it constant.
- max_delay: an upper bound on any delay; 0 means no bound.
- jitter: a fraction from 0 to 1. Each delay shrinks by a random part of this fraction, so many clients don't reconnect in lockstep.
- max_attempts: how many attempts in a row reconnect_next_delay allows; 0 means no limit.
*/
Reconnect_Options :: struct {
	initial_delay: time.Duration,
	multiplier:    f64,
	max_delay:     time.Duration,
	jitter:        f64,
	max_attempts:  int,
}

/*
Reconnect tracks what a client needs to reconnect after a dropped stream: the
last event ID for the `Last-Event-ID` header, the reconnection time and the
number of failed attempts in a row.

Create one with reconnect_init and release it with reconnect_destroy. A
Reconnect is safe to use from one thread at a time.
*/
Reconnect :: struct {
	allocator:     runtime.Allocator,
	options:       Reconnect_Options,
	// The reconnection time from the latest `retry` field, or the initial delay.
	delay:         time.Duration,
	// Failed attempts since the last successful connection.
	attempts:      int,
	last_event_id: string,
}

// Response_Verdict says what a client does with the response to an event stream request.
Response_Verdict :: enum {
	// The response is a stream: start parsing the body.
	Open,
	// Fail the connection and don't reconnect, as the spec requires.
	Fail,
}

/*
reconnect_init prepares `r`. It allocates only when a last event ID is
stored. Call reconnect_destroy when done.
*/
reconnect_init :: proc(r: ^Reconnect, options := Reconnect_Options{}, allocator := context.allocator) {
	r^ = {}
	r.allocator = allocator
	r.options = options
	r.delay = options.initial_delay if options.initial_delay > 0 else DEFAULT_RECONNECT_DELAY
}

// reconnect_destroy frees the stored last event ID and zeroes `r`.
reconnect_destroy :: proc(r: ^Reconnect) {
	delete(r.last_event_id, r.allocator)
	r^ = {}
}

// reconnect_set_retry sets the reconnection time from a `retry` value in milliseconds.
reconnect_set_retry :: proc(r: ^Reconnect, ms: u64) {
	MAX_MS :: u64(max(i64) / i64(time.Millisecond))
	r.delay = time.Duration(min(ms, MAX_MS)) * time.Millisecond
}

/*
reconnect_set_last_event_id stores a copy of `id`.

Returns:
- err: an allocator error. On error the previous ID is kept.
*/
reconnect_set_last_event_id :: proc(r: ^Reconnect, id: string) -> (err: Error) {
	if id == r.last_event_id {
		return nil
	}
	owned := strings.clone(id, r.allocator) or_return
	delete(r.last_event_id, r.allocator)
	r.last_event_id = owned
	return nil
}

/*
reconnect_last_event_id returns the ID to send in the `Last-Event-ID` header.
An empty string means the client sends no header. The string borrows `r`.
*/
reconnect_last_event_id :: proc(r: ^Reconnect) -> string {
	return r.last_event_id
}

/*
reconnect_sync copies the last event ID and the latest `retry` value from `p`.
Call it after each parser_feed, or at least when the connection drops.

Returns:
- err: an allocator error. On error the previous ID is kept.
*/
reconnect_sync :: proc(r: ^Reconnect, p: ^Parser) -> Error {
	if ms, ok := parser_retry(p); ok {
		reconnect_set_retry(r, ms)
	}
	return reconnect_set_last_event_id(r, parser_last_event_id(p))
}

/*
reconnect_next_delay records one more failed attempt and returns how long to
wait before trying again.

The delay is the reconnection time multiplied by `multiplier` once per earlier
failure, capped at `max_delay`, then reduced by up to `jitter` of itself using
`context.random_generator`.

Returns:
- delay: how long to wait.
- ok: false when `max_attempts` is reached; the client then gives up.
*/
reconnect_next_delay :: proc(r: ^Reconnect) -> (delay: time.Duration, ok: bool) {
	if r.options.max_attempts > 0 && r.attempts >= r.options.max_attempts {
		return 0, false
	}
	value := f64(r.delay)
	if r.options.multiplier > 1 {
		for _ in 0 ..< r.attempts {
			value *= r.options.multiplier
			if r.options.max_delay > 0 && value >= f64(r.options.max_delay) {
				break
			}
			if value >= f64(max(i64)) {
				break
			}
		}
	}
	if r.options.max_delay > 0 && value > f64(r.options.max_delay) {
		value = f64(r.options.max_delay)
	}
	if value >= f64(max(i64)) {
		value = f64(max(i64))
	}
	if r.options.jitter > 0 {
		value -= value * clamp(r.options.jitter, 0, 1) * rand.float64()
	}
	r.attempts += 1
	if value >= f64(max(i64)) {
		return time.Duration(max(i64)), true
	}
	return time.Duration(value), true
}

// reconnect_attempts returns how many attempts failed since the last success.
reconnect_attempts :: proc(r: ^Reconnect) -> int {
	return r.attempts
}

// reconnect_connected resets the attempt count after a connection opens.
reconnect_connected :: proc(r: ^Reconnect) {
	r.attempts = 0
}

/*
check_response applies the spec's rule for an event stream response: the
client opens the stream only for status 200 with a `text/event-stream`
Content-Type. Any other response fails the connection for good, so the client
must not reconnect. Network errors are different: they call for a reconnect.
*/
check_response :: proc(status: int, content_type: string) -> Response_Verdict {
	if status == 200 && is_event_stream(content_type) {
		return .Open
	}
	return .Fail
}

/*
is_event_stream reports whether a Content-Type header value names
`text/event-stream`. It ignores parameters such as `charset`, surrounding
spaces and letter case.
*/
is_event_stream :: proc(content_type: string) -> bool {
	essence := content_type
	if i := strings.index_byte(essence, ';'); i >= 0 {
		essence = essence[:i]
	}
	essence = strings.trim(essence, " \t")
	if len(essence) != len(MIME_TYPE) {
		return false
	}
	// Media types compare case-insensitively in ASCII only.
	want := MIME_TYPE
	for i in 0 ..< len(essence) {
		c := essence[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != want[i] {
			return false
		}
	}
	return true
}
