const pending = new Map<string, string | null>();

export function setPending(agentId: string, text: string): void {
  pending.set(agentId, text);
}

export function consumePending(agentId: string): string | null {
  const msg = pending.get(agentId) ?? null;
  pending.set(agentId, null);
  return msg;
}

export function hasPending(agentId: string): boolean {
  return !!pending.get(agentId);
}

export function clear(agentId: string): void {
  pending.delete(agentId);
}
