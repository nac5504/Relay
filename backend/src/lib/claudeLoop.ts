import Anthropic from '@anthropic-ai/sdk';
import type {
  BetaToolComputerUse20251124,
  BetaToolTextEditor20250728,
  BetaToolBash20250124,
  BetaToolUnion,
} from '@anthropic-ai/sdk/resources/beta/messages';
import { v4 as uuidv4 } from 'uuid';
import * as registry from './agentRegistry';
import * as messageQueue from './messageQueue';
import * as recordingManager from './recordingManager';
import * as wsHub from './wsHub';
import * as docker from './dockerManager';
import { getApiKey } from './config';
import * as outputManager from './outputManager';
import { ComputerToolInput, AnthropicMessage } from './types';

const MODEL = 'claude-sonnet-4-6';
const MAX_TOKENS = 4096;
const LOOP_DELAY_MS = 2000;
const MAX_ITERATIONS = 200;

// Per docs: computer-use-2025-11-24 for Opus 4.6, Sonnet 4.6, Opus 4.5
const BETA_HEADER = 'computer-use-2025-11-24' as const;
const TOOL_TYPE = 'computer_20251124' as const;

function makeClient(): Anthropic {
  return new Anthropic({ apiKey: getApiKey() });
}

function describeAction(toolInput: ComputerToolInput): string {
  const { action } = toolInput;
  switch (action) {
    case 'screenshot':    return 'Captured screenshot';
    case 'left_click':   return `Clicked at (${toolInput.coordinate?.join(', ')})`;
    case 'right_click':  return `Right-clicked at (${toolInput.coordinate?.join(', ')})`;
    case 'double_click': return `Double-clicked at (${toolInput.coordinate?.join(', ')})`;
    case 'triple_click': return `Triple-clicked at (${toolInput.coordinate?.join(', ')})`;
    case 'mouse_move':   return `Moved mouse to (${toolInput.coordinate?.join(', ')})`;
    case 'type':         return `Typed "${(toolInput.text ?? '').slice(0, 50)}${(toolInput.text ?? '').length > 50 ? '…' : ''}"`;
    case 'key':          return `Pressed ${toolInput.key}`;
    case 'scroll':       return `Scrolled ${toolInput.scroll_direction ?? ''} at (${toolInput.coordinate?.join(', ')})`;
    case 'left_click_drag': return `Dragged from (${toolInput.startCoordinate?.join(', ')}) to (${toolInput.coordinate?.join(', ')})`;
    case 'wait':         return `Waited ${toolInput.duration ?? 1}s`;
    default:             return action;
  }
}

function parsePlanSteps(planText: string): string[] {
  const lines = planText.split('\n');
  const steps: string[] = [];
  for (const line of lines) {
    const match = line.match(/^\s*(\d+)\.\s+(.+)/);
    if (match) steps.push(match[2].trim());
  }
  return steps;
}

/**
 * Detect which step the agent is currently working on or has completed.
 * Returns { active: number | null, completed: number[] }
 */
function detectStepProgress(
  text: string,
  steps: string[],
  alreadyCompleted: Set<number>,
  currentActive: number,
): { active: number | null; completed: number[] } {
  const lower = text.toLowerCase();
  const completed: number[] = [];
  let active: number | null = null;

  // Find all "step N" references
  const stepRefs = [...lower.matchAll(/step\s+(\d+)/g)];
  const mentionedSteps = stepRefs.map(m => parseInt(m[1], 10) - 1).filter(n => n >= 0 && n < steps.length);

  // Positive evaluation words → completion
  const positiveWords = /correct|done|complete|success|achiev|verified|confirm|moved on|moving on|proceed|finished|accomplished/;
  // Active/working words → currently working
  const activeWords = /now|next|start|begin|work on|moving to|proceed to|let me|i'll|i will/;

  for (const m of stepRefs) {
    const stepIdx = parseInt(m[1], 10) - 1;
    if (stepIdx < 0 || stepIdx >= steps.length) continue;
    const pos = m.index!;
    const context = lower.slice(Math.max(0, pos - 50), pos + 200);

    if (positiveWords.test(context) && !alreadyCompleted.has(stepIdx)) {
      completed.push(stepIdx);
    }
    if (activeWords.test(context) && !alreadyCompleted.has(stepIdx) && !completed.includes(stepIdx)) {
      active = stepIdx;
    }
  }

  // If we detected a new active step higher than current, mark all previous uncompleted steps as done
  if (active !== null && active > currentActive) {
    for (let i = currentActive; i < active; i++) {
      if (!alreadyCompleted.has(i) && !completed.includes(i)) {
        completed.push(i);
      }
    }
  }

  // If no explicit step reference but positive evaluation, complete the current active step
  if (mentionedSteps.length === 0 && positiveWords.test(lower) && !alreadyCompleted.has(currentActive)) {
    completed.push(currentActive);
    active = currentActive + 1 < steps.length ? currentActive + 1 : null;
  }

  return { active, completed };
}

