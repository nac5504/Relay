import { WebSocket } from 'ws';

const clients = new Set<WebSocket>();

export function addClient(ws: WebSocket): void {
  clients.add(ws);
  ws.on('close', () => clients.delete(ws));
}

export function broadcast(message: object): void {
  const json = JSON.stringify(message);
  const type = (message as { type?: string }).type ?? 'unknown';
  if (type !== 'plan_message' || !(message as { streaming?: boolean }).streaming) {
    console.log(`[ws] broadcast ${type} to ${clients.size} clients`);
  }
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(json);
    }
  }
}
