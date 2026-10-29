/*
Example server streams a clock to every client that connects, one client at a
time. Run it with `odin run examples/server`, then in another terminal:

	curl -N http://127.0.0.1:8080/

It reads the `Last-Event-ID` header so a reconnecting client resumes counting
where it left off.
*/
package main

import sse "../.."
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

EVENTS_PER_CLIENT :: 10

main :: proc() {
	endpoint, _ := net.parse_endpoint("127.0.0.1:8080")
	listener, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintln("listen failed:", err)
		return
	}
	defer net.close(listener)
	fmt.println("listening on http://127.0.0.1:8080/")

	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			fmt.eprintln("accept failed:", aerr)
			continue
		}
		serve(client)
		net.close(client)
	}
}

// serve reads the request head, then streams numbered events.
serve :: proc(client: net.TCP_Socket) {
	buf: [4096]byte
	n, rerr := net.recv_tcp(client, buf[:])
	if rerr != nil {
		return
	}
	start := resume_point(string(buf[:n]))

	head := "HTTP/1.1 200 OK\r\nContent-Type: " + sse.MIME_TYPE + "\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
	if !send(client, head) {
		return
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	w := strings.to_writer(&b)
	_ = sse.write_retry(w, 1000)
	_ = sse.write_comment(w, "clock")

	for i in start ..< start + EVENTS_PER_CLIENT {
		id_buf: [32]byte
		id := strconv.write_int(id_buf[:], i64(i), 10)
		now := time.now()
		data := fmt.tprintf("tick %d at %v", i, now)
		if err := sse.write_message(w, {type = "tick", id = id, data = data}); err != nil {
			fmt.eprintln("encode failed:", err)
			return
		}
		if !send(client, strings.to_string(b)) {
			return
		}
		strings.builder_reset(&b)
		free_all(context.temp_allocator)
		time.sleep(time.Second)
	}
}

// resume_point returns one past the number in the Last-Event-ID header, or 0.
resume_point :: proc(request: string) -> int {
	rest := request
	for line in strings.split_lines_iterator(&rest) {
		name, _, value := strings.partition(line, ":")
		if strings.equal_fold(strings.trim_space(name), sse.LAST_EVENT_ID_HEADER) {
			if last, ok := strconv.parse_int(strings.trim_space(value)); ok {
				return last + 1
			}
		}
	}
	return 0
}

send :: proc(client: net.TCP_Socket, text: string) -> bool {
	_, err := net.send_tcp(client, transmute([]byte)text)
	return err == nil
}
