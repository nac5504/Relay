import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuidv4 } from 'uuid';
import * as registry from './agentRegistry';
import * as wsHub from './wsHub';
import * as docker from './dockerManager';
import * as outputManager from './outputManager';
import * as recordingManager from './recordingManager';
import { getApiKey } from './config';

const MODEL = 'claude-sonnet-4-6';
const MAX_ITERATIONS = 50;

function parsePlanSteps(planText: string): string[] {
  const steps: string[] = [];
  for (const line of planText.split('\n')) {
    const match = line.match(/^\s*(\d+)\.\s+(.+)/);
    if (match) steps.push(match[2].trim());
  }
  return steps;
}

/**
 * Bash-only agent loop — no screenshots, no GUI. Uses bash + text_editor tools only.
 * Much faster and cheaper than the full computer use loop.
 */
export async function runBashLoop(agentId: string): Promise<void> {
  const agent = registry.get(agentId);
  if (!agent) return;

  const { containerName, sessionId } = agent;
  if (!containerName) throw new Error('Agent has no container');

  const client = new Anthropic({ apiKey: getApiKey() });
  let iterations = 0;

  const systemPrompt = `You are an autonomous agent running inside a Linux Docker container. Complete the following task: ${agent.task}

You have access to bash and a text editor. Work efficiently — execute commands, create files, process data.

The home directory is /home/computeruse. When you produce output files, write their paths to /tmp/relay_outputs.txt:
  echo "/path/to/file" >> /tmp/relay_outputs.txt

When done, state "Task completed." and stop.`;

  const messages: Anthropic.MessageParam[] = [
    { role: 'user', content: systemPrompt },
  ];

  console.log(`[bash:${agentId.slice(0,8)}] Starting bash-only loop`);
  registry.update(agentId, { status: 'working' });
  wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: 0 });

  // Parse plan steps and broadcast checklist
  const planSteps = parsePlanSteps(agent.task);
  if (planSteps.length > 0) {
    wsHub.broadcast({ type: 'task_list', agentId, steps: planSteps });
    wsHub.broadcast({ type: 'task_update', agentId, stepIndex: 0, status: 'active' });
  }
  let stepsCompleted = 0;

  try {
    while (iterations < MAX_ITERATIONS) {
      iterations++;
      console.log(`[bash:${agentId.slice(0,8)}] Iteration ${iterations}`);

      const currentAgent = registry.get(agentId);
      if (!currentAgent || currentAgent.status === 'stopped') break;

      const response = await client.messages.create({
        model: MODEL,
        max_tokens: 4096,
        tools: [
          {
            name: 'bash',
            description: 'Run a bash command in the container. Returns stdout/stderr.',
            input_schema: {
              type: 'object' as const,
              properties: {
                command: { type: 'string', description: 'The bash command to run' },
                restart: { type: 'boolean', description: 'Set to true to restart the bash session' },
              },
            },
          },
          {
            name: 'text_editor',
            description: 'View, create, or edit files.',
            input_schema: {
              type: 'object' as const,
              properties: {
                command: { type: 'string', enum: ['view', 'create', 'str_replace', 'insert'] },
                path: { type: 'string', description: 'Absolute file path' },
                file_text: { type: 'string', description: 'Full file content (for create)' },
                old_str: { type: 'string', description: 'String to replace (for str_replace)' },
                new_str: { type: 'string', description: 'Replacement string' },
                insert_line: { type: 'number', description: 'Line number to insert after' },
              },
              required: ['command', 'path'],
            },
          },
        ],
        messages,
      });

      // Log response
      const textBlocks = response.content.filter((b) => b.type === 'text').map((b) => (b as { text: string }).text);
      const toolUses = response.content.filter((b) => b.type === 'tool_use').map((b) => (b as { name: string }).name);
      console.log(`[bash:${agentId.slice(0,8)}] Response — stop: ${response.stop_reason}, tools: [${toolUses.join(', ')}], text: ${textBlocks.map(t => t.slice(0,80)).join(' | ') || '(none)'}`);

      messages.push({ role: 'assistant', content: response.content as Anthropic.ContentBlockParam[] });

      // Broadcast text
      for (const block of response.content) {
        if (block.type === 'text' && block.text.trim()) {
          wsHub.broadcast({ type: 'chat_message', agentId, role: 'assistant', text: block.text, timestamp: new Date().toISOString() });
        }
      }

      // No tool use — task complete
      const toolUseBlocks = response.content.filter((b) => b.type === 'tool_use');
      if (toolUseBlocks.length === 0) {
        if (response.stop_reason === 'end_turn') break;
        continue;
      }

      // Execute tools
      const toolResults: Anthropic.ToolResultBlockParam[] = [];

      for (const block of toolUseBlocks) {
        if (block.type !== 'tool_use') continue;

        if (block.name === 'bash') {
          const input = block.input as { command?: string; restart?: boolean };
          console.log(`[bash:${agentId.slice(0,8)}] 💻 $ ${(input.command ?? 'restart').slice(0, 120)}`);

          let output: string;
          try {
            output = await docker.executeBash(containerName, input);
          } catch (err) {
            output = `Error: ${(err as Error).message}`;
          }
          if (output.trim()) console.log(`[bash:${agentId.slice(0,8)}]    → ${output.trim().slice(0, 200)}`);

          wsHub.broadcast({ type: 'chat_message', agentId, role: 'action', text: `$ ${(input.command ?? 'restart').slice(0, 80)}`, timestamp: new Date().toISOString() });
          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: output });

        } else if (block.name === 'text_editor') {
          const input = block.input as Record<string, unknown>;
          console.log(`[bash:${agentId.slice(0,8)}] 📝 ${input.command} ${input.path}`);

          let output: string;
          try {
            output = await docker.executeTextEditor(containerName, input);
          } catch (err) {
            output = `Error: ${(err as Error).message}`;
          }
          if (output.trim()) console.log(`[bash:${agentId.slice(0,8)}]    → ${output.trim().slice(0, 200)}`);

          wsHub.broadcast({ type: 'chat_message', agentId, role: 'action', text: `${input.command}: ${input.path}`, timestamp: new Date().toISOString() });
          toolResults.push({ type: 'tool_result', tool_use_id: block.id, content: output });
        }
      }

      messages.push({ role: 'user', content: toolResults });

      // Progress plan steps — each successful tool call advances one step
      if (planSteps.length > 0 && toolResults.length > 0 && stepsCompleted < planSteps.length) {
        // Check if any tool had an error
        const hasError = toolResults.some(r => typeof r.content === 'string' && r.content.startsWith('Error:'));
        if (!hasError) {
          wsHub.broadcast({ type: 'task_update', agentId, stepIndex: stepsCompleted, status: 'completed' });
          stepsCompleted++;
          if (stepsCompleted < planSteps.length) {
            wsHub.broadcast({ type: 'task_update', agentId, stepIndex: stepsCompleted, status: 'active' });
          }
        }
      }

      const newCost = (registry.get(agentId)?.cost ?? 0) + 0.003;
      registry.update(agentId, { cost: newCost });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'working', cost: newCost });
    }

  } catch (err) {
    console.error(`[bash:${agentId.slice(0,8)}] Error:`, (err as Error).message);
    registry.update(agentId, { status: 'error', error: (err as Error).message });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'error' });
  } finally {
    // Retrieve output files
    const finalAgent = registry.get(agentId);
    try {
      if (finalAgent?.containerName) {
        const files = await outputManager.retrieveOutputs(finalAgent.containerName, agentId);
        if (files.length > 0) {
          wsHub.broadcast({ type: 'files_ready', agentId, files });
        }
      }
    } catch (err) {
      console.warn(`[bash:${agentId.slice(0,8)}] Output retrieval failed: ${(err as Error).message}`);
    }

    // Stop recording
    if (finalAgent?.recordingProc) {
      await recordingManager.stopRecording(finalAgent.recordingProc, containerName, sessionId);
    }
    recordingManager.saveTimeline(sessionId);

    const finalStatus = registry.get(agentId)?.status;
    if (finalStatus !== 'stopped' && finalStatus !== 'error') {
      registry.update(agentId, { status: 'completed' });
      wsHub.broadcast({ type: 'agent_update', agentId, status: 'completed', cost: registry.get(agentId)?.cost ?? 0 });
    }
    console.log(`[bash:${agentId.slice(0,8)}] Loop finished (${iterations} iterations)`);
  }
}
