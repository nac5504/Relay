require('dotenv').config();

const express = require('express');
const http = require('http');
const { execSync } = require('child_process');
const configRoutes = require('./routes/config');
const agentRoutes = require('./routes/agents');
const docker = require('./lib/dockerManager');
const registry = require('./lib/agentRegistry');

const PORT = process.env.PORT || 3001;

const app = express();
app.use(express.json());

app.use('/config', configRoutes);
app.use('/agents', agentRoutes);
app.get('/health', (req, res) => res.json({ ok: true }));

const server = http.createServer(app);

// --- Startup: kill stale backend, nuke all containers, start clean ---
try {
  const pids = execSync(`lsof -ti:${PORT}`, { encoding: 'utf8' }).trim();
  for (const pid of pids.split('\n').filter(Boolean)) {
    if (pid !== String(process.pid)) {
      try { process.kill(Number(pid), 'SIGTERM'); } catch {}
    }
  }
  execSync('sleep 0.5');
} catch {}

docker.cleanupAll().then(() => {
  registry.clear();
  server.listen(PORT, () => {
    console.log(`Relay backend listening on http://localhost:${PORT}`);
  });
});

// --- Shutdown: nuke all containers, exit ---
function shutdown() {
  console.log('Shutting down — removing all containers...');
  docker.cleanupAll()
    .then(() => { server.close(); process.exit(0); })
    .catch(() => { process.exit(0); });
  setTimeout(() => process.exit(0), 3000);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

module.exports = { app, server };
