import { ChildProcess } from 'child_process';

export type AgentStatus =
  | 'starting'
  | 'working'
  | 'waiting'
  | 'completed'
  | 'error'
  | 'stopped';

export interface ActionEvent {
  id: string;
  timestampMs: number;
  actionType: string;
  description: string;
  coordinates: { x: number; y: number } | null;
}

export interface AgentState {
  id: string;
  agentName: string;
  task: string;
  status: AgentStatus;
  containerName: string | null;
  noVNCPort: number | null;
  vncPort: number | null;
  sessionId: string;
  cost: number;
  waitingForInput: boolean;
  startedAt: number; // Date.now()
  messages: AnthropicMessage[];
  recordingProc: ChildProcess | null;
  error: string | null;
}

// Minimal shape of Anthropic message used in conversation history
export interface AnthropicMessage {
  role: 'user' | 'assistant';
  content: AnthropicContentBlock[];
}

export type AnthropicContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: { type: 'base64'; media_type: 'image/png'; data: string } }
  | { type: 'tool_use'; id: string; name: string; input: ComputerToolInput }
  | { type: 'tool_result'; tool_use_id: string; content: AnthropicContentBlock[] };

export interface ComputerToolInput {
  action: string;
  coordinate?: [number, number];
  startCoordinate?: [number, number];
  text?: string;
  key?: string;
  scroll_direction?: 'up' | 'down' | 'left' | 'right';
  scroll_amount?: number;
  duration?: number;
}
