## 0.1.1

**Fixes (audit):**
- Client output (`LogCollectorOutput`): the re-buffer path on send failure now enforces `bufferSize` (was unbounded), and the flush is serialized -- a record is removed from the buffer only after its send succeeds, preserving order and preventing loss/reordering on reconnect.
- Server handshake is now idempotent per connection: a duplicate handshake no longer leaks the previous session or emits a spurious `DeviceConnected`.
- MCP server: a malformed/non-object JSON body now returns a JSON-RPC `-32700` parse-error envelope (HTTP 200) instead of an HTTP 500 with a stack trace.
- `mcp_buffer`: a stale cursor (older than the eviction horizon) is now signalled with a reset warning instead of silently returning the whole buffer; eviction uses a `ListQueue` for O(1) removal.

**Security:**
- The collector and MCP servers now bind `127.0.0.1` by default (was `0.0.0.0`); use `--bind-all` to opt into binding all interfaces.
- The MCP OAuth `authorize` endpoint now allowlists loopback `redirect_uri` targets only (rejecting open-redirect attempts) and issues a random per-request token instead of a static one. The flow remains dev-only/unauthenticated.

## 0.1.0

- Initial release: real-time remote log collector over WebSocket (`LogCollectorOutput` client, `LogCollectorServer` + `LogCollectorConsole`), and `LogCollectorMcpServer` for Claude Code integration.
