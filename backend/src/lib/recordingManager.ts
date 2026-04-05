import { spawn, execFile, ChildProcess } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import fs from 'fs';
import { ActionEvent } from './types';

const execFileAsync = promisify(execFile);

const RECORDINGS_DIR = path.resolve(process.env.RECORDINGS_DIR ?? './recordings');
const DOCKER = [
  '/usr/local/bin/docker',
  '/opt/homebrew/bin/docker',
  '/Applications/Docker.app/Contents/Resources/bin/docker',
].find((p) => fs.existsSync(p)) ?? 'docker';

const EXTRA_PATHS = ['/usr/local/bin', '/opt/homebrew/bin', '/Applications/Docker.app/Contents/Resources/bin'];
const DOCKER_ENV: Record<string, string> = {
  ...process.env as Record<string, string>,
  PATH: [...new Set([...EXTRA_PATHS, ...(process.env.PATH ?? '').split(':')])].join(':'),
};

const timelines = new Map<string, ActionEvent[]>();

export function startRecording(containerName: string, sessionId: string): ChildProcess {
  const sessionDir = path.join(RECORDINGS_DIR, sessionId);
  fs.mkdirSync(sessionDir, { recursive: true });
  timelines.set(sessionId, []);

  // Use -movflags +faststart so the moov atom is written even if interrupted
  const proc = spawn(DOCKER, [
    'exec', containerName,
    'ffmpeg',
    '-f', 'x11grab',
    '-r', '10',
    '-video_size', '1024x768',
    '-i', ':1',
    '-c:v', 'libx264',
    '-preset', 'ultrafast',
    '-crf', '28',
    '-movflags', '+faststart',
    '-y',
    '/recordings/recording.mp4',
  ], { stdio: 'pipe', env: DOCKER_ENV });

  proc.on('error', (err) => console.warn(`ffmpeg spawn error: ${err.message}`));
  proc.stderr?.on('data', (d: Buffer) => {
    const line = d.toString().trim();
    if (line && !line.startsWith('frame=')) {
      console.log(`[ffmpeg] ${line.slice(0, 120)}`);
    }
  });
  proc.on('exit', (code) => {
    if (code !== null && code !== 0 && code !== 255) {
      console.warn(`[ffmpeg] exited with code ${code}`);
    }
  });

  console.log(`Recording started for session ${sessionId}`);
  return proc;
}

export async function stopRecording(
  proc: ChildProcess,
  containerName: string,
  sessionId: string,
): Promise<void> {
  // Send 'q' to ffmpeg stdin to gracefully quit (writes moov atom)
  try {
    await execFileAsync(DOCKER, [
      'exec', containerName,
      'bash', '-c', 'kill -INT $(pgrep ffmpeg) 2>/dev/null || true',
    ], { env: DOCKER_ENV });
  } catch { /* container might be gone */ }

  // Wait for the spawn process to exit
  await new Promise<void>((resolve) => {
    const timeout = setTimeout(() => {
      proc.kill('SIGKILL');
      resolve();
    }, 8000);

    proc.on('exit', () => {
      clearTimeout(timeout);
      resolve();
    });

    // Also try killing the local process
    proc.kill('SIGINT');
  });

  // Small delay to let the file finalize
  await new Promise<void>((r) => setTimeout(r, 1000));
  await copyRecording(containerName, sessionId);
}

async function copyRecording(containerName: string, sessionId: string): Promise<void> {
  const destPath = path.join(RECORDINGS_DIR, sessionId, 'recording.mp4');
  try {
    await execFileAsync(DOCKER, ['cp', `${containerName}:/recordings/recording.mp4`, destPath], { env: DOCKER_ENV });
    const stat = fs.statSync(destPath);
    console.log(`Recording saved: ${destPath} (${(stat.size / 1024).toFixed(0)} KB)`);
  } catch (err) {
    console.warn(`Failed to copy recording for session ${sessionId}: ${(err as Error).message}`);
  }
}

export function logAction(sessionId: string, event: ActionEvent): void {
  if (!timelines.has(sessionId)) timelines.set(sessionId, []);
  timelines.get(sessionId)!.push(event);
}

export function saveTimeline(sessionId: string): void {
  const sessionDir = path.join(RECORDINGS_DIR, sessionId);
  fs.mkdirSync(sessionDir, { recursive: true });
  const timelinePath = path.join(sessionDir, 'timeline.json');
  const events = timelines.get(sessionId) ?? [];
  fs.writeFileSync(timelinePath, JSON.stringify(events, null, 2));
  console.log(`Timeline saved: ${timelinePath} (${events.length} events)`);
}

export function recordingPath(sessionId: string): string {
  return path.join(RECORDINGS_DIR, sessionId, 'recording.mp4');
}

export function timelinePath(sessionId: string): string {
  return path.join(RECORDINGS_DIR, sessionId, 'timeline.json');
}
