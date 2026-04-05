import { execFile, spawn } from 'child_process';
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

export async function execInContainer(containerName: string, shellCmd: string, timeoutMs = 30_000): Promise<string> {
  const { stdout } = await execFileAsync(DOCKER, ['exec', containerName, 'bash', '-c', shellCmd], {
    env: DOCKER_ENV,
    timeout: timeoutMs,
    maxBuffer: 10 * 1024 * 1024,
  });
  return stdout;
}

export interface ContainerInfo {
  containerName: string;
  noVNCPort: number;
  vncPort: number;
}

let imageReady = false;
const IMAGE_VERSION = '4'; // bump to force rebuild — added chromium via playwright

export async function ensureImage(): Promise<void> {
  if (imageReady) return;
  try {
    const out = await dockerRun(['images', '-q', `${RELAY_IMAGE}:v${IMAGE_VERSION}`]);
    if (out.length > 0) {
      imageReady = true;
      console.log(`[docker] Image ${RELAY_IMAGE}:v${IMAGE_VERSION} already exists`);
      return;
    }
  } catch { /* no image */ }

  console.log(`[docker] Building ${RELAY_IMAGE}:v${IMAGE_VERSION} image (one-time, installs ffmpeg + scrot + chromium)...`);
  await dockerRun(['build', '-t', `${RELAY_IMAGE}:v${IMAGE_VERSION}`, '-t', RELAY_IMAGE, DOCKER_DIR]);
  imageReady = true;
  console.log(`[docker] Image ${RELAY_IMAGE}:v${IMAGE_VERSION} built successfully`);
}

export async function startContainer(agentId: string, sessionId: string, chromeProfilePath?: string): Promise<ContainerInfo> {
  await ensureImage();

  const ports = allocatePorts();
  const containerName = `relay-agent-${agentId.replace(/-/g, '').slice(0, 12)}`;
  const recordingsPath = path.resolve(RECORDINGS_DIR, sessionId);

  const args = [
    'run', '-d',
    '--name', containerName,
    '-p', `${ports.noVNC}:6080`,
    '-p', `${ports.vnc}:5900`,
    '-v', `${recordingsPath}:/recordings`,
    '-e', `ANTHROPIC_API_KEY=${getApiKey()}`,
    '-e', 'WIDTH=2560',
    '-e', 'HEIGHT=1440',
    '--shm-size=2g',
  ];

  // Mount Chrome profile if synced
  if (chromeProfilePath) {
    args.push('-v', `${chromeProfilePath}:/home/computeruse/.config/chromium/Default`);
    console.log(`[docker] Mounting Chrome profile from ${chromeProfilePath}`);
  }

  args.push(RELAY_IMAGE);
  await dockerRun(args);

  // Fix permissions on mounted Chrome profile (volume mounts as root)
  if (chromeProfilePath) {
    await dockerRun(['exec', '-u', 'root', containerName, 'chown', '-R', 'computeruse:computeruse', '/home/computeruse/.config/chromium']);
    // Also create the symlink for chromium binary
    await dockerRun(['exec', '-u', 'root', containerName, 'bash', '-c',
      'ln -sf $(find /home/computeruse/.cache/ms-playwright -name "chrome" -path "*/chrome-linux/chrome" -type f 2>/dev/null | head -1) /usr/local/bin/chromium 2>/dev/null || true']);
  }

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

/**
 * Run an Anthropic tool via the Python relay_tool_runner.py inside the container.
 * Returns parsed JSON result.
 */
async function runTool(containerName: string, toolName: string, input: Record<string, unknown> = {}): Promise<{ base64?: string; output?: string; error?: string }> {
  const inputJson = JSON.stringify(input).replace(/'/g, "'\\''");
  const cmd = `python3 /relay_tool_runner.py ${toolName} '${inputJson}'`;
  const raw = await execInContainer(containerName, cmd);
  try {
    return JSON.parse(raw.trim().split('\n').pop()!);
  } catch {
    return { error: raw.slice(0, 500) };
  }
}

export async function screenshot(containerName: string): Promise<string> {
  const result = await runTool(containerName, 'screenshot');
  if (result.error) console.warn(`[docker] Screenshot error: ${result.error}`);
  return result.base64 ?? '';
}

export async function executeAction(containerName: string, toolInput: ComputerToolInput): Promise<void> {
  if (toolInput.action === 'screenshot') return; // handled separately
  if (toolInput.action === 'wait') {
    await new Promise<void>((r) => setTimeout(r, (toolInput.duration ?? 1) * 1000));
    return;
  }
  const result = await runTool(containerName, 'computer', toolInput as unknown as Record<string, unknown>);
  if (result.error) console.warn(`[docker] Action error: ${result.error}`);
}

export async function executeBash(containerName: string, input: { command?: string; restart?: boolean }): Promise<string> {
  const result = await runTool(containerName, 'bash', input as Record<string, unknown>);
  if (result.error) return `Error: ${result.error}`;
  return result.output ?? '';
}

export async function executeTextEditor(containerName: string, input: Record<string, unknown>): Promise<string> {
  const result = await runTool(containerName, 'text_editor', input);
  if (result.error) return `Error: ${result.error}`;
  return result.output ?? '';
}

export async function waitForReady(noVNCPort: number, timeoutMs = 60_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  const url = `http://localhost:${noVNCPort}/`;

  while (Date.now() < deadline) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(2000) });
      if (res.ok) {
        // VNC WebSocket proxy (websockify) starts after the HTTP server —
        // wait for it to fully initialize before signaling readiness
        await new Promise<void>((r) => setTimeout(r, 3000));
        return;
      }
    } catch {
      // not ready yet
    }
    await new Promise<void>((r) => setTimeout(r, 1000));
  }
  throw new Error(`Container noVNC not ready on port ${noVNCPort} after ${timeoutMs}ms`);
}

export function resetImageReady(): void {
  imageReady = false;
}

export async function checkImageExists(): Promise<boolean> {
  try {
    const out = await dockerRun(['images', '-q', `${RELAY_IMAGE}:v${IMAGE_VERSION}`]);
    return out.length > 0;
  } catch {
    return false;
  }
}

export function getImageTag(): string {
  return `${RELAY_IMAGE}:v${IMAGE_VERSION}`;
}

export async function buildImageStreaming(onLine: (line: string) => void): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn(DOCKER, ['build', '-t', `${RELAY_IMAGE}:v${IMAGE_VERSION}`, '-t', RELAY_IMAGE, DOCKER_DIR], {
      env: DOCKER_ENV,
    });

    let stderr = '';

    const processData = (data: Buffer) => {
      const lines = data.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        onLine(line);
      }
    };

    proc.stdout.on('data', processData);
    proc.stderr.on('data', (data: Buffer) => {
      stderr += data.toString();
      processData(data);
    });

    proc.on('close', (code) => {
      if (code === 0) {
        imageReady = true;
        resolve();
      } else {
        reject(new Error(`Docker build failed (exit ${code}): ${stderr.slice(-500)}`));
      }
    });

    proc.on('error', (err) => {
      reject(err);
    });
  });
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
