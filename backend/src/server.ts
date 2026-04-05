import 'dotenv/config';
import http from 'http';
import express from 'express';
import { WebSocketServer } from 'ws';
import cors from 'cors';
import * as wsHub from './lib/wsHub';
import * as appConfig from './lib/config';
import agentsRouter from './routes/agents';
import recordingsRouter from './routes/recordings';
import { cleanupStale } from './lib/dockerManager';

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT ? parseInt(process.env.PORT) : 3001;

app.use(cors());
app.use(express.json());

app.use('/agents', agentsRouter);
app.use('/recordings', recordingsRouter);

app.get('/health', (_req, res) => res.json({ ok: true }));

app.post('/config', (req, res) => {
  const { apiKey } = req.body as { apiKey?: string };
  if (!apiKey || typeof apiKey !== 'string') {
    return res.status(400).json({ error: '"apiKey" is required' });
  }
  appConfig.setApiKey(apiKey);
  console.log('[config] API key set');
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
