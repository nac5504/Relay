import { Router, Request, Response } from 'express';
import fs from 'fs';
import { recordingPath, timelinePath } from '../lib/recordingManager';

const router = Router();

// GET /recordings/:sessionId/video
router.get('/:sessionId/video', (req: Request, res: Response) => {
  const filePath = recordingPath(req.params.sessionId);

  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'Recording not found' });
  }

  const stat = fs.statSync(filePath);
  const fileSize = stat.size;
  const range = req.headers.range;

  if (range) {
    const parts = range.replace(/bytes=/, '').split('-');
    const start = parseInt(parts[0], 10);
    const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
    const chunkSize = end - start + 1;

    res.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${fileSize}`,
      'Accept-Ranges': 'bytes',
      'Content-Length': chunkSize,
      'Content-Type': 'video/mp4',
    });
    fs.createReadStream(filePath, { start, end }).pipe(res);
  } else {
    res.writeHead(200, {
      'Content-Length': fileSize,
      'Content-Type': 'video/mp4',
    });
    fs.createReadStream(filePath).pipe(res);
  }
});

// GET /recordings/:sessionId/timeline
router.get('/:sessionId/timeline', (req: Request, res: Response) => {
  const filePath = timelinePath(req.params.sessionId);

  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'Timeline not found' });
  }

  res.json(JSON.parse(fs.readFileSync(filePath, 'utf8')));
});

export default router;
