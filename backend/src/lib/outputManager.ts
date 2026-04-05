import path from 'path';
import { mkdir, readdir } from 'fs/promises';
import { existsSync } from 'fs';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

const DOCKER = [
  '/usr/local/bin/docker',
  '/opt/homebrew/bin/docker',
  '/Applications/Docker.app/Contents/Resources/bin/docker',
].find((p) => existsSync(p)) ?? 'docker';

const OUTPUTS_BASE = path.resolve(process.env.OUTPUTS_DIR ?? './outputs');

export function outputDir(agentId: string): string {
  return path.join(OUTPUTS_BASE, agentId);
}

export async function retrieveOutputs(containerName: string, agentId: string): Promise<string[]> {
  let raw = '';
  try {
    const { stdout } = await execFileAsync(DOCKER, [
      'exec', containerName, 'bash', '-c',
      'cat /tmp/relay_outputs.txt 2>/dev/null || echo ""',
    ]);
    raw = stdout;
  } catch {
    return [];
  }

  const remotePaths = raw
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && l.startsWith('/'));

  if (remotePaths.length === 0) return [];

  const localDir = outputDir(agentId);
  await mkdir(localDir, { recursive: true });

  const retrieved: string[] = [];
  for (const remotePath of remotePaths) {
    const basename = path.basename(remotePath);
    const localPath = path.join(localDir, basename);
    try {
      await execFileAsync(DOCKER, ['cp', `${containerName}:${remotePath}`, localPath]);
      retrieved.push(basename);
      console.log(`[outputs] Retrieved ${remotePath} → ${localPath}`);
    } catch (err) {
      console.warn(`[outputs] Failed to retrieve ${remotePath}: ${(err as Error).message}`);
    }
  }
  return retrieved;
}

export async function listOutputs(agentId: string): Promise<string[]> {
  const dir = outputDir(agentId);
  if (!existsSync(dir)) return [];
  return readdir(dir);
}
