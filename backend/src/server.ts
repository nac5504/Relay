import 'dotenv/config';
import http from 'http';
import express from 'express';
import { WebSocketServer } from 'ws';
import cors from 'cors';
import * as wsHub from './lib/wsHub';
import * as appConfig from './lib/config';
import agentsRouter from './routes/agents';
import recordingsRouter from './routes/recordings';
import dockerRouter from './routes/docker';
import { cleanupStale } from './lib/dockerManager';
import * as warmPool from './lib/warmPool';

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT ? parseInt(process.env.PORT) : 3001;

app.use(cors());
app.use(express.json());

app.use('/agents', agentsRouter);
app.use('/recordings', recordingsRouter);
app.use('/docker', dockerRouter);

app.get('/health', (_req, res) => res.json({ ok: true }));

// List available Chrome profiles from macOS
app.get('/chrome-profiles', async (_req, res) => {
  const { detectProfiles } = await import('./lib/chromeProfileSync');
  const profiles = await detectProfiles();
  res.json(profiles);
});

app.post('/config', (req, res) => {
  const { apiKey } = req.body as { apiKey?: string };
  if (!apiKey || typeof apiKey !== 'string') {
    return res.status(400).json({ error: '"apiKey" is required' });
  }
  appConfig.setApiKey(apiKey);
  console.log('[config] API key set');
  warmPool.initWarmPool(); // fire-and-forget: boots warm container in background
  res.json({ ok: true });
});

wss.on('connection', (ws) => {
  wsHub.addClient(ws);
  ws.send(JSON.stringify({ type: 'connected' }));
});

server.listen(PORT, () => {
  console.log(`Relay backend listening on http://localhost:${PORT}`);
  cleanupStale().then(() => console.log('[startup] Stale containers cleaned up'));
});

// Graceful shutdown — drain warm pool
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, async () => {
    console.log(`[shutdown] Received ${sig}, draining warm pool...`);
    await warmPool.drainPool();
    process.exit(0);
  });
}
