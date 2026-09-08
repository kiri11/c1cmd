# MCP setup

Build and install from the repository root:

```sh
make install
command -v c1-mcp
```

Use the returned absolute executable path in your MCP client's stdio server configuration:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/absolute/path/to/bin/c1-mcp"
    }
  }
}
```

Client configuration-file locations differ; use the client's current documentation. No network server, API key, or listening port is required. Diagnostics go to stderr; stdout is reserved for the MCP transport.

Keep `c1_CaptureOneCore.bundle` beside both executables. `make install` and the release archive include it. A binary copied alone may work in the source checkout but is not a complete installation.

Launch Capture One at `/Applications/Capture One.app`, open one Session, and call `doctor`, `doc_info`, and `variants_list`. Check `isSession` and `exactBuildMatched` before editing. A healthy Catalog supports inspection only.

If macOS reports `permission-denied`, allow the launching client to control Capture One in **System Settings → Privacy & Security → Automation**. Ad-hoc signed release executables are not Developer ID notarized; source builds remain an alternative if your machine's policy blocks them.

Use a single sequential workflow. Keep the Session open and avoid UI edits, document switching, and competing exports during calls. Restarting Capture One invalidates existing working references. Read the [support and recovery boundary](../README.md) before automated grading.

`schema` exposes the same contract as `c1 schema`; `tools/list` uses its request schemas. `preview` writes a dedicated recipe/output and returns both JSON metadata and JPEG content. Uncertain failures include `operationId`; inspect `operation_status` instead of retrying.
