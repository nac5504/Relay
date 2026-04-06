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
import { ComputerToolInput, AnthropicMessage, StructuredPlan } from './types';
import { checkStallGuard, createStallGuardState, StallGuardConfig } from './stallGuard';

const MODEL = 'claude-sonnet-4-6';
const MAX_TOKENS = 4096;
const LOOP_DELAY_MS = 2000;
const MAX_ITERATIONS = 200;

const STALL_GUARD: StallGuardConfig = {
  stepIterBudget: 30,
  stepTimeBudgetMs: 4 * 60_000,
  maxTaskMs: 20 * 60_000,
  nudgeAtFrac: 0.7,
};

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

/** Append a [System] text block to the trailing user message so the next API
 * call carries the note alongside any tool_results. Safe no-op if the last
 * message isn't a user message. */
function appendSystemTextToLastUserMessage(messages: AnthropicMessage[], text: string): void {
  const last = messages[messages.length - 1];
  if (!last || last.role !== 'user') return;
  last.content.push({ type: 'text', text });
}

function buildStepsPrompt(plan: StructuredPlan): string {
  return plan.steps.map(s =>
    `${s.stepNumber}. ${s.detailedInstructions}\n   Suggested tools: ${s.suggestedTools.join(', ')}`
  ).join('\n\n');
}

function handleStepComplete(agentId: string, plan: StructuredPlan, stepNumber: number): string {
  const stepIdx = plan.steps.findIndex(s => s.stepNumber === stepNumber);
  if (stepIdx === -1) return `Step ${stepNumber} not found in plan.`;

  plan.steps[stepIdx].status = 'completed';

  // Set next step to active
  const nextStep = plan.steps.find(s => s.status === 'pending');
  if (nextStep) nextStep.status = 'active';

  registry.update(agentId, { plan });
  wsHub.broadcast({
    type: 'step_update',
    agentId,
    stepNumber,
    status: 'completed',
    timestamp: new Date().toISOString(),
  });

  if (nextStep) {
    wsHub.broadcast({
      type: 'step_update',
      agentId,
      stepNumber: nextStep.stepNumber,
      status: 'active',
      timestamp: new Date().toISOString(),
    });
  }

  return `Step ${stepNumber} marked as completed.${nextStep ? ` Proceeding to step ${nextStep.stepNumber}.` : ' All steps completed.'}`;
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

    // Read structured plan from agent state
    const plan = agent.plan;

    // Build system prompt with structured steps
    const stepsSection = plan ? `\n## Steps\n${buildStepsPrompt(plan)}\n\nAfter completing each step, you MUST call report_step_complete with the step number before proceeding to the next step.` : '';

    const systemPrompt = `You are controlling a computer to complete the following task: ${agent.task}
${stepsSection}

## Opening a browser
To open ANY website, use this SINGLE bash command (includes the wait):
  DISPLAY=:1 chromium --no-sandbox "https://example.com" & sleep 8
Then take a screenshot. The browser needs ~8 seconds on first launch to load.

## Already logged in
The browser has the user's real Chrome profile with all their cookies and sessions.
Gmail, GitHub, Twitter, YouTube, and all other sites the user uses are ALREADY LOGGED IN.
Do NOT try to sign in, enter credentials, or authenticate — just navigate directly.

## Other apps
  DISPLAY=:1 libreoffice --writer &
  DISPLAY=:1 libreoffice --calc &
  DISPLAY=:1 xterm &

## Workflow
After each step, take a screenshot and evaluate the result. Be concise. If correct, call report_step_complete and move on. If not, try once more.

## User messages
The user may send you messages while you're working. When you see a user message, read it carefully:
- If it changes the task, acknowledge and adjust your approach
- If it's feedback on your current action, incorporate it immediately
- If it's a new instruction, follow it
Always briefly acknowledge the user's message before continuing.

## Output files
When done, write file paths to /tmp/relay_outputs.txt:
  echo "/home/computeruse/report.pdf" >> /tmp/relay_outputs.txt

## Clarification
If you need clarification, say "Waiting for input:" followed by your question and stop.`;

    const messages: AnthropicMessage[] = [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: initScreenshot } },
      ],
    }];

    registry.update(agentId, { status: 'working', messages });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: agent.cost });

    // Initialize step tracking from structured plan
    if (plan && plan.steps.length > 0) {
      plan.steps[0].status = 'active';
      registry.update(agentId, { plan });
      wsHub.broadcast({
        type: 'plan_update',
        agentId,
        plan,
        timestamp: new Date().toISOString(),
      });
    }

    const stallState = createStallGuardState();

    while (iterations < MAX_ITERATIONS) {
      iterations++;

      // Stall guard: nudge → force-complete → task timeout
      const decision = checkStallGuard(stallState, STALL_GUARD, plan, iterations, agent.startedAt);
      if (decision.kind === 'task_timeout') {
        console.warn(`[loop:${agentId.slice(0,8)}] ⏱  ${decision.reason} — aborting`);
        registry.update(agentId, { status: 'error', error: decision.reason });
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'error', error: decision.reason });
        break;
      } else if (decision.kind === 'force_complete') {
        console.warn(`[loop:${agentId.slice(0,8)}] ⏭  force-completing step ${decision.stepNumber}`);
        if (plan) handleStepComplete(agentId, plan, decision.stepNumber);
        appendSystemTextToLastUserMessage(messages, decision.text);
      } else if (decision.kind === 'nudge') {
        console.log(`[loop:${agentId.slice(0,8)}] 📣 nudging model to wrap up current step`);
        appendSystemTextToLastUserMessage(messages, decision.text);
      }

      const pendingMsg = messageQueue.consumePending(agentId);
      if (pendingMsg) {
        messages.push({ role: 'user', content: [{ type: 'text', text: pendingMsg }] });
        wsHub.broadcast({ type: 'chat_message', agentId, role: 'user', text: pendingMsg, timestamp: new Date().toISOString() });
      }

      const currentAgent = registry.get(agentId);
      if (!currentAgent) break;
      if (currentAgent.status === 'stopped') break;
      if (currentAgent.status === 'paused') {
        // Paused via /stop — poll until resumed or stopped
        await new Promise<void>((r) => setTimeout(r, 500));
        iterations--; // don't count paused iterations against the cap
        continue;
      }
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
          ...(plan ? [{
            type: 'custom' as const,
            name: 'report_step_complete',
            description: 'Report that you have completed a step in the plan. Call this after finishing each step before moving to the next.',
            input_schema: {
              type: 'object' as const,
              properties: {
                stepNumber: { type: 'number', description: 'The step number (1-indexed) that was completed.' },
                summary: { type: 'string', description: 'Brief summary of what was done.' },
              },
              required: ['stepNumber'],
            },
          }] : []),
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

      // Broadcast text blocks and detect waiting-for-input state
      for (const block of response.content) {
        if (block.type === 'text' && block.text.trim()) {
          wsHub.broadcast({ type: 'chat_message', agentId, role: 'assistant', text: block.text, timestamp: new Date().toISOString() });

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

        } else if (block.name === 'report_step_complete' && plan) {
          const input = block.input as { stepNumber: number; summary?: string };
          console.log(`[loop:${agentId.slice(0,8)}] ✅ Step ${input.stepNumber} completed${input.summary ? `: ${input.summary.slice(0, 80)}` : ''}`);

          const resultText = handleStepComplete(agentId, plan, input.stepNumber);
          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: [{ type: 'text', text: resultText }] });
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
          const localDir = outputManager.outputDir(agentId);
          wsHub.broadcast({ type: 'files_ready', agentId, files, localDir });
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
