import { Router, Request, Response } from 'express';
import fs from 'fs';
import path from 'path';
import { recordingPath, timelinePath } from '../lib/recordingManager';
import { listOutputs, outputDir } from '../lib/outputManager';

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

// GET /recordings/:agentId/outputs — list output files
router.get('/:agentId/outputs', async (req: Request, res: Response) => {
  const files = await listOutputs(req.params.agentId);
  res.json({ files });
});

// GET /recordings/:agentId/outputs/:filename — download a specific output file
router.get('/:agentId/outputs/:filename', (req: Request, res: Response) => {
  const { agentId, filename } = req.params;
  if (filename.includes('..') || filename.includes('/')) {
    return res.status(400).json({ error: 'Invalid filename' });
  }
  const filePath = path.join(outputDir(agentId), filename);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'Not found' });
  res.download(filePath);
});

export default router;
