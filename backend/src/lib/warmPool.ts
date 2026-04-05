import { allocatePorts, dockerRun, ensureImage, waitForReady, execInContainer, releasePorts, Ports } from './dockerManager';
import { getApiKey } from './config';

const RELAY_IMAGE = 'relay-agent';

export interface WarmContainer {
  containerName: string;
  noVNCPort: number;
  vncPort: number;
  portIndex: number;
}

let pool: WarmContainer[] = [];
let booting = 0;
let initialized = false;
const TARGET_SIZE = 1;

export function acquire(): WarmContainer | null {
  const container = pool.shift() ?? null;
  if (container) {
    console.log(`[warmPool] Acquired warm container ${container.containerName} (pool: ${pool.length} remaining)`);
    // Replenish in background
    setImmediate(() => replenish());
  }
  return container;
}

export async function initWarmPool(): Promise<void> {
  if (initialized) {
    // API key changed — drain and reboot
    console.log('[warmPool] Re-initializing (API key changed)');
    await drainPool();
  }
  initialized = true;
  console.log(`[warmPool] Initializing warm pool (target: ${TARGET_SIZE})`);
  replenish();
}

function replenish(): void {
  const needed = TARGET_SIZE - pool.length - booting;
  for (let i = 0; i < needed; i++) {
    booting++;
    bootOne().catch((err) => {
      console.error(`[warmPool] Failed to boot warm container:`, err);
      booting--;
    });
  }
}

async function bootOne(): Promise<void> {
  console.log('[warmPool] Booting warm container...');
  await ensureImage();

  const ports: Ports = allocatePorts();
  const containerName = `relay-warm-${ports._index}`;

  await dockerRun([
    'run', '-d',
    '--name', containerName,
    '-p', `${ports.noVNC}:6080`,
    '-p', `${ports.vnc}:5900`,
    '-e', `ANTHROPIC_API_KEY=${getApiKey()}`,
    '-e', 'WIDTH=2560',
    '-e', 'HEIGHT=1440',
    '--shm-size=2g',
    RELAY_IMAGE,
  ]);

  console.log(`[warmPool] Container ${containerName} started — waiting for noVNC on port ${ports.noVNC}...`);
  await waitForReady(ports.noVNC);

  // Create /recordings as root (container user can't create dirs at /)
  await dockerRun(['exec', '-u', 'root', containerName, 'bash', '-c', 'mkdir -p /recordings && chmod 777 /recordings']);

  // Set desktop wallpaper via pcmanfm (creates a DESKTOP-type window above mutter's background)
  execInContainer(containerName,
    'DISPLAY=:1 pcmanfm --desktop --profile default & sleep 2 && DISPLAY=:1 pcmanfm --set-wallpaper /usr/share/wallpaper.jpg --wallpaper-mode=stretch',
    15_000
  ).catch((e) => console.warn(`[warmPool] Wallpaper set failed: ${(e as Error).message}`));

  booting--;
  pool.push({
    containerName,
    noVNCPort: ports.noVNC,
    vncPort: ports.vnc,
    portIndex: ports._index,
  });
  console.log(`[warmPool] Warm container ${containerName} ready (pool: ${pool.length})`);
}

export async function drainPool(): Promise<void> {
  console.log(`[warmPool] Draining ${pool.length} warm container(s)`);
  const toStop = pool.splice(0);
  for (const c of toStop) {
    try {
      await dockerRun(['rm', '-f', c.containerName]);
      releasePorts(c.noVNCPort);
    } catch (e) {
      console.warn(`[warmPool] Failed to stop ${c.containerName}: ${(e as Error).message}`);
    }
  }
  initialized = false;
}

export function getPoolStatus(): { ready: number; booting: number; target: number } {
  return { ready: pool.length, booting, target: TARGET_SIZE };
}
