# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-09-07

### Added
- **Core Library (`CaptureOneCore`)**:
  - Fail-closed working-variant safety model: originals cannot be mutated directly; mutations strictly require a document-bound working clone (`c1_wrk_<uuid>`).
  - Optimistic concurrency control via SHA-256 adjustment state hashing (`--if-state`).
  - Strict Catalog read-only mutation guards preventing edits to Catalogs.
  - Cross-process advisory locking (`flock`) to serialize operations across CLI and MCP instances.
  - Pre-dispatch operation journaling (`.c1/journal.jsonl`) for tracking, auditing, and recovery.
  - FieldSpec registry for verified adjustments (`exposure`, `contrast`, `saturation`, `temperature`, `tint`) with tolerance-aware precision rounding and coupled white balance handling.
  - Read-only capture metadata extraction (`camera`, `lens`, `iso`, `shutterSpeed`, `asShotWB`, `captureDate`, `starRating`, `colorTag`).
  - Dedicated `c1-preview` recipe export with ImageIO decoding and pixel SHA-256 verification.
  - `testedBuilds` registry supporting multiple qualified Capture One builds (starting with `16.8.5.30`), with default compatibility and warning notes for Capture One 16.4+ through 16.x.
- **`c1` CLI Executable**:
  - 15 subcommands: `doctor`, `version`, `capabilities`, `schema`, `doc info`, `variants list`, `variant clone`, `variant delete`, `variant baseline`, `get`, `set`, `add`, `reset`, `diff`, `dump`, `preview`, `operation status`.
  - Machine-readable JSON (`--format json`), streaming JSONL (`--format jsonl`), and human-friendly table outputs.
  - Standardized error codes (`app-not-running`, `no-document`, `unsupported-version`, `unmanaged-variant`, `capture-one-busy`, `document-changed`, `state-changed`, `readback-mismatch`, `permission-denied`, etc.) and non-zero exit codes.
- **`c1-mcp` Server**:
  - Full-featured Model Context Protocol (MCP) server over stdio built on the official Swift MCP SDK (`modelcontextprotocol/swift-sdk`).
  - 16 registered tools with complete JSON schemas matching the CLI contract.
  - Dual text (JSON metadata) and visual `image/jpeg` base64 content blocks for variant previews.
- **Documentation & Workflows**:
  - [docs/QUALIFYING_NEW_BUILDS.md](docs/QUALIFYING_NEW_BUILDS.md): Step-by-step qualification runbook for testing and registering newly released Capture One builds.
  - GitHub Actions CI (`.github/workflows/ci.yml`) and Release workflow (`.github/workflows/release.yml`) for automated testing and tagged asset packaging.
  - End-to-end integration test suites (`Tests/integration_test.py` and `Tests/mcp_test.py`) with disposable Sessions and real RAW file verification.
  - 237 automated unit assertions in standalone test harness (`make test`).
