// Example basic encodes a stream, parses it back in small chunks and plans a reconnect. Run it with `odin run examples/basic`.
package main

import sse "../.."
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	// Server side: frame a few messages.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)

	_ = sse.write_comment(w, "stream opened")
	_ = sse.write_message(w, {retry = 2000, data = "connected"})
	_ = sse.write_message(w, {type = "price", id = "1", data = "YHOO\n+2\n10"})
	if err := sse.write_message(w, {id = "bad\nid", data = "x"}); err != nil {
		fmt.println("refused:", err)
	}
	stream := strings.to_string(b)

	// Client side: parse the bytes as they would arrive from a socket.
	p: sse.Parser
	sse.parser_init(&p, {max_line_size = 64 * 1024})
	defer sse.parser_destroy(&p)

	bytes := transmute([]byte)stream
	for start := 0; start < len(bytes); start += 7 {
		if err := sse.parser_feed(&p, bytes[start:min(start + 7, len(bytes))]); err != nil {
			fmt.eprintln("parse failed:", err)
			os.exit(1)
		}
		for ev in sse.parser_next(&p) {
			fmt.printfln("event=%s id=%q data=%q", ev.type, ev.id, ev.data)
		}
	}

	// The connection dropped: work out how to reconnect.
	r: sse.Reconnect
	sse.reconnect_init(&r, {multiplier = 2, max_delay = 30 * time.Second})
	defer sse.reconnect_destroy(&r)
	if err := sse.reconnect_sync(&r, &p); err != nil {
		fmt.eprintln("sync failed:", err)
		os.exit(1)
	}
	for _ in 0 ..< 3 {
		delay, ok := sse.reconnect_next_delay(&r)
		if !ok {
			break
		}
		fmt.printfln("retry in %v with %s: %q", delay, sse.LAST_EVENT_ID_HEADER, sse.reconnect_last_event_id(&r))
	}
}
