import { AgentState } from './types';

const registry = new Map<string, AgentState>();

export function create(agentId: string, state: Omit<AgentState, 'containerReady'> & { containerReady?: boolean }): AgentState {
  const full: AgentState = { containerReady: false, ...state } as AgentState;
  registry.set(agentId, full);
  return full;
}

export function get(agentId: string): AgentState | undefined {
  return registry.get(agentId);
}

export function getAll(): AgentState[] {
  return Array.from(registry.values());
}

export function update(agentId: string, patch: Partial<AgentState>): AgentState {
  const existing = registry.get(agentId);
  if (!existing) throw new Error(`Agent ${agentId} not found`);
  Object.assign(existing, patch);
  return existing;
}

export function remove(agentId: string): void {
  registry.delete(agentId);
}

export function has(agentId: string): boolean {
  return registry.has(agentId);
}
