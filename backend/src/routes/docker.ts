import { Router, Request, Response } from 'express';
import { checkImageExists, getImageTag, resetImageReady, buildImageStreaming } from '../lib/dockerManager';
import * as wsHub from '../lib/wsHub';

const router = Router();

let buildInProgress = false;

router.get('/status', async (_req: Request, res: Response) => {
  try {
    const imageExists = await checkImageExists();
    res.json({ imageExists, imageTag: getImageTag() });
  } catch (e) {
    res.status(500).json({ error: (e as Error).message });
  }
});

router.post('/build', (req: Request, res: Response) => {
  if (buildInProgress) {
    res.status(409).json({ status: 'already_building', message: 'A Docker build is already in progress' });
    return;
  }

  const force = req.body?.force ?? false;
  if (force) {
    resetImageReady();
  }

  buildInProgress = true;
  res.status(202).json({ status: 'building', message: 'Docker image build started' });

  setImmediate(async () => {
    try {
      await buildImageStreaming((line) => {
        wsHub.broadcast({ type: 'docker_build_progress', line });
      });
      wsHub.broadcast({ type: 'docker_build_complete', success: true });
      console.log('[docker] Image build completed successfully');
    } catch (e) {
      const error = (e as Error).message;
      wsHub.broadcast({ type: 'docker_build_complete', success: false, error });
      console.error('[docker] Image build failed:', error);
    } finally {
      buildInProgress = false;
    }
  });
});

export default router;
