# Crop bounds investigation — 2026-09-19

Capture One 16.8.5.30, copied fixture `/Users/kiri11/Desktop/papochka/2U6A7257.CR3`.
Original SHA-256: `2505287a24868a162c94bc879303a76f1e76b7ccb2bba4cacfdfeb4a33c4b868`.
Both live suites verified unchanged original RAW and source variant.

- Packaged `geometry`: passed (114.508 s).
- Final `make check`: passed, including fractional singleton/empty center
  intervals, adjacent floating-point endpoints, and three proposal tests.
- Packaged `lens`: all six cases passed (201.110 s), including the added stored
  off-center observation with unchanged lens context.
- Archive SHA-256: `be12066fa4cd7d1282ba072f1629bafab7d1b0ecf3d6979ff1f6d8172a350527`.
- Regular suites omitted: cli, mcp, perspective, keystone, catalog, existing,
  inventory, native. Geometry/lens themselves exercise CLI and MCP calls.
- Fault injection omitted: no production bounds, mutation, journaling, lifetime,
  or recovery behavior changed. A production bounds change still requires the
  affected geometry/lens fault cases against a rebuilt archive.

The observed crop overhangs its reported right bound by two pixels, within the
existing edge tolerance. A larger stored overhang was not reproduced on this
fixture. The retained strict proposal shifts the center left by two pixels; it
was not applied. Native fixture normalization is explicitly recorded, not
described as an exact copy. See the [investigation](../../crop-bounds-investigation.md)
and [proposal](lens/contained-proposal.json).

JSONL events and journals are retained here; preview paths refer to the disposable
Sessions in `/private/tmp` and are not portable image attachments. The suites
closed their owned Sessions and left Capture One running.
