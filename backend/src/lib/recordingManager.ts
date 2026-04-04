import { spawn, execFile, ChildProcess } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import fs from 'fs';
import { ActionEvent } from './types';

const execFileAsync = promisify(execFile);

const RECORDINGS_DIR = path.resolve(process.env.RECORDINGS_DIR ?? './recordings');
const DOCKER = ['/usr/local/bin/docker', '/opt/homebrew/bin/docker', 'docker'].find(
  (p) => p === 'docker' || fs.existsSync(p),
) ?? 'docker';

const timelines = new Map<string, ActionEvent[]>();

export function startRecording(containerName: string, sessionId: string): ChildProcess {
  const sessionDir = path.join(RECORDINGS_DIR, sessionId);
  fs.mkdirSync(sessionDir, { recursive: true });
  timelines.set(sessionId, []);

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
    '-y',
    '/recordings/recording.mp4',
  ], { stdio: 'ignore' });

  proc.on('error', (err) => console.warn(`ffmpeg spawn error: ${err.message}`));
  proc.on('exit', (code) => {
    if (code !== null && code !== 0 && code !== 255) {
      console.warn(`ffmpeg exited with code ${code}`);
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
  return new Promise((resolve) => {
    proc.kill('SIGINT');

    const timeout = setTimeout(async () => {
      proc.kill('SIGKILL');
      await copyRecording(containerName, sessionId);
      resolve();
    }, 5000);

    proc.on('exit', async () => {
      clearTimeout(timeout);
      await new Promise<void>((r) => setTimeout(r, 1000));
      await copyRecording(containerName, sessionId);
      resolve();
    });
  });
}

async function copyRecording(containerName: string, sessionId: string): Promise<void> {
  const destPath = path.join(RECORDINGS_DIR, sessionId, 'recording.mp4');
  try {
    await execFileAsync(DOCKER, ['cp', `${containerName}:/recordings/recording.mp4`, destPath]);
    console.log(`Recording saved: ${destPath}`);
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
