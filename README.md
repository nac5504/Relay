# Relay — Computer Use Agent Manager

## Context

"Relay" is a macOS Swift app being extended into a computer use agent management dashboard — "Conductor for computer use". Instead of managing browser tabs, each agent session runs a Claude Computer Use loop inside a Docker container. The macOS app shows a live noVNC stream of the agent's desktop alongside a chat history, and stores recordings with tagged action timelines for replay.

The existing codebase already has: Docker container management (via shell), noVNC WebKit streaming, port allocation, and a SwiftUI grid layout. The rewrite replaces direct Swift↔Docker interaction with a Node.js backend that owns the Claude API loop, recording, and WebSocket broadcasting.

**Demo goal**: 3 agents showing (1) live working agent you can message, (2) agent paused waiting for human input, (3) completed agent with annotated recording playback.

---

## Architecture

```
[Swift macOS App (Relay)]
    ↕  HTTP REST + WebSocket (ws://localhost:3001)
[Node.js Backend]
    ↕  docker CLI shell commands
[Docker Containers — 1 per agent]
    ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest
    - Xvfb display :1
    - noVNC on port 6080 (mapped to host)
    - VNC on port 5900 (mapped to host)
    - Chrome, LibreOffice, xdotool, ffmpeg
```

---

## Phase 1: Node.js Backend (`backend/`)

### Directory structure
```
backend/
├── package.json                  # express, ws, @anthropic-ai/sdk, uuid, dotenv
├── .env.example                  # ANTHROPIC_API_KEY, RECORDINGS_DIR
├── server.js                     # Express + WebSocket server on :3001
├── lib/
│   ├── agentRegistry.js          # Map<agentId, AgentState>
│   ├── dockerManager.js          # start/stop/exec container shell helpers
│   ├── claudeLoop.js             # Claude Computer Use agent loop
│   ├── recordingManager.js       # ffmpeg spawn + timeline JSON
│   ├── messageQueue.js           # per-agent pending user message
│   └── wsHub.js                  # WebSocket broadcast to all Swift clients
└── routes/
    ├── agents.js                 # GET/POST/DELETE /agents, POST /agents/:id/message
    └── recordings.js             # GET /recordings/:sessionId/video + /timeline
```

### AgentState shape (`agentRegistry.js`)
```js
{
  id, containerName, status,      // 'starting'|'running'|'waiting'|'completed'|'error'
  task, noVNCPort, vncPort,
  conversationHistory: [],        // Anthropic messages array
  pendingMessage: null,           // set by POST /agents/:id/message
  waitingForInput: false,
  sessionId, startedAt, cost,
  recordingProc: null,            // ffmpeg child process
}
```

### Claude loop flow (`claudeLoop.js`)
1. Check `consumePending(agentId)` — if message exists, inject as user turn
2. If `waitingForInput && !pendingMessage` → sleep 500ms, repeat
3. Take screenshot: `docker exec {name} bash -c "DISPLAY=:1 scrot -z /tmp/ss.png && base64 /tmp/ss.png"`
   Fallback if no scrot: `import -window root /tmp/ss.png` (ImageMagick)
4. Call `anthropic.messages.create` with `computer_20251124` tool + beta header `computer-use-2025-11-24`
5. Parse response:
   - `stop_reason == 'tool_use'` → execute computer actions, log to timeline, loop
   - `stop_reason == 'end_turn'` + text contains "waiting for" → set `waitingForInput=true`, broadcast
   - `stop_reason == 'end_turn'` otherwise → set `status='completed'`, save timeline, stop recording
6. Execute computer actions via `xdotool` inside container:
   - `left_click` (x,y) → `xdotool mousemove x y click 1`
   - `type` text → `xdotool type --clearmodifiers "text"`
   - `key` name → `xdotool key name`
   - `mouse_move` → `xdotool mousemove x y`
7. Log each action to `recordingManager.logAction(sessionId, event)`
8. Broadcast via wsHub: `{type:'action', agentId, event}`, `{type:'agent_update', agentId, status, cost}`

### Recording (`recordingManager.js`)
- **Start**: `docker exec {name} ffmpeg -f x11grab -r 10 -video_size 1024x768 -i :1 -c:v libx264 -preset ultrafast -crf 28 -y /recordings/{sessionId}.mp4`
- **Stop**: send SIGINT to ffmpeg process, then `docker cp {name}:/recordings/{sessionId}.mp4 {outputDir}/`
- **Timeline**: append `{id, timestamp_ms, action_type, description, coordinates}` to in-memory array; write JSON to disk on completion

