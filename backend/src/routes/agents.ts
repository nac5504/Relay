import { Router, Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import * as registry from '../lib/agentRegistry';
import * as docker from '../lib/dockerManager';
import * as claudeLoop from '../lib/claudeLoop';
import * as bashLoop from '../lib/bashLoop';
import * as planAgent from '../lib/planAgent';
import * as messageQueue from '../lib/messageQueue';
import * as recordingManager from '../lib/recordingManager';
import * as wsHub from '../lib/wsHub';
import * as warmPool from '../lib/warmPool';
import { AgentState } from '../lib/types';
import { getApiKey, hasApiKey } from '../lib/config';
import * as chromeSync from '../lib/chromeProfileSync';

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
  if (!hasApiKey()) return res.status(400).json({ error: 'API key not set. POST /config first.' });

  const { task, agentName, chromeProfile: reqProfile } = req.body as { task?: string; agentName?: string; chromeProfile?: string };
  const chromeProfile = reqProfile ?? 'Profile 1'; // default to usc.edu profile
  if (!task) return res.status(400).json({ error: '"task" is required' });

  const agentId = uuidv4();
  const sessionId = uuidv4();
  const name = agentName ?? generateName();

  const agent = registry.create(agentId, {
    id: agentId,
    agentName: name,
    task: task ?? '',
    status: 'starting',
    containerName: null,
    noVNCPort: null,
    vncPort: null,
    sessionId,
    cost: 0,
    waitingForInput: false,
    containerReady: false,
    startedAt: Date.now(),
    messages: [],
    recordingProc: null,
    error: null,
  });

  console.log(`[agents] Created agent ${agentId} (${name}) — task: "${(task ?? '').slice(0, 60) || '(awaiting)'}"`);
  wsHub.broadcast({ type: 'agent_added', agent: summarize(agent) });
  res.status(201).json(summarize(agent));

  setImmediate(async () => {
    let containerAssigned = false;

    // 1. Try warm pool for instant container assignment
    const warm = warmPool.acquire();
    if (warm) {
      try {
        const newName = `relay-agent-${agentId.replace(/-/g, '').slice(0, 12)}`;
        await docker.dockerRun(['rename', warm.containerName, newName]);
        console.log(`[agents] Using warm container ${warm.containerName} → ${newName} (instant)`);

        registry.update(agentId, { containerName: newName, noVNCPort: warm.noVNCPort, vncPort: warm.vncPort });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'starting', cost: 0 });

        const recordingProc = recordingManager.startRecording(newName, sessionId);
        registry.update(agentId, { containerReady: true, status: 'planning', recordingProc });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'planning', noVNCPort: warm.noVNCPort, vncPort: warm.vncPort, cost: 0 });
        containerAssigned = true;
      } catch (err) {
        console.warn(`[agents] Warm container assign failed, falling back to cold boot:`, (err as Error).message);
      }
    }

    // 2. Start plan agent (works for both warm and cold paths)
    console.log(`[agents] Starting plan agent for ${agentId}`);
    planAgent.runPlanAgent(agentId, async (_finalPlan: string, mode: 'bash_only' | 'computer_use') => {
      console.log(`[agents] Plan complete for ${agentId} (mode: ${mode}) — waiting for container`);
      await waitForContainerReady(agentId);
      const current = registry.get(agentId);
      if (!current || current.status === 'stopped') return;
      console.log(`[agents] Starting ${mode} loop for ${agentId}`);
      registry.update(agentId, { status: 'working' });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: 0 });

      const loopFn = mode === 'bash_only' ? bashLoop.runBashLoop : claudeLoop.runAgentLoop;
      loopFn(agentId).catch((err) => {
        console.error(`[agents] Loop error for ${agentId}:`, err);
      });
    }).catch((err) => {
      console.error(`[agents] Plan agent error for ${agentId}:`, err);
    });

    // 3. Cold boot fallback if no warm container was available
    if (!containerAssigned) {
      try {
        // Sync Chrome profile if requested
      let chromeProfilePath: string | undefined;
      if (chromeProfile) {
        try {
          console.log(`[agents] Syncing Chrome profile "${chromeProfile}" for ${agentId}`);
          chromeProfilePath = await chromeSync.syncProfile(chromeProfile, agentId);
        } catch (err) {
          console.warn(`[agents] Chrome profile sync failed: ${(err as Error).message}`);
        }
      }

      console.log(`[agents] Starting container for ${agentId} (cold boot)`);
        const { containerName, noVNCPort, vncPort } = await docker.startContainer(agentId, sessionId, chromeProfilePath);
        console.log(`[agents] Container ${containerName} started — noVNC:${noVNCPort} VNC:${vncPort}`);
        registry.update(agentId, { containerName, noVNCPort, vncPort });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'starting', cost: 0 });

        console.log(`[agents] Waiting for container ready on port ${noVNCPort}...`);
        await docker.waitForReady(noVNCPort);
        console.log(`[agents] Container ready for ${agentId}`);

        // Set desktop wallpaper via pcmanfm (creates a DESKTOP-type window above mutter's background)
        docker.execInContainer(containerName,
          'DISPLAY=:1 pcmanfm --desktop --profile default & sleep 2 && DISPLAY=:1 pcmanfm --set-wallpaper /usr/share/wallpaper.jpg --wallpaper-mode=stretch',
          15_000
        ).catch((e) => console.warn(`[agents] Wallpaper set failed: ${(e as Error).message}`));

        // Start recording now that container is ready
        const recordingProc = recordingManager.startRecording(containerName, sessionId);
        registry.update(agentId, { containerReady: true, status: 'planning', recordingProc });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'planning', noVNCPort, vncPort, cost: 0 });
      } catch (err) {
        console.error(`[agents] Container start failed for ${agentId}:`, err);
        registry.update(agentId, { status: 'error', error: (err as Error).message });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'error', error: (err as Error).message });
      }
    }
  });
});

