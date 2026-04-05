import Anthropic from '@anthropic-ai/sdk';
import { getApiKey } from './config';
import * as registry from './agentRegistry';
import * as wsHub from './wsHub';

const MODEL = 'claude-sonnet-4-6';

const ENVIRONMENT_CONTEXT = `
The computer use agent runs inside a Linux Docker container with the following environment:
- Display: 1024x768 virtual desktop (Xvfb)
- Browser: Chromium (chromium-browser), Firefox ESR available
- Office suite: LibreOffice (Writer, Calc, Impress, Draw)
- Text editors: nano, vim, gedit
- Shell: bash with standard Unix utilities
- Python 3 with pip
- Internet access: yes
- Output files: the agent can write any file and mark it for retrieval by appending its absolute path to /tmp/relay_outputs.txt (one path per line)

The agent controls the computer by taking screenshots and using mouse/keyboard actions. It works best with clear, numbered step-by-step instructions.
`.trim();

const PLAN_AGENT_SYSTEM = `You are a planning assistant helping a user define a precise task for an autonomous computer use agent.

${ENVIRONMENT_CONTEXT}

Your job:
1. Understand what the user wants to accomplish
2. Ask 1-2 clarifying questions only if the task is genuinely ambiguous (file format, specific URL, target application, etc.)
3. Produce a concrete, numbered step-by-step plan the agent can execute
4. When the user confirms they want to proceed (says "go", "looks good", "implement", "start", "do it", "yes", or similar), call the begin_implementation tool with the final plan

Keep responses concise. If the task is already clear and specific, skip straight to proposing the plan. Do not overcomplicate — the agent is capable.`;

// Per-agent pending message buffer (polling-based so runPlanAgent can stay async)
const pendingMessages = new Map<string, string>();
const cancelledAgents = new Set<string>();

export function injectPlanMessage(agentId: string, text: string): void {
  pendingMessages.set(agentId, text);
}

export function cancelPlanAgent(agentId: string): void {
  cancelledAgents.add(agentId);
  pendingMessages.delete(agentId);
}

export async function runPlanAgent(
  agentId: string,
  onBeginImplementation: (finalPlan: string) => Promise<void>,
): Promise<void> {
  const agent = registry.get(agentId);
  if (!agent) return;

  const client = new Anthropic({ apiKey: getApiKey() });

  const messages: Anthropic.MessageParam[] = [
    { role: 'user', content: agent.task },
  ];

  // Echo initial task to UI
  wsHub.broadcast({
    type: 'plan_message',
    agentId,
    role: 'user',
    text: agent.task,
    timestamp: new Date().toISOString(),
  });

  while (true) {
    if (cancelledAgents.has(agentId)) {
      cancelledAgents.delete(agentId);
      break;
    }

    const current = registry.get(agentId);
    if (!current || current.status === 'stopped' || current.status === 'working') break;

    // Stream plan agent response
    console.log(`[planAgent] Calling Claude for ${agentId} (${messages.length} messages)`);
    let fullText = '';
    let toolName = '';
    let toolInputJson = '';
    let toolUseId = '';
    let inToolUse = false;

    try {
      const stream = client.messages.stream({
        model: MODEL,
        max_tokens: 1024,
        system: PLAN_AGENT_SYSTEM,
        tools: [
          {
            name: 'begin_implementation',
            description: 'Call this when the user confirms they want to proceed. Passes the final plan to the computer use agent.',
            input_schema: {
              type: 'object' as const,
              properties: {
                finalPlan: {
                  type: 'string',
                  description: 'The complete, step-by-step task description for the computer use agent.',
                },
              },
              required: ['finalPlan'],
            },
          },
        ],
        messages,
      });

      for await (const event of stream) {
        if (cancelledAgents.has(agentId)) break;

        if (event.type === 'content_block_start') {
          if (event.content_block.type === 'tool_use') {
            inToolUse = true;
            toolName = event.content_block.name;
            toolUseId = event.content_block.id;
            toolInputJson = '';
          }
        } else if (event.type === 'content_block_delta') {
          if (event.delta.type === 'text_delta') {
            fullText += event.delta.text;
            wsHub.broadcast({
              type: 'plan_message',
              agentId,
              role: 'assistant',
              text: event.delta.text,
              streaming: true,
              timestamp: new Date().toISOString(),
            });
          } else if (event.delta.type === 'input_json_delta') {
            toolInputJson += event.delta.partial_json;
          }
        } else if (event.type === 'content_block_stop') {
          if (inToolUse) {
            inToolUse = false;
          }
        }
      }
    } catch (err) {
      console.error(`[planAgent] Stream error for ${agentId}:`, (err as Error).message, (err as Error).stack);
      break;
    }

    console.log(`[planAgent] Response done — text: ${fullText.length} chars, tool: ${toolName || 'none'}`);

    // Append assistant turn to history
    const assistantContent: Anthropic.ContentBlockParam[] = [];
    if (fullText) assistantContent.push({ type: 'text', text: fullText });
    if (toolName) {
      let toolInput: Record<string, string> = {};
      try { toolInput = JSON.parse(toolInputJson); } catch { /* empty */ }
      assistantContent.push({ type: 'tool_use', id: toolUseId, name: toolName, input: toolInput });

      // Handle begin_implementation
      if (toolName === 'begin_implementation' && toolInput.finalPlan) {
        messages.push({ role: 'assistant', content: assistantContent });

        // Acknowledge the tool call so conversation is valid
        messages.push({
          role: 'user',
          content: [{ type: 'tool_result', tool_use_id: toolUseId, content: 'Implementation started.' }],
        });

        wsHub.broadcast({ type: 'plan_complete', agentId, timestamp: new Date().toISOString() });
        registry.update(agentId, { task: toolInput.finalPlan });

        await onBeginImplementation(toolInput.finalPlan);
        break;
      }
    }
    if (assistantContent.length > 0) {
      messages.push({ role: 'assistant', content: assistantContent });
    }

    // Wait for next user message (poll with 200ms interval, 5 min timeout)
    console.log(`[planAgent] Waiting for user message for ${agentId}...`);
    const userMsg = await pollForMessage(agentId, 300_000);
    if (!userMsg) { console.log(`[planAgent] No message received — exiting`); break; }

    console.log(`[planAgent] Got user message: "${userMsg.slice(0, 60)}"`);
    pendingMessages.delete(agentId);
    messages.push({ role: 'user', content: userMsg });
    wsHub.broadcast({
      type: 'plan_message',
      agentId,
      role: 'user',
      text: userMsg,
      timestamp: new Date().toISOString(),
    });
  }
}

async function pollForMessage(agentId: string, timeoutMs: number): Promise<string | null> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (cancelledAgents.has(agentId)) return null;
    const agent = registry.get(agentId);
    if (!agent || agent.status === 'stopped') return null;
    const msg = pendingMessages.get(agentId);
    if (msg !== undefined) return msg;
    await new Promise<void>((r) => setTimeout(r, 200));
  }
  return null;
}
