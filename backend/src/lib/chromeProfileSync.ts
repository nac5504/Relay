import os from 'os';
import path from 'path';
import fs from 'fs-extra';
import crypto from 'crypto';
import { execSync } from 'child_process';
import Database from 'better-sqlite3';

const CHROME_BASE = path.join(os.homedir(), 'Library', 'Application Support', 'Google', 'Chrome');
const STAGING_BASE = path.join(os.homedir(), '.relay', 'chrome-profiles');

const PORTABLE_FILES = ['Bookmarks', 'History', 'Top Sites', 'Favicons', 'Preferences', 'Login Data'];

// ---- macOS Keychain ----

function getMacOSChromeKey(): string | null {
  try {
    return execSync('security find-generic-password -w -s "Chrome Safe Storage"', {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    return null;
  }
}

// ---- Cookie re-encryption ----

function deriveKey(password: string, iterations: number): Buffer {
  return crypto.pbkdf2Sync(password, 'saltysalt', iterations, 16, 'sha1');
}

function decryptMacOS(encryptedValue: Buffer, key: Buffer): Buffer | null {
  if (!encryptedValue || encryptedValue.length < 4) return null;
  const prefix = encryptedValue.slice(0, 3).toString('utf8');
  if (prefix !== 'v10') return null;
  const encrypted = encryptedValue.slice(3);
  const iv = Buffer.alloc(16, ' ');
  try {
    const decipher = crypto.createDecipheriv('aes-128-cbc', key, iv);
    decipher.setAutoPadding(true);
    return Buffer.concat([decipher.update(encrypted), decipher.final()]);
  } catch {
    return null;
  }
}

function encryptLinux(plainValue: Buffer, key: Buffer): Buffer {
  const iv = Buffer.alloc(16, ' ');
  const cipher = crypto.createCipheriv('aes-128-cbc', key, iv);
  cipher.setAutoPadding(true);
  const encrypted = Buffer.concat([cipher.update(plainValue), cipher.final()]);
  return Buffer.concat([Buffer.from('v10'), encrypted]);
}

async function convertCookies(sourceDir: string, destDir: string): Promise<void> {
  const sourceCookiesPath = path.join(sourceDir, 'Cookies');
  const destCookiesPath = path.join(destDir, 'Cookies');

  if (!(await fs.pathExists(sourceCookiesPath))) {
    console.log('[chromeSync] No Cookies file — skipping');
    return;
  }

  const macKey = getMacOSChromeKey();
  if (!macKey) {
    console.warn('[chromeSync] Could not get macOS Chrome key (Touch ID may be needed) — copying without re-encryption');
    await fs.copy(sourceCookiesPath, destCookiesPath, { overwrite: true });
    return;
  }

  const decryptKey = deriveKey(macKey, 1003);
  const encryptKey = deriveKey('peanuts', 1);

  const tmpPath = `${destCookiesPath}.tmp`;
  await fs.copy(sourceCookiesPath, tmpPath, { overwrite: true });

  const db = new Database(tmpPath);
  try {
    db.pragma('journal_mode = WAL');
    const rows = db.prepare('SELECT rowid, encrypted_value FROM cookies').all() as Array<{ rowid: number; encrypted_value: Buffer }>;

    const update = db.prepare('UPDATE cookies SET encrypted_value = ? WHERE rowid = ?');
    const updateMany = db.transaction((rows: Array<{ rowid: number; encrypted_value: Buffer }>) => {
      let converted = 0;
      for (const row of rows) {
        const plain = decryptMacOS(row.encrypted_value, decryptKey);
        if (plain) {
          const reEncrypted = encryptLinux(plain, encryptKey);
          update.run(reEncrypted, row.rowid);
          converted++;
        }
      }
      return converted;
    });
    const count = updateMany(rows);
    console.log(`[chromeSync] Re-encrypted ${count}/${rows.length} cookies`);
  } finally {
    db.close();
  }

  await fs.move(tmpPath, destCookiesPath, { overwrite: true });
}

// ---- Public API ----

export function stagingDir(agentId: string): string {
  return path.join(STAGING_BASE, agentId, 'Default');
}

export interface ChromeProfile {
  dirName: string;
  displayName: string;
}

export async function detectProfiles(): Promise<ChromeProfile[]> {
  const profiles: ChromeProfile[] = [];
  let entries: fs.Dirent[];
  try {
    entries = await fs.readdir(CHROME_BASE, { withFileTypes: true });
  } catch {
    return profiles;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (entry.name !== 'Default' && !entry.name.startsWith('Profile ')) continue;

    let displayName = entry.name;
    try {
      const prefs = await fs.readJson(path.join(CHROME_BASE, entry.name, 'Preferences'));
      displayName = prefs?.profile?.name ?? entry.name;
    } catch { /* ignore */ }

    profiles.push({ dirName: entry.name, displayName });
  }

  return profiles;
}

/**
 * Sync Chrome profile to staging for a given agent.
 * Returns the staging path to mount into the container.
 */
export async function syncProfile(profileDirName: string, agentId: string): Promise<string> {
  const sourceDir = path.join(CHROME_BASE, profileDirName);
  const destDir = stagingDir(agentId);

  if (!(await fs.pathExists(sourceDir))) {
    throw new Error(`Chrome profile not found: ${sourceDir}`);
  }

  await fs.ensureDir(destDir);

  // Copy portable files
  for (const file of PORTABLE_FILES) {
    const src = path.join(sourceDir, file);
    const dest = path.join(destDir, file);
    if (!(await fs.pathExists(src))) continue;
    await fs.copy(src, dest, { overwrite: true });
  }

  // Convert cookies from macOS to Linux encryption
  await convertCookies(sourceDir, destDir);

  console.log(`[chromeSync] Profile "${profileDirName}" synced to ${destDir}`);
  return destDir;
}

export async function cleanupProfile(agentId: string): Promise<void> {
  const dir = path.join(STAGING_BASE, agentId);
  if (await fs.pathExists(dir)) await fs.remove(dir);
}
