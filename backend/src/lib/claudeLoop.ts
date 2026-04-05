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
const MAX_ITERATIONS = 50;

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

After each step, take a screenshot and carefully evaluate if you have achieved the right outcome. Explicitly show your thinking: "I have evaluated step X..." If not correct, try again. Only when you confirm a step was executed correctly should you move on to the next one.

When you produce output files the user should receive (documents, images, spreadsheets, etc.), write their absolute paths to /tmp/relay_outputs.txt inside the container, one path per line. Example:
  echo "/home/computeruse/report.pdf" >> /tmp/relay_outputs.txt

If you need clarification or reach a decision point requiring user input, say "Waiting for input:" followed by your question and stop.`;

    const messages: AnthropicMessage[] = [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: initScreenshot } },
      ],
    }];

    registry.update(agentId, { status: 'working', messages });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: agent.cost });

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
              display_width_px: 1024,
              display_height_px: 768,
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
        wsHub.broadcast({ type: 'agent_update', agentId, status: 'error' });
        break;
      }

      // Log response summary
      const textBlocks = response.content.filter((b) => b.type === 'text').map((b) => (b as { text: string }).text);
      const toolUses = response.content.filter((b) => b.type === 'tool_use').map((b) => (b as { name: string; input: unknown }).name);
      console.log(`[loop:${agentId.slice(0,8)}] Response — stop: ${response.stop_reason}, text: ${textBlocks.map(t => t.slice(0,80)).join(' | ') || '(none)'}, tools: [${toolUses.join(', ')}]`);

      messages.push({ role: 'assistant', content: response.content as AnthropicMessage['content'] });

      // Broadcast text blocks; detect waiting-for-input state
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
          // Bash: execute command inside container, return stdout/stderr as text
          const input = block.input as { command?: string; restart?: boolean };
          const command = input.command ?? '';

          if (input.restart) {
            console.log(`[loop:${agentId.slice(0,8)}] 💻 bash restart`);
            toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: [{ type: 'text', text: 'Bash restarted.' }] });
            continue;
          }

          console.log(`[loop:${agentId.slice(0,8)}] 💻 $ ${command.slice(0, 100)}`);
          let output = '';
          try {
            output = await docker.execInContainer(containerName, command);
            if (output.trim()) console.log(`[loop:${agentId.slice(0,8)}]    → ${output.trim()}`);
          } catch (err) {
            output = `Error: ${(err as Error).message}`;
            console.warn(`[loop:${agentId.slice(0,8)}]    → ${output}`);
          }

          const event = {
            id: uuidv4(),
            timestampMs: actionStartMs,
            actionType: 'bash',
            description: `Ran: ${command.slice(0, 60)}${command.length > 60 ? '…' : ''}`,
            coordinates: null,
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

          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: [{ type: 'text', text: output }] });

        } else if (block.name === 'str_replace_based_edit_tool') {
          // Text editor: execute via bash inside container, return result
          const input = block.input as { command: string; path: string; old_str?: string; new_str?: string; insert_line?: number; new_file_text?: string };
          console.log(`[loop:${agentId.slice(0,8)}] 📝 ${input.command} ${input.path}`);
          let output = '';
          try {
            if (input.command === 'view') {
              output = await docker.execInContainer(containerName, `cat "${input.path}" 2>&1 || echo "File not found"`);
            } else if (input.command === 'create') {
              const escaped = (input.new_file_text ?? '').replace(/'/g, "'\\''");
              await docker.execInContainer(containerName, `mkdir -p "$(dirname '${input.path}')" && printf '%s' '${escaped}' > '${input.path}'`);
              output = 'File created successfully';
            } else if (input.command === 'str_replace') {
              const tmpScript = `/tmp/relay_edit_${Date.now()}.py`;
              const script = `
import sys
path = sys.argv[1]
old = sys.argv[2]
new = sys.argv[3]
with open(path, 'r') as f:
    content = f.read()
if old not in content:
    print("ERROR: old_str not found")
    sys.exit(1)
with open(path, 'w') as f:
    f.write(content.replace(old, new, 1))
print("OK")
`.trim();
              await docker.execInContainer(containerName, `cat > ${tmpScript} << 'PYEOF'\n${script}\nPYEOF`);
              output = await docker.execInContainer(containerName,
                `python3 ${tmpScript} '${input.path}' '${(input.old_str ?? '').replace(/'/g, "'\\''")}' '${(input.new_str ?? '').replace(/'/g, "'\\''")}'`);
            } else if (input.command === 'insert') {
              output = await docker.execInContainer(containerName,
                `sed -i '${input.insert_line}a\\${(input.new_str ?? '').replace(/'/g, "'\\''")}' '${input.path}' && echo "OK"`);
            }
          } catch (err) {
            output = `Error: ${(err as Error).message}`;
          }

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
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'error' });
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
