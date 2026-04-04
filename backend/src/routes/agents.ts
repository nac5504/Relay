import { Router, Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import * as registry from '../lib/agentRegistry';
import * as docker from '../lib/dockerManager';
import * as claudeLoop from '../lib/claudeLoop';
import * as messageQueue from '../lib/messageQueue';
import * as wsHub from '../lib/wsHub';
import { AgentState } from '../lib/types';

const router = Router();

type AgentSummary = Omit<AgentState, 'messages' | 'recordingProc'>;

function summarize(agent: AgentState): AgentSummary {
  const { messages: _m, recordingProc: _r, ...rest } = agent;
  return rest;
}

// GET /agents
router.get('/', (_req: Request, res: Response) => {
  res.json(registry.getAll().map(summarize));
});

// GET /agents/:id
router.get('/:id', (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });
  res.json(summarize(agent));
});

// GET /agents/:id/history
router.get('/:id/history', (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });

  const messages = agent.messages.flatMap((m) =>
    Array.isArray(m.content)
      ? m.content
          .filter((b) => b.type === 'text' && 'text' in b && b.text.trim())
          .map((b) => ({ role: m.role, text: (b as { text: string }).text, timestamp: new Date().toISOString() }))
      : [],
  );
  res.json(messages);
});

// POST /agents
router.post('/', async (req: Request, res: Response) => {
  const { task, agentName } = req.body as { task?: string; agentName?: string };
  if (!task) return res.status(400).json({ error: '"task" is required' });

  const agentId = uuidv4();
  const sessionId = uuidv4();
  const name = agentName ?? generateName();

  const agent = registry.create(agentId, {
    id: agentId,
    agentName: name,
    task,
    status: 'starting',
    containerName: null,
    noVNCPort: null,
    vncPort: null,
    sessionId,
    cost: 0,
    waitingForInput: false,
    startedAt: Date.now(),
    messages: [],
    recordingProc: null,
    error: null,
  });

  wsHub.broadcast({ type: 'agent_added', agent: summarize(agent) });
  res.status(201).json(summarize(agent));

  setImmediate(async () => {
    try {
      const { containerName, noVNCPort, vncPort } = await docker.startContainer(agentId, sessionId);
      registry.update(agentId, { containerName, noVNCPort, vncPort });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'starting', noVNCPort, vncPort });

      await docker.waitForReady(noVNCPort);
      registry.update(agentId, { status: 'working' });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', noVNCPort, vncPort });

      await claudeLoop.runAgentLoop(agentId);
    } catch (err) {
      console.error(`Failed to start agent ${agentId}:`, err);
      registry.update(agentId, { status: 'error', error: (err as Error).message });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'error' });
    }
  });
});

// DELETE /agents/:id
router.delete('/:id', async (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });

  registry.update(req.params.id, { status: 'stopped' });
  messageQueue.clear(req.params.id);

  if (agent.containerName) {
    await docker.stopContainer(agent.containerName, agent.noVNCPort);
  }

  registry.remove(req.params.id);
  wsHub.broadcast({ type: 'agent_removed', agentId: req.params.id });
  res.status(204).send();
});

// POST /agents/:id/message
router.post('/:id/message', (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });

  const { text } = req.body as { text?: string };
  if (!text) return res.status(400).json({ error: '"text" is required' });

  messageQueue.setPending(req.params.id, text);

  if (agent.status === 'waiting') {
    registry.update(req.params.id, { status: 'working', waitingForInput: false });
    wsHub.broadcast({ type: 'agent_update', agentId: req.params.id, status: 'working', cost: agent.cost });
  }

  wsHub.broadcast({ type: 'chat_message', agentId: req.params.id, role: 'user', text, timestamp: new Date().toISOString() });
  res.status(204).send();
});

const NAME_POOL = ['Atlas', 'Nova', 'Sage', 'Echo', 'Pixel', 'Bolt', 'Onyx', 'Flux', 'Haze', 'Iris'];
let nameIdx = 0;
function generateName(): string {
  return NAME_POOL[nameIdx++ % NAME_POOL.length];
}

export default router;
