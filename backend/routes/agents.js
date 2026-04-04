const express = require('express');
const net = require('net');
const registry = require('../lib/agentRegistry');
const docker = require('../lib/dockerManager');

const router = express.Router();

router.get('/', (_req, res) => {
  res.json(registry.list());
});

router.post('/', async (req, res) => {
  const { task, agentName } = req.body;

  try {
    await docker.ensureImage();

    const agent = registry.create({ task, agentName });

    // Start container, wait for it, launch browser — all before responding
    const apiKey = process.env.ANTHROPIC_API_KEY || '';
    const { containerId } = await docker.startContainer({
      agentId: agent.id,
      noVNCPort: agent.noVNCPort,
      vncPort: agent.vncPort,
      apiKey,
    });

    registry.update(agent.id, { containerId, status: 'running' });

    await waitForPort(agent.noVNCPort, 30);
    await docker.launchBrowser(agent.containerName);

    console.log(`Agent ${agent.agentName} (${agent.id}) running on port ${agent.noVNCPort}`);
    res.status(201).json(registry.get(agent.id));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.get('/:id', (req, res) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  res.json(agent);
});

router.delete('/:id', async (req, res) => {
  const agent = registry.get(req.params.id);
  if (!agent) return res.status(404).json({ error: 'Agent not found' });
  await docker.stopContainer(agent.containerName).catch(() => {});
  registry.remove(agent.id);
  res.json({ ok: true });
});

function waitForPort(port, timeoutSec) {
  const deadline = Date.now() + timeoutSec * 1000;
  return new Promise((resolve, reject) => {
    const tryConnect = () => {
      if (Date.now() > deadline) return reject(new Error(`Timeout waiting for port ${port}`));
      const sock = new net.Socket();
      sock.setTimeout(1000);
      sock.on('connect', () => { sock.destroy(); resolve(); });
      sock.on('error', () => { sock.destroy(); setTimeout(tryConnect, 500); });
      sock.on('timeout', () => { sock.destroy(); setTimeout(tryConnect, 500); });
      sock.connect(port, '127.0.0.1');
    };
    tryConnect();
  });
}

module.exports = router;
