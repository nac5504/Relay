const express = require('express');
const config = require('../lib/config');
const chromeSync = require('../lib/chromeProfileSync');
const docker = require('../lib/dockerManager');

const router = express.Router();

// GET /config — return current settings
router.get('/', async (req, res) => {
  try {
    const cfg = await config.load();
    res.json(cfg);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// PUT /config — update settings (chrome profile, packages)
router.put('/', async (req, res) => {
  try {
    const { chromeProfile, aptPackages, pipPackages } = req.body;
    const cfg = await config.update({ chromeProfile, aptPackages, pipPackages });
    res.json(cfg);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /config/chrome-profiles — list detected Chrome profiles on the host
router.get('/chrome-profiles', async (req, res) => {
  try {
    const profiles = await chromeSync.detectProfiles();
    res.json(profiles);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /config/rebuild-image — trigger Docker image rebuild with current packages
router.post('/rebuild-image', async (req, res) => {
  try {
    // Start build in background, return immediately
    res.json({ status: 'building' });
    await docker.buildImage();
  } catch (err) {
    // Build status is tracked in dockerManager
    console.error('Image build failed:', err.message);
  }
});

// GET /config/image-status — check Docker image build status with progress
router.get('/image-status', async (req, res) => {
  try {
    const buildStatus = docker.getBuildStatus();
    const needsRebuild = await config.imageNeedsRebuild();

    if (buildStatus.status === 'building') {
      res.json({
        status: 'building',
        progress: buildStatus.progress,
        step: buildStatus.step,
        currentStep: buildStatus.currentStep,
        totalSteps: buildStatus.totalSteps,
      });
    } else if (needsRebuild) {
      res.json({ status: 'needs-rebuild' });
    } else {
      res.json({ status: buildStatus.status, error: buildStatus.error });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;