async function waitForContainerReady(agentId: string, timeoutMs = 120_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const agent = registry.get(agentId);
    if (!agent || agent.status === 'stopped') return;
    if (agent.containerReady) return;
    await new Promise<void>((r) => setTimeout(r, 500));
  }
  console.warn(`[agents] Container for ${agentId} not ready after ${timeoutMs}ms — proceeding anyway`);
}

// DELETE /agents/:id
router.delete('/:id', async (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });

  planAgent.cancelPlanAgent(req.params.id);
  registry.update(req.params.id, { status: 'stopped' });
  messageQueue.clear(req.params.id);

  if (agent.containerName) {
    await docker.stopContainer(agent.containerName, agent.noVNCPort);
  }

  registry.remove(req.params.id);
  wsHub.broadcast({ type: 'agent_removed', agentId: req.params.id });
  res.status(204).send();
});

// POST /agents/:id/message — routes to plan agent or computer use agent based on status
router.post('/:id/message', (req: Request, res: Response) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Not found' });

  const { text } = req.body as { text?: string };
  if (!text) return res.status(400).json({ error: '"text" is required' });

  console.log(`[agents] Message for ${req.params.id} (status: ${agent.status}): "${text.slice(0, 60)}"`);

  if (agent.status === 'completed' || agent.status === 'stopped' || agent.status === 'error') {
    console.log(`[agents] Agent is ${agent.status} — message ignored`);
    return res.status(400).json({ error: `Agent is ${agent.status}` });
  }

  if (agent.status === 'starting' || agent.status === 'planning') {
    // Route to plan agent
    console.log(`[agents] Routing to plan agent`);
    planAgent.injectPlanMessage(req.params.id, text);
  } else {
    // Route to computer use agent
    messageQueue.setPending(req.params.id, text);
    if (agent.status === 'waiting') {
      registry.update(req.params.id, { status: 'working', waitingForInput: false });
      wsHub.broadcast({ type: 'agent_update', agentId: req.params.id, status: 'working', cost: agent.cost });
    }
    wsHub.broadcast({ type: 'chat_message', agentId: req.params.id, role: 'user', text, timestamp: new Date().toISOString() });
  }

  res.status(204).send();
});

const NAME_POOL = ['Atlas', 'Nova', 'Sage', 'Echo', 'Pixel', 'Bolt', 'Onyx', 'Flux', 'Haze', 'Iris'];
let nameIdx = 0;
function generateName(): string {
  return NAME_POOL[nameIdx++ % NAME_POOL.length];
}

export default router;