### REST API (`routes/agents.js`)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/agents` | list all agent summaries |
| POST | `/agents` | `{task}` → start container + Claude loop, return AgentState |
| DELETE | `/agents/:id` | stop loop + container |
| POST | `/agents/:id/message` | `{text}` → queue user message |
| GET | `/recordings/:id/video` | serve MP4 |
| GET | `/recordings/:id/timeline` | serve `[ActionEvent]` JSON |

### WebSocket messages (server → Swift)
```js
{ type: 'agent_update',  agentId, status, cost }
{ type: 'action',        agentId, event: ActionEvent }
{ type: 'chat_message',  agentId, role, text, timestamp }
{ type: 'agent_added',   agent: AgentSummary }
{ type: 'agent_removed', agentId }
```

### Docker container launch (note: anthropic image uses port **6080** for noVNC, not 7900)
```bash
docker run -d
  -p {noVNCPort}:6080
  -p {vncPort}:5900
  -v {recordingsDir}:/recordings
  -e ANTHROPIC_API_KEY={key}
  --name {containerName}
  ghcr.io/anthropics/anthropic-quickstarts:computer-use-demo-latest
```

---

## Phase 2: Swift Model + Service Layer

### Modified: `Relay/Models/BrowserAgent.swift`
Add to existing model:
```swift
var task: String = ""
var relayStatus: RelayAgentStatus = .notStarted
var chatMessages: [ChatMessage] = []
var actionLog: [ActionEvent] = []
var cost: Double = 0.0
var sessionId: String = ""
var waitingForInput: Bool = false

enum RelayAgentStatus: String, Codable {
    case notStarted, starting, working, waiting, completed, error, stopped
    var dotColor: Color { /* green/orange/yellow/gray/red */ }
}
struct ChatMessage: Identifiable, Codable { id, role, text, timestamp }
struct ActionEvent: Identifiable, Codable  { id, timestampMs, actionType, description, coordinates? }
```

### New: `Relay/Services/AgentStore.swift`
`@Observable` class replacing `BrowserManager` as the Swift state source of truth:
```swift
actor AgentStore {
    static let shared = AgentStore()
    var agents: [BrowserAgent] = []
    func load() async          // GET /agents on launch
    func createAgent(task: String) async throws
    func deleteAgent(_ agent: BrowserAgent) async throws
    func sendMessage(to agent: BrowserAgent, text: String) async throws
}
```

### New: `Relay/Services/APIService.swift`
HTTP client using `URLSession` async/await:
```swift
actor APIService {
    let baseURL = URL(string: "http://localhost:3001")!
    func fetchAgents() async throws -> [BrowserAgent]
    func createAgent(task: String) async throws -> BrowserAgent
    func deleteAgent(id: UUID) async throws
    func sendMessage(agentId: UUID, text: String) async throws
    func fetchTimeline(sessionId: String) async throws -> [ActionEvent]
    func recordingURL(sessionId: String) -> URL
}
```

### New: `Relay/Services/WebSocketManager.swift`
`@Observable` class with persistent WS connection to `ws://localhost:3001`:
- Recursive `receive()` loop decoding JSON by `type` field
- Routes to `AgentStore` mutations: update status, append chat/action, add/remove agents
- Auto-reconnect with exponential backoff (1s→2s→4s→30s max)

---

## Phase 3: Swift View Redesign

### Hierarchy
```
RelayApp.swift
└── ContentView.swift  (NavigationSplitView: sidebar + detail)
    ├── SidebarView.swift          NEW — 220px dark sidebar
    └── Detail pane (by state):
        ├── HomeView.swift         NEW — LazyVGrid of AgentCardView
        ├── AgentDetailView.swift  NEW — noVNC stream + chat panel
        └── PlaybackView.swift     NEW — AVPlayer + timeline scrubber
```

### `ContentView.swift` — rewrite as `NavigationSplitView`
- `@State var selectedAgentId: UUID?` controls which view shows in detail pane
- `minWidth: 1100, minHeight: 700`

### `SidebarView.swift` (NEW)
- Logo + "Relay" name
- "Home" nav item (deselects agent)
- Per-agent rows: status dot + truncated task name + chevron
- "New Task" button → sheet with `TextField` for task prompt

