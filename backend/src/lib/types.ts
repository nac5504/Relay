import { ChildProcess } from 'child_process';

export type AgentStatus =
  | 'starting'   // container booting, plan agent active
  | 'planning'   // container ready, plan agent still talking
  | 'working'    // computer use loop running
  | 'waiting'    // Claude asked for user input
  | 'completed'
  | 'error'
  | 'stopped';

export type PlanStepStatus = 'pending' | 'active' | 'completed' | 'failed';

export interface PlanStep {
  stepNumber: number;           // 1-indexed
  shortDescription: string;     // One sentence for UI display
  detailedInstructions: string; // Full instructions for execution agent
  suggestedTools: string[];     // e.g. ["bash", "computer", "text_editor"]
  status: PlanStepStatus;
}

export interface StructuredPlan {
  version: number;              // Incremented on each revision
  mode: 'bash_only' | 'computer_use';
  steps: PlanStep[];
}

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
  containerReady: boolean;
  startedAt: number;
  messages: AnthropicMessage[];
  recordingProc: ChildProcess | null;
  error: string | null;
  plan?: StructuredPlan;
}

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
