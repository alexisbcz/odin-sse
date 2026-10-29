# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Fixed

- The parser's event queue no longer grows without bound when the consumer always leaves at least one event queued. The parser now drops consumed slots before it queues new events.

## [0.1.0] - 2026-10-29

### Added

- `Parser`, an incremental `text/event-stream` parser that follows the WHATWG HTML rules: `parser_init`, `parser_feed`, `parser_next`, `parser_pending`, `parser_reset` and `parser_destroy`.
- Support for CR, LF and CRLF line endings, including a CRLF pair split across chunks, one leading byte order mark and U+FFFD replacement of invalid UTF-8.
- `parser_last_event_id` and `parser_retry` to read the stream's last event ID and reconnection time.
- `Parser_Options` with `max_line_size` and `max_data_size` limits, reported as `Parse_Error` values.
- `parse_all`, `event_clone`, `event_destroy` and `events_destroy` for streams held in memory.
- An encoder for servers: `write_message`, `encode_message`, `write_comment`, `write_id`, `write_retry` and `validate_message`, with `Encode_Error` for ids and event types that would break the framing.
- `Reconnect`, a reconnection helper with the last event ID, the `retry` delay, exponential backoff, jitter and an attempt limit.
- `check_response` and `is_event_stream` for the spec's rule on which responses open a stream.

[Unreleased]: https://github.com/alexisbcz/odin-sse/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-sse/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-sse/releases/tag/v0.1.0
