const { v4: uuidv4 } = require('uuid');

const agents = new Map();

// Simple sequential port assignment — starts fresh every launch
let nextPort = 17900;
const PORT_SPACING = 10;

function create({ task, agentName }) {
  const id = uuidv4().slice(0, 8);
  const noVNCPort = nextPort;
  const vncPort = nextPort + 1;
  nextPort += PORT_SPACING;

  const agent = {
    id,
    agentName: agentName || 'Agent',
    task: task || '',
    status: 'starting',
    noVNCPort,
    vncPort,
    containerName: `relay-agent-${id}`,
    containerId: null,
    cost: 0,
    startedAt: new Date().toISOString(),
    sessionId: uuidv4(),
    error: null,
  };

  agents.set(id, agent);
  return agent;
}

function get(id) { return agents.get(id) || null; }
function list() { return Array.from(agents.values()); }
function update(id, fields) {
  const agent = agents.get(id);
  if (!agent) return null;
  Object.assign(agent, fields);
  return agent;
}
function remove(id) {
  const agent = agents.get(id);
  if (agent) agents.delete(id);
  return agent;
}
function clear() {
  agents.clear();
  nextPort = 17900;
}

module.exports = { create, get, list, update, remove, clear };
