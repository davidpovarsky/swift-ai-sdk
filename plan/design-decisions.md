# Swift SDK design decisions

## Original accepted tool JSON for local executors (2026-11-15)

Swift's `JSONValue.number(Double)` cannot preserve an original Int64 beyond 2^53,
or distinguish integer tokens from decimal/exponent tokens after re-encoding.
Add optional `ToolCallRawInput` to typed tool calls, local `ToolCallPart` storage,
and `ToolCallOptions`. Existing initializers and stored messages default to nil.
Never reconstruct this field by serializing a normalized value. Empty legacy
argument strings and schema transformations without identical parsed values have
no original-input provenance. A successful repair retains the accepted repaired
JSON and must retain the original call ID.

The execution boundary checks call/tool/type correlation, bounded JSON syntax,
agreement with normalized input and the current schema, with cancellation checks
after validation awaits. Static/dynamic identity and original input survive the
response-message/Codable approval-resume path. Ambiguous approval correlation is
not executable. These fields do not grant consent, identity or host authority;
applications still enforce current session state and native argument validation.
The provider prompt DTO and telemetry conversion remain unchanged. There is no
parallel parser/engine, stream side cache, schema coercion or numeric-type change.

This additive local executor option is an intentional Swift-specific extension,
not an upstream parity refresh. It preserves JSON text rather than promising
arbitrary-precision numeric validation. Applications with Int64/finite Double
contracts must reject unsupported values themselves and fail closed if original
input is absent. Verification and its platform limits are recorded in the Hanlin
producer/consumer handoff; no Apple/device or root SwiftPM test pass is implied.