### `HomeView.swift` (NEW)
- `LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))])`
- `AgentCardView`: thumbnail (last screenshot or placeholder), status dot, task text, cost badge

### `AgentDetailView.swift` (NEW)
- `HSplitView`: left = `BrowserStreamView` (reused as-is, update noVNC URL port to 6080), right = chat panel (320px)
- Chat panel: `ScrollView` of `ChatBubbleView` + `TextField` + Send button
- Status banner: "Working...", "Waiting for your input", "Completed ✓"
- Send button calls `AgentStore.shared.sendMessage(to: agent, text:)`

### `PlaybackView.swift` (NEW)
- `AVPlayer` loading `APIService.recordingURL(sessionId:)`
- `TimelineScrubberView`: horizontal bar with tick marks at each `ActionEvent.timestampMs`, colored by action type
- Tapping tick seeks `AVPlayer` to that timestamp
- Scrollable `ActionEventRow` list below scrubber

### Retire / simplify
- `BrowserGridView.swift` → replaced by `HomeView`
- `BrowserTileView.swift` → replaced by `AgentCardView`
- `BrowserManager.swift` → replaced by `AgentStore` + `APIService` (keep only if needed for Docker path detection)

---

## Phase 4: Demo Setup

### Demo Agent 1 — Working (live)
**Task**: "Go to Wikipedia, search for 'artificial intelligence', copy the intro paragraph, open LibreOffice Writer, paste it with a title 'AI Summary', and save as /home/user/summary.odt"
- Start 2-3 min before demo so it's mid-task
- Audience sends "Make the title bold" → agent pauses, reads, adjusts

### Demo Agent 2 — Waiting for input
**Task**: "Search Wikipedia for 'Eiffel Tower', collect key facts, then STOP and ask me what spreadsheet format I want before creating it."
- `waitingForInput` prompt in the system message ensures Claude pauses at that point
- Sidebar dot shows orange; chat shows Claude's question

### Demo Agent 3 — Completed (pre-recorded)
**Task**: Pre-record "Search for 'best python libraries 2024', summarize top 5 into LibreOffice Calc with Library/Description/Use Case columns"
- Run before demo; MP4 + timeline JSON stored in `backend/recordings/`
- Seed script `backend/scripts/seedCompletedAgent.js` inserts a completed AgentState pointing to the recording

---

## Implementation Order (Hackathon)

1. **Backend skeleton** — `server.js`, `dockerManager.js`, `agentRegistry.js`, `routes/agents.js` → verify `curl` works
2. **Claude loop** — `claudeLoop.js`, screenshot+action execution, `messageQueue.js`
3. **Recording** — `recordingManager.js`, timeline JSON, `routes/recordings.js`
4. **Swift services** — `AgentStore`, `APIService`, `WebSocketManager`, update `BrowserAgent`
5. **Swift views** — `ContentView` (NavigationSplitView), `SidebarView`, `HomeView`, `AgentDetailView`
6. **Playback** — `PlaybackView` with `AVPlayer` + `TimelineScrubberView`
7. **Demo prep** — seed agents, rehearsal

---

## Critical Files

- `Relay/Relay/Models/BrowserAgent.swift` — extend with new fields/types
- `Relay/Relay/ContentView.swift` — rewrite as NavigationSplitView
- `Relay/Relay/Views/BrowserStreamView.swift` — update noVNC port from 7900 → 6080
- `Relay/Relay/Services/BrowserManager.swift` — retire/hollow out
- `backend/lib/claudeLoop.js` — new, core logic
- `backend/lib/dockerManager.js` — new, replaces Swift Docker code

## Verification

1. `cd backend && node server.js` — server starts on :3001
2. `curl -X POST localhost:3001/agents -d '{"task":"take a screenshot"}' -H 'Content-Type: application/json'` → returns agent JSON
3. Container appears in `docker ps`, noVNC loads at `http://localhost:{noVNCPort}/vnc.html`
4. Swift app launches, shows sidebar, connects WebSocket, agent status updates propagate to UI
5. Chat message sent from Swift → appears in agent loop → Claude adjusts action
6. On completion: `curl localhost:3001/recordings/{sessionId}/timeline` returns action events
7. PlaybackView in Swift loads video + timeline markers, seeking works
