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

## Google thought signatures in the V3 OpenAI-compatible path (2026-11-23)

The V3 OpenAI-compatible adapter retains a received, nonempty
`extra_content.google.thought_signature` as the opaque string
`providerMetadata.google.thoughtSignature`. The wire provider identity is
independent of the configured adapter name, including
`hanlin-openai-compatible`. The original core response-message path carries
that metadata into tool-call provider options; the V3 converter restores the
same nested wire field on the next assistant tool-call message. Missing and
empty signatures remain absent. V3 does not coerce arbitrary JSON values into
signatures or synthesize a signature.

The original tracker emits completed calls only in `flush()`. An optional
metadata merge hook, nil by default, lets this V3 adapter retain metadata from
later deltas before that emission. Only the relevant tool index is updated.
Identical repeats are harmless; two nonempty signatures with different UTF-8
bytes cause an invalid-response error before a completed call is emitted.
There is no concatenation, normalization, cross-call borrowing or replacement.
The Google documentation requires returning received signatures unchanged but
does not define conflicting signatures on a single call. Rejecting that
ambiguity is an explicit Swift contract, not a claimed upstream parity result.

The V4 metadata namespace, converter and stream lifecycle retain their
existing behavior. Other tracker callers keep the original first-delta
metadata policy unless they opt into the hook. Tool dispatch, prompt/model
selection, finish-stop continuation, validation, cancellation and package
dependencies are unchanged.

Reference: [Google thought signatures](https://ai.google.dev/gemini-api/docs/thought-signatures).
The new original-SDK regressions cover response and streaming receipt,
absent/empty baselines, late metadata after complete JSON, parallel isolation,
duplicate/conflicting values, and the real `streamText` path through captured
mocked fetch requests and two local tools with `finish_reason: stop`.
Source preparation alone does not establish an Apple test pass or the HTTP
cause of the observed Live failure; those remain separately qualified.

## Current OpenAI cache controls and stream usage attributes (2026-11-24)

This narrowly extends the existing original provider options with current
Responses cache lifetime/prewarm/diagnostic fields. The Chat serializer keeps
its own supported control set. Cache prewarming is an explicit direct-provider
operation, never an automatic side effect of chat or engine construction.
The lifetime is a minimum reuse window, not a data deletion deadline.

The original stream telemetry attribute builder reads normalized input token
details and adds cache-write and uncached counts beside cached reads. This
repairs an observability omission without adding a parallel telemetry stream,
global tracer, content logging, exporter, or network destination.

References and authored fixture names are recorded in upstream/providers/openai.md.
This is an intentional API/observability extension to the existing Swift fork,
not a broad upstream parity refresh. Native compilation and test evidence must
be supplied by the integration owner before this new slice is described as verified.
