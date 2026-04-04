const { execFile, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const config = require('./config');
const chromeSync = require('./chromeProfileSync');

// Detect Docker binary path (macOS: Homebrew or standard install)
const DOCKER_PATH = ['/opt/homebrew/bin/docker', '/usr/local/bin/docker']
  .find((p) => fs.existsSync(p)) || 'docker';

const DOCKER_DIR = path.join(__dirname, '..', 'docker');
const IMAGE_NAME = 'relay-agent';
const RECORDINGS_DIR = path.resolve(process.env.RECORDINGS_DIR || path.join(__dirname, '..', 'recordings'));

// Track image build state + progress
let _buildStatus = 'unknown'; // 'unknown' | 'building' | 'built' | 'needs-rebuild'
let _buildError = null;
let _buildProgress = 0;     // 0.0 - 1.0
let _buildStep = '';         // human-readable current step
let _buildTotalSteps = 0;
let _buildCurrentStep = 0;

// Ensure PATH includes Docker credential helpers and common tool locations.
// When spawned from a macOS GUI app, PATH can be minimal.
const EXTRA_PATHS = [
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '/usr/bin',
  '/bin',
  '/Applications/Docker.app/Contents/Resources/bin',
];
const DOCKER_ENV = {
  ...process.env,
  PATH: [...new Set([...EXTRA_PATHS, ...(process.env.PATH || '').split(':')])].join(':'),
};

/**
 * Run a Docker CLI command and return stdout.
 */
function execDocker(args) {
  return new Promise((resolve, reject) => {
    execFile(DOCKER_PATH, args, { maxBuffer: 10 * 1024 * 1024, env: DOCKER_ENV }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`docker ${args[0]} failed: ${stderr || err.message}`));
      } else {
        resolve(stdout.trim());
      }
    });
  });
}

/**
 * Check if the relay-agent image exists locally.
 */
async function imageExists() {
  try {
    const out = await execDocker(['images', '-q', IMAGE_NAME]);
    return out.length > 0;
  } catch {
    return false;
  }
}

/**
 * Build the relay-agent Docker image with user-specified packages.
 * Uses spawn for streaming output so we can parse progress.
 */
