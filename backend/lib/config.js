const fs = require('fs-extra');
const path = require('path');
const crypto = require('crypto');

const CONFIG_PATH = path.join(__dirname, '..', '.relay-config.json');

const DEFAULT_CONFIG = {
  chromeProfile: 'Default',
  aptPackages: [],
  pipPackages: [],
  imageHash: null, // hash of package lists used in last build
};

let _config = null;

/**
 * Load config from disk, or return defaults if no config file exists.
 */
async function load() {
  if (_config) return _config;

  if (await fs.pathExists(CONFIG_PATH)) {
    try {
      _config = { ...DEFAULT_CONFIG, ...(await fs.readJson(CONFIG_PATH)) };
    } catch {
      _config = { ...DEFAULT_CONFIG };
    }
  } else {
    _config = { ...DEFAULT_CONFIG };
  }

  return _config;
}

/**
 * Save current config to disk.
 */
async function save() {
  if (!_config) return;
  await fs.writeJson(CONFIG_PATH, _config, { spaces: 2 });
}

/**
 * Update config with partial values and persist.
 */
async function update(partial) {
  const config = await load();

  if (partial.chromeProfile !== undefined) config.chromeProfile = partial.chromeProfile;
  if (partial.aptPackages !== undefined) config.aptPackages = partial.aptPackages;
  if (partial.pipPackages !== undefined) config.pipPackages = partial.pipPackages;

  await save();
  return config;
}

/**
 * Hash the current package lists. Used to detect if image needs rebuilding.
 */
function packageHash(config) {
  const data = JSON.stringify({
    apt: [...(config.aptPackages || [])].sort(),
    pip: [...(config.pipPackages || [])].sort(),
  });
  return crypto.createHash('sha256').update(data).digest('hex').slice(0, 12);
}

/**
 * Check if the Docker image needs to be rebuilt (packages changed since last build).
 */
async function imageNeedsRebuild() {
  const config = await load();
  if (!config.imageHash) return true;
  return config.imageHash !== packageHash(config);
}

/**
 * Record that the image was built with the current package lists.
 */
async function markImageBuilt() {
  const config = await load();
  config.imageHash = packageHash(config);
  await save();
}

module.exports = {
  load,
  save,
  update,
  packageHash,
  imageNeedsRebuild,
  markImageBuilt,
};
