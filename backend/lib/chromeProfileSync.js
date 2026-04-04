const os = require('os');
const fs = require('fs-extra');
const path = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');

const CHROME_BASE = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'Google',
  'Chrome'
);
const STAGING_BASE = path.join(os.homedir(), '.relay', 'chrome-profiles');

// Files safe to copy directly (unencrypted, cross-platform compatible)
const PORTABLE_FILES = [
  'Bookmarks',
  'History',
  'Top Sites',
  'Favicons',
  'Preferences',
];

// --- Cookie re-encryption (macOS Chrome → Linux Chromium) ---

/**
 * Get the Chrome Safe Storage password from macOS Keychain.
 * This may trigger a system auth prompt (Touch ID / password).
 */
function getMacOSChromeKey() {
  try {
    const password = execSync(
      'security find-generic-password -w -s "Chrome Safe Storage"',
      { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }
    ).trim();
    return password;
  } catch {
    return null;
  }
}

/**
 * Derive an AES key from a password using Chrome's PBKDF2 scheme.
 * macOS: 1003 iterations with the Chrome Safe Storage password
 * Linux: 1 iteration with "peanuts" (Chromium default when no keyring)
 */
function deriveKey(password, iterations) {
  return crypto.pbkdf2Sync(password, 'saltysalt', iterations, 16, 'sha1');
}

/**
 * Decrypt a Chrome cookie value encrypted on macOS.
 * Format: "v10" prefix + 3-byte nonce(ignored) + AES-128-CBC encrypted data
 */
function decryptMacOS(encryptedValue, key) {
  if (!encryptedValue || encryptedValue.length < 4) return null;

  // v10 prefix = 3 bytes
  const prefix = encryptedValue.slice(0, 3).toString('utf8');
  if (prefix !== 'v10') return null;

  const encrypted = encryptedValue.slice(3);
  const iv = Buffer.alloc(16, ' '); // Chrome uses a space-filled IV

  try {
    const decipher = crypto.createDecipheriv('aes-128-cbc', key, iv);
    decipher.setAutoPadding(true);
    const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    return decrypted;
  } catch {
    return null;
  }
}

/**
 * Encrypt a cookie value for Linux Chromium.
 * Format: "v10" prefix + AES-128-CBC encrypted data
 */
function encryptLinux(plainValue, key) {
  const iv = Buffer.alloc(16, ' ');
  const cipher = crypto.createCipheriv('aes-128-cbc', key, iv);
  cipher.setAutoPadding(true);
  const encrypted = Buffer.concat([cipher.update(plainValue), cipher.final()]);
  return Buffer.concat([Buffer.from('v10', 'utf8'), encrypted]);
}

/**
 * Re-encrypt cookies from macOS Chrome format to Linux Chromium format.
 * Copies the Cookies SQLite file, then updates encrypted_value in each row.
 *
 * Requires `better-sqlite3` — falls back to skipping if not available.
 */
async function convertCookies(sourceDir, destDir) {
  let Database;
  try {
    Database = require('better-sqlite3');
  } catch {
    console.warn('better-sqlite3 not installed — skipping cookie transfer. Run: npm install better-sqlite3');
    return false;
  }

  const srcCookies = path.join(sourceDir, 'Cookies');
  const destCookies = path.join(destDir, 'Cookies');

  if (!(await fs.pathExists(srcCookies))) return false;

  // Get macOS decryption key
  const macPassword = getMacOSChromeKey();
  if (!macPassword) {
    console.warn('Could not get Chrome Safe Storage key from Keychain — skipping cookie transfer');
    return false;
  }

  const macKey = deriveKey(macPassword, 1003);
  const linuxKey = deriveKey('peanuts', 1);

  // Copy the Cookies file first
  await fs.copy(srcCookies, destCookies, { overwrite: true });

  // Open and re-encrypt each cookie
  const db = new Database(destCookies);

  try {
    const rows = db.prepare('SELECT rowid, encrypted_value FROM cookies').all();
    const update = db.prepare('UPDATE cookies SET encrypted_value = ? WHERE rowid = ?');

    const transaction = db.transaction(() => {
      let converted = 0;
      for (const row of rows) {
        if (!row.encrypted_value || row.encrypted_value.length < 4) continue;

        const plain = decryptMacOS(row.encrypted_value, macKey);
        if (!plain) continue;

        const reEncrypted = encryptLinux(plain, linuxKey);
        update.run(reEncrypted, row.rowid);
        converted++;
      }
      return converted;
    });

    const count = transaction();
    console.log(`Re-encrypted ${count} cookies for Linux Chromium`);
    return true;
  } catch (err) {
    console.error('Cookie conversion error:', err.message);
    // Remove partial cookies file
    await fs.remove(destCookies).catch(() => {});
    return false;
  } finally {
    db.close();
  }
}