async function buildImage() {
  _buildStatus = 'building';
  _buildError = null;
  _buildProgress = 0;
  _buildStep = 'Starting build...';
  _buildTotalSteps = 0;
  _buildCurrentStep = 0;

  const cfg = await config.load();
  const aptStr = (cfg.aptPackages || []).join(' ');
  const pipStr = (cfg.pipPackages || []).join(' ');

  const args = [
    'build', '--progress=plain',
    '--build-arg', `APT_PACKAGES=${aptStr}`,
    '--build-arg', `PIP_PACKAGES=${pipStr}`,
    '-t', IMAGE_NAME,
    DOCKER_DIR,
  ];

  return new Promise((resolve, reject) => {
    const proc = spawn(DOCKER_PATH, args, { env: DOCKER_ENV });
    let stderr = '';

    // Count total steps by reading the Dockerfile
    try {
      const dockerfile = fs.readFileSync(path.join(DOCKER_DIR, 'Dockerfile'), 'utf8');
      // Count FROM, RUN, COPY, ADD, etc. as steps
      _buildTotalSteps = (dockerfile.match(/^(FROM|RUN|COPY|ADD|ARG|USER|WORKDIR|ENV)\s/gm) || []).length;
    } catch {
      _buildTotalSteps = 8; // fallback estimate
    }

    const parseLine = (line) => {
      // Docker buildkit plain output: "#5 [2/6] RUN apt-get update..."
      const stepMatch = line.match(/#\d+\s+\[(\d+)\/(\d+)\]\s+(.*)/);
      if (stepMatch) {
        _buildCurrentStep = parseInt(stepMatch[1]);
        _buildTotalSteps = parseInt(stepMatch[2]);
        _buildProgress = _buildCurrentStep / _buildTotalSteps;
        // Clean up the step description
        const rawStep = stepMatch[3].trim();
        if (rawStep.startsWith('RUN')) {
          // Shorten long RUN commands
          const cmd = rawStep.slice(4).trim();
          if (cmd.includes('chromium')) _buildStep = 'Installing Chromium...';
          else if (cmd.includes('apt-get install')) _buildStep = 'Installing system packages...';
          else if (cmd.includes('pip install')) _buildStep = 'Installing Python packages...';
          else if (cmd.includes('mkdir')) _buildStep = 'Setting up directories...';
          else _buildStep = cmd.length > 60 ? cmd.slice(0, 57) + '...' : cmd;
        } else if (rawStep.startsWith('FROM')) {
          _buildStep = 'Pulling base image...';
        } else if (rawStep.startsWith('ARG') || rawStep.startsWith('USER')) {
          _buildStep = rawStep;
        } else {
          _buildStep = rawStep.length > 60 ? rawStep.slice(0, 57) + '...' : rawStep;
        }
      }

      // Detect layer caching: "CACHED" means instant
      if (line.includes('CACHED')) {
        const cachedMatch = line.match(/#\d+\s+\[(\d+)\/(\d+)\]/);
        if (cachedMatch) {
          _buildCurrentStep = parseInt(cachedMatch[1]);
          _buildTotalSteps = parseInt(cachedMatch[2]);
          _buildProgress = _buildCurrentStep / _buildTotalSteps;
          _buildStep = `Step ${_buildCurrentStep}/${_buildTotalSteps} (cached)`;
        }
      }

      // Detect download progress for base image pull
      const pullMatch = line.match(/(\d+\.\d+[MG]B)\s*\/\s*(\d+\.\d+[MG]B)/);
      if (pullMatch) {
        _buildStep = `Downloading: ${pullMatch[1]} / ${pullMatch[2]}`;
      }

      // Detect "exporting" / "writing" at the end
      if (line.includes('exporting to image') || line.includes('writing image')) {
        _buildProgress = 0.95;
        _buildStep = 'Finalizing image...';
      }
    };

    proc.stdout.on('data', (data) => {
      for (const line of data.toString().split('\n')) {
        if (line.trim()) parseLine(line);
      }
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
      // Docker buildkit sends most output to stderr
      for (const line of data.toString().split('\n')) {
        if (line.trim()) parseLine(line);
      }
    });

    proc.on('close', async (code) => {
      if (code === 0) {
        _buildProgress = 1;
        _buildStep = 'Complete';
        _buildStatus = 'built';
        await config.markImageBuilt();
        resolve();
      } else {
        _buildStatus = 'needs-rebuild';
        _buildError = stderr.slice(-200);
        _buildStep = 'Failed';
        reject(new Error(`docker build failed: ${stderr.slice(-500)}`));
      }
    });
  });
}

/**
 * Ensure the image is built and up to date. Builds if missing or packages changed.
 */
async function ensureImage() {
  const exists = await imageExists();
  const needsRebuild = await config.imageNeedsRebuild();

  if (!exists || needsRebuild) {
    await buildImage();
  } else {
    _buildStatus = 'built';
  }
}

/**
 * Get current image build status with progress details.
 */
function getBuildStatus() {
  return {
    status: _buildStatus,
    error: _buildError,
    progress: _buildProgress,
    step: _buildStep,
    currentStep: _buildCurrentStep,
    totalSteps: _buildTotalSteps,
  };
}

/**
 * Start a Docker container for an agent with Chrome profile mounted.
 */
async function startContainer({ agentId, noVNCPort, vncPort, apiKey }) {
  const cfg = await config.load();

  // Sync Chrome profile to staging directory
  const chromeProfileMount = await chromeSync.syncProfile(cfg.chromeProfile, agentId);

  // Ensure recordings directory exists
  await fs.promises.mkdir(RECORDINGS_DIR, { recursive: true });

  const containerName = `relay-agent-${agentId}`;

  const args = [
    'run', '-d',
    '-p', `${noVNCPort}:6080`,
    '-p', `${vncPort}:5900`,
    '--shm-size=2g',
    '-v', `${chromeProfileMount}:/home/computeruse/.config/chromium`,
    '-v', `${RECORDINGS_DIR}:/recordings`,
    '-e', `ANTHROPIC_API_KEY=${apiKey}`,
    '-e', 'WIDTH=1280',
    '-e', 'HEIGHT=720',
    '--name', containerName,
    `${IMAGE_NAME}:latest`,
  ];

  const containerId = await execDocker(args);
  return { containerId: containerId.trim(), containerName };
}

/**
 * Launch Google Chrome inside the container with the mounted profile.
 */
async function launchBrowser(containerName) {
  // Try chromium first, fall back to firefox-esr (which is in the base image)
  try {
    await execDocker([
      'exec', '-d', containerName,
      'bash', '-c',
      'DISPLAY=:1 chromium --no-sandbox --disable-gpu --start-maximized ' +
      '--no-first-run --user-data-dir=/home/computeruse/.config/chromium 2>/dev/null &',
    ]);
  } catch {
    await execDocker([
      'exec', '-d', containerName,
      'bash', '-c',
      'MOZ_DISABLE_CONTENT_SANDBOX=1 DISPLAY=:1 firefox-esr --no-remote 2>/dev/null &',
    ]);
  }
}

/**
 * Stop and remove a container.
 */
async function stopContainer(containerName) {
  try {
    await execDocker(['rm', '-f', containerName]);
  } catch {
    // Container may already be gone
  }
}

/**
 * Remove all relay-agent containers.
 */
async function cleanupAll() {
  try {
    const out = await execDocker(['ps', '-a', '--filter', 'name=relay-agent', '-q']);
    const ids = out.split('\n').filter(Boolean);
    for (const id of ids) {
      await execDocker(['rm', '-f', id]);
    }
  } catch {
    // Ignore cleanup errors
  }
}

/**
 * Execute a command inside a running container.
 */
async function execInContainer(containerName, command) {
  return execDocker(['exec', containerName, 'bash', '-c', command]);
}

module.exports = {
  execDocker,
  imageExists,
  buildImage,
  ensureImage,
  getBuildStatus,
  startContainer,
  launchBrowser,
  stopContainer,
  cleanupAll,
  execInContainer,
  RECORDINGS_DIR,
  IMAGE_NAME,
};
