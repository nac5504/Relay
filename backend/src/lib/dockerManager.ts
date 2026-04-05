import { execFile } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import { existsSync } from 'fs';
import { getApiKey } from './config';
import { ComputerToolInput } from './types';

const execFileAsync = promisify(execFile);

const DOCKER = [
  '/usr/local/bin/docker',
  '/opt/homebrew/bin/docker',
  '/Applications/Docker.app/Contents/Resources/bin/docker',
].find((p) => existsSync(p)) ?? 'docker';

// Ensure Docker credential helpers and CLI tools are in PATH
const EXTRA_PATHS = [
  '/usr/local/bin',
  '/opt/homebrew/bin',
  '/Applications/Docker.app/Contents/Resources/bin',
];
const DOCKER_ENV: Record<string, string> = {
  ...process.env as Record<string, string>,
  PATH: [...new Set([...EXTRA_PATHS, ...(process.env.PATH ?? '').split(':')])].join(':'),
};

const RECORDINGS_DIR = process.env.RECORDINGS_DIR ?? './recordings';
const RELAY_IMAGE = 'relay-agent';
const DOCKER_DIR = path.resolve(__dirname, '..', '..', 'docker');

// Port allocation — base 17900, 10 ports per agent
const BASE_PORT = 17900;
const STRIDE = 10;
let nextIndex = 0;
const freedIndices: number[] = [];

interface Ports {
  noVNC: number;
  vnc: number;
  _index: number;
}

function allocatePorts(): Ports {
  const index = freedIndices.length > 0 ? freedIndices.pop()! : nextIndex++;
  return {
    noVNC: BASE_PORT + index * STRIDE,
    vnc: BASE_PORT + index * STRIDE + 1,
    _index: index,
  };
}

export function releasePorts(noVNCPort: number): void {
  const index = (noVNCPort - BASE_PORT) / STRIDE;
  if (Number.isInteger(index)) freedIndices.push(index);
}

async function dockerRun(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(DOCKER, args, { env: DOCKER_ENV, maxBuffer: 10 * 1024 * 1024 });
  return stdout.trim();
}

export async function execInContainer(containerName: string, shellCmd: string): Promise<string> {
  const { stdout } = await execFileAsync(DOCKER, ['exec', containerName, 'bash', '-c', shellCmd], { env: DOCKER_ENV });
  return stdout;
}

export interface ContainerInfo {
  containerName: string;
  noVNCPort: number;
  vncPort: number;
}

let imageReady = false;

export async function ensureImage(): Promise<void> {
  if (imageReady) return;
  try {
    const out = await dockerRun(['images', '-q', RELAY_IMAGE]);
    if (out.length > 0) {
      imageReady = true;
      console.log(`[docker] Image ${RELAY_IMAGE} already exists`);
      return;
    }
  } catch { /* no image */ }

  console.log(`[docker] Building ${RELAY_IMAGE} image (one-time, installs ffmpeg + scrot)...`);
  await dockerRun(['build', '-t', RELAY_IMAGE, DOCKER_DIR]);
  imageReady = true;
  console.log(`[docker] Image ${RELAY_IMAGE} built successfully`);
}

export async function startContainer(agentId: string, sessionId: string): Promise<ContainerInfo> {
  await ensureImage();

  const ports = allocatePorts();
  const containerName = `relay-agent-${agentId.replace(/-/g, '').slice(0, 12)}`;
  const recordingsPath = path.resolve(RECORDINGS_DIR, sessionId);

  await dockerRun([
    'run', '-d',
    '--name', containerName,
    '-p', `${ports.noVNC}:6080`,
    '-p', `${ports.vnc}:5900`,
    '-v', `${recordingsPath}:/recordings`,
    '-e', `ANTHROPIC_API_KEY=${getApiKey()}`,
    '-e', 'WIDTH=1024',
    '-e', 'HEIGHT=768',
    '--shm-size=2g',
    RELAY_IMAGE,
  ]);

  return { containerName, noVNCPort: ports.noVNC, vncPort: ports.vnc };
}

export async function stopContainer(containerName: string, noVNCPort: number | null): Promise<void> {
  try {
    await dockerRun(['rm', '-f', containerName]);
  } catch (e) {
    console.warn(`stopContainer: ${(e as Error).message}`);
  }
  if (noVNCPort !== null) releasePorts(noVNCPort);
}

export async function screenshot(containerName: string): Promise<string> {
  const cmd = `
    DISPLAY=:1 scrot /tmp/relay_ss.png -z 2>/dev/null || \
    DISPLAY=:1 import -window root /tmp/relay_ss.png 2>/dev/null; \
    base64 /tmp/relay_ss.png
  `;
  const b64 = await execInContainer(containerName, cmd);
  return b64.replace(/\s/g, '');
}

export async function executeAction(containerName: string, toolInput: ComputerToolInput): Promise<void> {
  const { action } = toolInput;

  switch (action) {
    case 'screenshot':
      break;

    case 'mouse_move': {
      const [x, y] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y}`);
      break;
    }

    case 'left_click': {
      const [x, y] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y} click 1`);
      break;
    }

    case 'right_click': {
      const [x, y] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y} click 3`);
      break;
    }

    case 'double_click': {
      const [x, y] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y} click --repeat 2 1`);
      break;
    }

    case 'triple_click': {
      const [x, y] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y} click 1 && DISPLAY=:1 xdotool key ctrl+a`);
      break;
    }

    case 'type': {
      const escaped = toolInput.text!.replace(/'/g, "'\\''");
      await execInContainer(containerName, `DISPLAY=:1 xdotool type --clearmodifiers '${escaped}'`);
      break;
    }

    case 'key':
      await execInContainer(containerName, `DISPLAY=:1 xdotool key ${toolInput.key}`);
      break;

    case 'scroll': {
      const [x, y] = toolInput.coordinate!;
      const button = toolInput.scroll_direction === 'up' ? 4 : 5;
      const clicks = toolInput.scroll_amount ?? 3;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${x} ${y} click --repeat ${clicks} ${button}`);
      break;
    }

    case 'drag': {
      const [sx, sy] = toolInput.startCoordinate!;
      const [ex, ey] = toolInput.coordinate!;
      await execInContainer(containerName, `DISPLAY=:1 xdotool mousemove ${sx} ${sy} mousedown 1 mousemove ${ex} ${ey} mouseup 1`);
      break;
    }

    case 'wait':
      await new Promise<void>((r) => setTimeout(r, (toolInput.duration ?? 1) * 1000));
      break;

    default:
      console.warn(`Unknown action: ${action}`);
  }
}

export async function waitForReady(noVNCPort: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  const url = `http://localhost:${noVNCPort}/`;

  while (Date.now() < deadline) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (res.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise<void>((r) => setTimeout(r, 1000));
  }
  throw new Error(`Container noVNC not ready on port ${noVNCPort} after ${timeoutMs}ms`);
}

export async function cleanupStale(): Promise<void> {
  try {
    const out = await dockerRun(['ps', '-a', '--filter', 'name=relay-agent', '-q']);
    const ids = out.split('\n').filter(Boolean);
    for (const id of ids) {
      await dockerRun(['rm', '-f', id]).catch(() => {});
    }
  } catch {
    // Docker not available or no stale containers
  }
}