export async function runAgentLoop(agentId: string): Promise<void> {
  const agent = registry.get(agentId);
  if (!agent) return;

  const { containerName, sessionId } = agent;
  if (!containerName) throw new Error('Agent has no container');

  // Recording is already started in routes/agents.ts when container becomes ready
  let iterations = 0;

  try {
    const initScreenshot = await docker.screenshot(containerName);

    // System prompt per docs recommendation for reliable step-by-step execution
    const systemPrompt = `You are controlling a computer to complete the following task: ${agent.task}

## Opening a browser
To open ANY website, use this SINGLE bash command (includes the wait):
  DISPLAY=:1 chromium --no-sandbox "https://example.com" & sleep 8
Then take a screenshot. The browser needs ~8 seconds on first launch to load.
IMPORTANT: The browser is already logged into the user's accounts (Gmail, GitHub, Twitter, etc.) — do NOT try to sign in.

## Other apps
  DISPLAY=:1 libreoffice --writer &
  DISPLAY=:1 libreoffice --calc &
  DISPLAY=:1 xterm &

## Workflow
After each step, take a screenshot and evaluate the result. Be concise. If correct, move on. If not, try once more.

## Output files
When done, write file paths to /tmp/relay_outputs.txt:
  echo "/home/computeruse/report.pdf" >> /tmp/relay_outputs.txt

## User input
If you need clarification, say "Waiting for input:" followed by your question and stop.`;

    const messages: AnthropicMessage[] = [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: initScreenshot } },
      ],
    }];

    registry.update(agentId, { status: 'working', messages });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: agent.cost });

    // Parse plan into numbered steps and broadcast task list
    const planSteps = parsePlanSteps(agent.task);
    if (planSteps.length > 0) {
      wsHub.broadcast({ type: 'task_list', agentId, steps: planSteps });
      // Mark first step as active
      wsHub.broadcast({ type: 'task_update', agentId, timestampMs: Date.now() - (registry.get(agentId)?.startedAt ?? Date.now()), stepIndex: 0, status: 'active' });
    }
    const completedSteps = new Set<number>();
    let currentActiveStep = 0;

    while (iterations < MAX_ITERATIONS) {
      iterations++;

      const pendingMsg = messageQueue.consumePending(agentId);
      if (pendingMsg) {
        messages.push({ role: 'user', content: [{ type: 'text', text: pendingMsg }] });
        wsHub.broadcast({ type: 'chat_message', agentId, role: 'user', text: pendingMsg, timestamp: new Date().toISOString() });
      }

      const currentAgent = registry.get(agentId);
      if (!currentAgent) break;
      if (currentAgent.status === 'stopped') break;
      if (currentAgent.status === 'waiting' && !pendingMsg) {
        await new Promise<void>((r) => setTimeout(r, 500));
        continue;
      }

      // Call Claude Computer Use API — let TypeScript infer the response type
      console.log(`[loop:${agentId.slice(0,8)}] Iteration ${iterations} — calling Claude (${messages.length} messages)`);
      let response;
      try {
        response = await makeClient().beta.messages.create({
          model: MODEL,
          max_tokens: MAX_TOKENS,
          system: systemPrompt,
          tools: [
            {
              type: TOOL_TYPE,
              name: 'computer',
              display_width_px: 2560,
              display_height_px: 1440,
              display_number: 1,
            } satisfies BetaToolComputerUse20251124,
            {
              type: 'text_editor_20250728',
              name: 'str_replace_based_edit_tool',
            } satisfies BetaToolTextEditor20250728,
            {
              type: 'bash_20250124',
              name: 'bash',
            } satisfies BetaToolBash20250124,
          ] as BetaToolUnion[],
          messages,
          betas: [BETA_HEADER],
        });
      } catch (err) {
        console.error(`Claude API error for agent ${agentId}:`, (err as Error).message);
        registry.update(agentId, { status: 'error', error: (err as Error).message });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'error', error: (err as Error).message });
        break;
      }

      // Log response summary
      const textBlocks = response.content.filter((b) => b.type === 'text').map((b) => (b as { text: string }).text);
      const toolUses = response.content.filter((b) => b.type === 'tool_use').map((b) => (b as { name: string; input: unknown }).name);
      console.log(`[loop:${agentId.slice(0,8)}] Response — stop: ${response.stop_reason}, text: ${textBlocks.map(t => t.slice(0,80)).join(' | ') || '(none)'}, tools: [${toolUses.join(', ')}]`);

      messages.push({ role: 'assistant', content: response.content as AnthropicMessage['content'] });

      // Broadcast text blocks; detect step completions and waiting-for-input state
      for (const block of response.content) {
        if (block.type === 'text' && block.text.trim()) {
          wsHub.broadcast({ type: 'chat_message', agentId, role: 'assistant', text: block.text, timestamp: new Date().toISOString() });

          // Detect step progress from Claude's evaluation text
          if (planSteps.length > 0) {
            const progress = detectStepProgress(block.text, planSteps, completedSteps, currentActiveStep);
            for (const stepIdx of progress.completed) {
              const ts = Date.now() - (registry.get(agentId)?.startedAt ?? Date.now());
              completedSteps.add(stepIdx);
              wsHub.broadcast({ type: 'task_update', agentId, timestampMs: ts, stepIndex: stepIdx, status: 'completed' });
              recordingManager.logStepEvent(sessionId, { stepIndex: stepIdx, status: 'completed', timestampMs: ts, title: planSteps[stepIdx] });
              console.log(`[loop:${agentId.slice(0,8)}] ✅ Step ${stepIdx + 1} completed`);
            }
            if (progress.active !== null && progress.active !== currentActiveStep) {
              const ts = Date.now() - (registry.get(agentId)?.startedAt ?? Date.now());
              currentActiveStep = progress.active;
              wsHub.broadcast({ type: 'task_update', agentId, timestampMs: ts, stepIndex: currentActiveStep, status: 'active' });
              recordingManager.logStepEvent(sessionId, { stepIndex: currentActiveStep, status: 'active', timestampMs: ts, title: planSteps[currentActiveStep] });
              console.log(`[loop:${agentId.slice(0,8)}] 🔄 Now working on step ${currentActiveStep + 1}`);
            }
          }

          if (response.stop_reason === 'end_turn') {
            const lower = block.text.toLowerCase();
            if (lower.includes('waiting for input') || lower.includes('please confirm') ||
                lower.includes('let me know') || lower.includes('what would you like')) {
              registry.update(agentId, { status: 'waiting', waitingForInput: true });
              wsHub.broadcast({ type: 'agent_update', agentId, status: 'waiting', cost: currentAgent.cost });
            }
          }
        }
      }

      const toolUseBlocks = response.content.filter((b) => b.type === 'tool_use');

      if (toolUseBlocks.length === 0) {
        if (response.stop_reason === 'end_turn') {
          registry.update(agentId, { status: 'completed' });
          wsHub.broadcast({ type: 'agent_update', agentId, status: 'completed', cost: currentAgent.cost });
          break;
        }
        continue;
      }

      const toolResults: AnthropicMessage['content'] = [];

      for (const block of toolUseBlocks) {
        if (block.type !== 'tool_use') continue;
        const actionStartMs = Date.now() - agent.startedAt;

        if (block.name === 'computer') {
          // Computer use: execute action, take screenshot, return image
          const toolInput = block.input as ComputerToolInput;
          console.log(`[loop:${agentId.slice(0,8)}] 🖱  ${describeAction(toolInput)}`);

          try {
            await docker.executeAction(containerName, toolInput);
          } catch (err) {
            console.warn(`[loop:${agentId.slice(0,8)}] Action failed (${toolInput.action}): ${(err as Error).message}`);
          }

          await new Promise<void>((r) => setTimeout(r, 500));
          const postScreenshot = await docker.screenshot(containerName);

          const event = {
            id: uuidv4(),
            timestampMs: actionStartMs,
            actionType: toolInput.action,
            description: describeAction(toolInput),
            coordinates: toolInput.coordinate ? { x: toolInput.coordinate[0], y: toolInput.coordinate[1] } : null,
          };
          recordingManager.logAction(sessionId, event);
          wsHub.broadcast({ type: 'action', agentId, event });
          wsHub.broadcast({
            type: 'chat_message',
            agentId,
            role: 'action',
            text: event.description,
            timestamp: new Date().toISOString(),
          });

          toolResults.push({
            type: 'tool_result',
            tool_use_id: block.id,
            content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: postScreenshot } }],
          });

        } else if (block.name === 'bash') {
          const input = block.input as { command?: string; restart?: boolean };
          const command = input.command ?? '';
          console.log(`[loop:${agentId.slice(0,8)}] 💻 ${input.restart ? 'bash restart' : `$ ${command.slice(0, 100)}`}`);

          const output = await docker.executeBash(containerName, input);
          if (output.trim()) console.log(`[loop:${agentId.slice(0,8)}]    → ${output.trim().slice(0, 200)}`);

          const event = {
            id: uuidv4(),
            timestampMs: actionStartMs,
            actionType: 'bash',
            description: input.restart ? 'Restarted bash' : `Ran: ${command.slice(0, 60)}${command.length > 60 ? '…' : ''}`,
            coordinates: null,
          };
          recordingManager.logAction(sessionId, event);
          wsHub.broadcast({ type: 'action', agentId, event });
          wsHub.broadcast({ type: 'chat_message', agentId, role: 'action', text: event.description, timestamp: new Date().toISOString() });

          // Send bash output to frontend
          if (output.trim()) {
            wsHub.broadcast({ type: 'chat_message', agentId, role: 'output', text: output.trim().slice(0, 2000), timestamp: new Date().toISOString() });
          }

          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: [{ type: 'text', text: output }] });

        } else if (block.name === 'str_replace_based_edit_tool') {
          const input = block.input as Record<string, unknown>;
          console.log(`[loop:${agentId.slice(0,8)}] 📝 ${input.command} ${input.path}`);

          const output = await docker.executeTextEditor(containerName, input);
          if (output.trim()) console.log(`[loop:${agentId.slice(0,8)}]    → ${output.trim().slice(0, 200)}`);

          wsHub.broadcast({ type: 'action', agentId, event: { id: uuidv4(), timestampMs: actionStartMs, actionType: 'text_editor', description: `${input.command}: ${input.path}`, coordinates: null } });
          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: [{ type: 'text', text: output }] });
        }
      }

      messages.push({ role: 'user', content: toolResults });

      const newCost = (registry.get(agentId)?.cost ?? 0) + 0.015;
      registry.update(agentId, { cost: newCost, messages });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: newCost });

      await new Promise<void>((r) => setTimeout(r, LOOP_DELAY_MS));
    }

  } catch (err) {
    console.error(`Agent loop error (${agentId}):`, err);
    registry.update(agentId, { status: 'error', error: (err as Error).message });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'error', error: (err as Error).message });
  } finally {
    const finalAgent = registry.get(agentId);
    if (finalAgent?.recordingProc) {
      await recordingManager.stopRecording(finalAgent.recordingProc, containerName, sessionId);
    }
    recordingManager.saveTimeline(sessionId);

    // Retrieve files the agent marked for output before container is cleaned up
    try {
      if (finalAgent?.containerName) {
        const files = await outputManager.retrieveOutputs(finalAgent.containerName, agentId);
        if (files.length > 0) {
          wsHub.broadcast({ type: 'files_ready', agentId, files });
        }
      }
    } catch (err) {
      console.warn(`[outputs] Retrieval failed: ${(err as Error).message}`);
    }

    const finalStatus = registry.get(agentId)?.status;
    if (finalStatus !== 'stopped' && finalStatus !== 'error') {
      registry.update(agentId, { status: 'completed' });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'completed', cost: registry.get(agentId)?.cost ?? 0 });
    }
  }
}
