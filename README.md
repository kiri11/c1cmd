# c1 — Unofficial Capture One CLI & MCP Server

[![CI](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml/badge.svg)](https://github.com/kiri11/c1cmd/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey.svg)]()
[![Capture One](https://img.shields.io/badge/Capture%20One-16.8.5.30%20(pinned)-blue.svg)]()

`c1` provides an unofficial CLI and Model Context Protocol (MCP) server for automating [Capture One](https://www.captureone.com/). It allows coding and reasoning agents (Claude Code, Cursor, Windsurf, Codex, etc.) as well as scripts to read, adjust, diff, and export variants inside Capture One through a stable, self-describing JSON and MCP interface.

---

> [!IMPORTANT]
> **Legal Disclaimer & Trademark Notice**  
> Capture One is a registered trademark of Capture One A/S.  
> `c1` is an independent, unofficial open-source project and is **not** affiliated with, endorsed by, or sponsored by Capture One A/S. No proprietary Capture One code, binaries, or assets are contained within this repository.

---

## Key Features

- **Hands, Not Brain:** `c1` executes adjustments with precision, safety guarantees, and deterministic readbacks. AI agents or external scripts provide the creative judgment.
- **Fail-Closed Safety Architecture:**
  - **Working-Variant Model:** Originals and native variants are strictly protected and cannot be mutated. Edits only occur on managed working clones (`c1_wrk_<uuid>`).
  - **Zero RAW Mutation:** RAW source files are never touched or modified (cryptographically verified via SHA-256).
  - **Catalog Guard:** Catalogs are strictly read-only; mutation verbs (`clone`, `delete`, `set`, `add`, `reset`, `baseline`) fail closed. Full editing is supported on Sessions.
  - **Optimistic Concurrency:** State hashing (`--if-state <hash>`) prevents race conditions between agents and photographer UI edits.
  - **Cross-Process Locking:** Advisory `flock` serialization ensures multiple CLI processes and MCP instances do not collide.
  - **Pre-Dispatch Journaling:** Every mutation is journaled (`.c1/journal.jsonl`) before dispatch, enabling audit trails and status reconciliation.
- **Dual Interfaces:**
  - **`c1` CLI:** 15 subcommands formatted for both human inspection and pipeable JSON.
  - **`c1-mcp` Server:** Full-featured stdio MCP adapter exposing 16 tools, dual text/JSON responses, and base64-encoded visual JPEG previews for AI chat interfaces.

---

## System Requirements

- **macOS:** macOS 13.0+ (Ventura or later), Apple Silicon (`arm64`).
- **Capture One:** Pinned to build **16.8.5.30** (tested and verified).
  > Untested builds fail closed with `unsupported-version`. To bypass this check for testing, set `C1_ALLOW_UNTESTED_BUILD=1`.
- **Permissions:** macOS Automation permissions (`System Settings > Privacy & Security > Automation`).
- **Build Tools:** Swift 5.9+ / Xcode command line tools.

---

## Installation

### Building from Source

```bash
git clone https://github.com/kiri11/c1cmd.git
cd c1cmd

# Build release binaries
make build

# Install to /usr/local/bin (requires sudo) or ~/.local/bin
make install
```

Alternatively, build with the Swift Package Manager directly:
```bash
swift build -c release
# Binaries are in .build/release/c1 and .build/release/c1-mcp
```

---

## Configuring the MCP Server

`c1-mcp` runs over `stdio` and connects seamlessly to any MCP-compliant client.

### Claude Desktop

Edit your Claude Desktop configuration file:
`~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "c1": {
      "command": "/usr/local/bin/c1-mcp"
    }
  }
}
```

### Cursor

In Cursor settings under **Features > MCP Servers**, add a new server:
- **Name:** `c1`
- **Type:** `command`
- **Command:** `/usr/local/bin/c1-mcp`

### Claude Code

Run Claude Code with the server configured:
```bash
claude mcp add c1 -- /usr/local/bin/c1-mcp
```

---

## CLI Usage & Workflow

### 1. Check Health & Environment

Verify Capture One status, active document, and advisory lock:
```bash
c1 doctor
```

Output:
```json
{
  "allChecksPassed" : true,
  "appRunning" : true,
  "appVersion" : "16.8.5.30",
  "docName" : "Shoot2026.cosessiondb",
  "exactBuildMatched" : true,
  "hasDocument" : true,
  "isSession" : true,
  "lockAcquired" : true,
  "pinnedBuild" : "16.8.5.30",
  "unresolvedOperationsCount" : 0
}
```

### 2. List Variants

```bash
# List all variants in the active session
c1 variants list

# Or list variants in a specific collection
c1 variants list --collection Capture
```

### 3. Clone to a Managed Working Variant

Originals cannot be adjusted directly. First create a managed working clone:
```bash
c1 variant clone 1
```
Output:
```json
{
  "baselineStateHash" : "3307611ef4f7831f0db0089e17b3f9ff4ff9a7c36a282f1b0a72ad41ec3ee989",
  "cloneVariantId" : "4",
  "documentPath" : "/Volumes/Work/Shoot2026",
  "sourceVariantId" : "1",
  "workingRef" : "c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4"
}
```

### 4. Read Adjustments & Metadata

```bash
c1 get c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4
```

### 5. Mutate Adjustments (Optimistic Concurrency)

Apply absolute (`set`) or relative (`add`) adjustments with `--if-state`:
```bash
# Absolute adjustment
c1 set c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4 \
  --if-state 3307611ef4f7831f0db0089e17b3f9ff4ff9a7c36a282f1b0a72ad41ec3ee989 \
  exposure=0.35 kelvin=5600 tint=-2.0

# Relative delta
c1 add c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4 \
  --if-state <new-state-hash> \
  exposure=-0.15 contrast=5.0
```

### 6. Export Verified Preview

Renders an sRGB JPEG preview via a dedicated `c1-preview` recipe and validates ImageIO decoding and pixel SHA-256:
```bash
c1 preview c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4
```

### 7. Compare Changes

```bash
# Compare working clone against its baseline
c1 diff c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4

# Or compare two variants
c1 diff 1 4
```

### 8. Cleanup Unwanted Clones

```bash
c1 variant delete c1_wrk_b74ad0a1-d576-47b1-b924-a7442ebbe8e4
```
*(Only managed working clones can be deleted; deleting original variants is blocked.)*

---

## Supported Adjustment Fields (v0.1)

| Field | Aliases | Range | Unit | Notes |
|---|---|---|---|---|
| `exposure` | `exp` | `[-4.0, 4.0]` | EV | Tolerance: `1e-5` |
| `contrast` | - | `[-50.0, 50.0]` | - | Tolerance: `1e-5` |
| `saturation` | `sat` | `[-100.0, 100.0]` | - | Tolerance: `1e-5` |
| `temperature` | `kelvin`, `temp` | `[800.0, 14000.0]` | Kelvin | Coupled with tint; tolerance: `0.01` |
| `tint` | - | `[-50.0, 50.0]` | - | Coupled with temp; tolerance: `0.0001` |

Read-only capture metadata includes: `camera`, `lens`, `iso`, `shutterSpeed`, `asShotWB`, `captureDate`, `starRating`, and `colorTag`.

---

## Safety & Architecture

```
AI Agent / Script ──▶ c1 (CLI)  /  c1-mcp (stdio MCP server)
                            │
                      CaptureOneCore (Swift Library)
                            │  FieldSpec Registry · Advisory Lock · Provenance Store
                            │  Operation Journal · State Hashing · Catalog Guards
                      AppleScriptBridge
                            │  Pre-compiled Handlers.applescript
                      Capture One 16.8.5.30 (macOS GUI active)
```

1. **No Runtime AppleScript Generation:** All Apple Events are dispatched through pre-compiled handler routines in bundled `Handlers.applescript` using non-reserved AppleScript user keys (`usrf`).
2. **Advisory File Lock:** A system flock protects against concurrent operations.
3. **Strict Document Context:** Operations are bound to the open document; switching documents or sessions between commands invalidates stale references (`document-changed`).

---

## Troubleshooting & Permissions

- **Apple Event Permission Denied (`-1743` / `errAEEventNotPermitted`):**  
  macOS requires authorization for applications to control Capture One. Go to **System Settings > Privacy & Security > Automation**, find your terminal app (Terminal, iTerm2, Cursor, Claude Desktop), and ensure **Capture One** is toggled ON.
- **Unsupported Version (`unsupported-version`):**  
  `c1` pins against tested Capture One builds (`16.8.5.30`). To run against another build at your own risk, set:
  ```bash
  export C1_ALLOW_UNTESTED_BUILD=1
  ```
- **Unresolved Operations:**  
  If a process crashes during a mutation, run `c1 operation status <operationId>` or check `.c1/journal.jsonl` in the Session directory.

---

## License

This project is licensed under the [MIT License](LICENSE).