// --- Profile detection & sync ---

/**
 * Detect all Chrome profiles on the host machine.
 * Returns [{dirName, displayName}] for each profile that has a Bookmarks file.
 */
async function detectProfiles() {
  const profiles = [];

  if (!(await fs.pathExists(CHROME_BASE))) {
    return profiles;
  }

  const entries = await fs.readdir(CHROME_BASE, { withFileTypes: true });

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;

    if (entry.name !== 'Default' && !entry.name.startsWith('Profile ')) continue;

    const profileDir = path.join(CHROME_BASE, entry.name);
    const bookmarksPath = path.join(profileDir, 'Bookmarks');

    if (!(await fs.pathExists(bookmarksPath))) continue;

    let displayName = entry.name;
    try {
      const prefsPath = path.join(profileDir, 'Preferences');
      if (await fs.pathExists(prefsPath)) {
        const prefs = await fs.readJson(prefsPath);
        if (prefs.profile && prefs.profile.name) {
          displayName = prefs.profile.name;
        }
      }
    } catch {
      // Fall back to directory name
    }

    let bookmarkCount = 0;
    try {
      const bookmarks = await fs.readJson(bookmarksPath);
      bookmarkCount = countBookmarks(bookmarks.roots);
    } catch {
      // Ignore
    }

    profiles.push({
      dirName: entry.name,
      displayName,
      bookmarkCount,
    });
  }

  return profiles;
}

function countBookmarks(node) {
  if (!node) return 0;
  if (typeof node !== 'object') return 0;

  let count = 0;
  if (node.type === 'url') return 1;

  for (const value of Object.values(node)) {
    if (Array.isArray(value)) {
      for (const child of value) {
        count += countBookmarks(child);
      }
    } else if (typeof value === 'object') {
      count += countBookmarks(value);
    }
  }
  return count;
}

/**
 * Sync Chrome profile data to a staging directory for an agent.
 * Includes cookie re-encryption from macOS → Linux format.
 *
 * If the staging dir already exists (returning agent), only bookmarks are
 * refreshed — login sessions from previous container runs are preserved.
 */
async function syncProfile(profileDirName, agentId) {
  const sourceDir = path.join(CHROME_BASE, profileDirName);
  const destDir = stagingDir(agentId);

  if (!(await fs.pathExists(sourceDir))) {
    throw new Error(`Chrome profile not found: ${sourceDir}`);
  }

  const isReturning = await fs.pathExists(destDir);
  await fs.ensureDir(destDir);

  // Copy portable files
  for (const file of PORTABLE_FILES) {
    const src = path.join(sourceDir, file);
    const dest = path.join(destDir, file);

    if (!(await fs.pathExists(src))) continue;

    if (isReturning && file !== 'Bookmarks') {
      continue;
    }

    await fs.copy(src, dest, { overwrite: true });
  }

  // Convert and copy cookies (only on first sync — don't overwrite container sessions)
  if (!isReturning) {
    await convertCookies(sourceDir, destDir);
  }

  return path.dirname(destDir);
}

function stagingDir(agentId) {
  return path.join(STAGING_BASE, agentId, 'Default');
}

async function cleanupProfile(agentId) {
  const dir = path.join(STAGING_BASE, agentId);
  if (await fs.pathExists(dir)) {
    await fs.remove(dir);
  }
}

module.exports = {
  detectProfiles,
  syncProfile,
  stagingDir,
  cleanupProfile,
  convertCookies,
  STAGING_BASE,
};
