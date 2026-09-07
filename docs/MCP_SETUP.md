# Setting Up `c1-mcp` in AI Desktop Clients

This guide walks through configuring the `c1-mcp` (Capture One Model Context Protocol) server for:
1. **ChatGPT macOS App** (via integrated Codex mode)
2. **Claude Desktop App**
3. **Antigravity** (IDE, CLI, & Desktop App)

---

## 1. Prerequisites: Building `c1-mcp`

Before configuring any client, ensure `c1-mcp` is built on your Mac.

### Option A: Install system-wide (Recommended)
From the repository root:
```bash
make build
make install
```
Verify the binary:
```bash
which c1-mcp
# Expected: /usr/local/bin/c1-mcp
```

### Option B: Build with Swift Package Manager
```bash
swift build -c release --product c1-mcp
```
The binary will be located at:
```
/Users/kiri11/projects/c1cmd/.build/release/c1-mcp
```
*(Replace `/usr/local/bin/c1-mcp` in the configurations below with your local path if not installed system-wide).*

---

## 2. macOS Automation Permissions (Crucial)

`c1-mcp` controls Capture One via macOS Apple Events (`NSAppleScript`).

When an AI assistant executes its first Capture One tool call, macOS will prompt for automation permission on behalf of the host application:
> **"[Client App]" wants access to control "Capture One".**

* Click **OK / Allow**.
* If permission was previously denied or missed, navigate to:  
  **System Settings > Privacy & Security > Automation**  
  Find the client app (**ChatGPT**, **Claude**, or **Antigravity**) and ensure the checkbox for **Capture One** is turned **ON**.

---

## 3. ChatGPT macOS App (Codex Mode)

The unified ChatGPT macOS app includes a dedicated **Codex** workspace with native support for local `stdio` MCP servers.

> [!IMPORTANT]
> **Use the Codex Workspace:**  
> Ensure you run tool calls from the **Codex** workspace tab inside the ChatGPT app. The classic consumer "Chat" tab uses remote web connectors and will not invoke local `stdio` processes.

### Method A: Configure via Codex CLI
Run in your terminal:
```bash
codex mcp add capture-one -- /usr/local/bin/c1-mcp
```

### Method B: Manual Configuration (`config.toml`)
Add the server entry to your global Codex configuration file at `~/.codex/config.toml` (or `.codex/config.toml` at the repository root):

```toml
[mcp_servers.capture-one]
command = "/usr/local/bin/c1-mcp"
env = { "C1_ALLOW_UNTESTED_BUILD" = "1" }
```

### Verify
Verify the server is registered:
```bash
codex mcp list
```
When opening a project in the **Codex** tab of the ChatGPT desktop app, `capture-one` tools (`doctor`, `variants_list`, `variant_clone`, `get`, `set`, `preview`, etc.) will appear in the model's active tools.

---

## 4. Claude Desktop App

Claude Desktop supports local `stdio` MCP servers via its central JSON configuration.

### Configuration File
Open or create:
```
~/Library/Application Support/Claude/claude_desktop_config.json
```

### Configuration
Add `c1` under the `mcpServers` object:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/usr/local/bin/c1-mcp",
      "env": {
        "C1_ALLOW_UNTESTED_BUILD": "1"
      }
    }
  }
}
```

### Activation
1. Fully quit Claude Desktop (`Cmd + Q`).
2. Re-open Claude Desktop.
3. Look for the hammer / tool icon in the prompt input area to confirm the `c1` tools are loaded.
4. When prompted by macOS on the first tool call, grant permission for Claude to control Capture One.

---

## 5. Antigravity (IDE, CLI, & Desktop App)

Antigravity natively manages MCP servers through its `mcp_config.json` configuration.

### Configuration File
Open or create the global MCP configuration file at:
```
~/.gemini/config/mcp_config.json
```

### Configuration
Add the `c1` server to the `mcpServers` object:

```json
{
  "mcpServers": {
    "c1": {
      "command": "/usr/local/bin/c1-mcp",
      "args": [],
      "env": {
        "C1_ALLOW_UNTESTED_BUILD": "1"
      }
    }
  }
}
```

### Verify & Inspect
1. Start or restart your Antigravity session.
2. Discovered tools (`doctor`, `doc_info`, `variants_list`, `variant_clone`, `get`, `set`, `add`, `preview`, etc.) are automatically injected into the agent's context.
3. In the Antigravity UI, navigate to **Additional Options (...) > MCP Servers** to inspect connection status and available tool signatures.

---

## 6. Quick Verification Prompt

Once configured in any of the three clients, open a Session in Capture One and test the connection with this prompt:

> *"Run the Capture One health check tool (doctor) to confirm the session status and list available variants."*

Expected response:
- Confirms Capture One is running with an active `.cosessiondb` session document.
- Returns variant metadata without errors.
