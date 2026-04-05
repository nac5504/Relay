import Anthropic from '@anthropic-ai/sdk';
import { getApiKey } from './config';
import * as registry from './agentRegistry';
import * as wsHub from './wsHub';

const MODEL = 'claude-haiku-4-5';

const ENVIRONMENT_CONTEXT = `
The computer use agent runs inside a Linux Docker container with the following environment:

Display: 2560x1440 virtual desktop (Xvfb on DISPLAY=:1)

## Exact application commands (use these — do NOT guess)
IMPORTANT: Always prefix with DISPLAY=:1. Prefer Chromium for all web tasks.
- Chromium (PREFERRED): DISPLAY=:1 chromium-browser
- Firefox: DISPLAY=:1 firefox-esr
- LibreOffice Writer: DISPLAY=:1 libreoffice --writer
- LibreOffice Calc: DISPLAY=:1 libreoffice --calc
- LibreOffice Impress: DISPLAY=:1 libreoffice --impress
- File manager: DISPLAY=:1 nautilus
- Text editor (GUI): DISPLAY=:1 gedit
- Text editor (terminal): nano, vim
- Terminal: xterm

## Opening URLs directly (fastest approach)
- DISPLAY=:1 chromium-browser "https://www.youtube.com" &
- DISPLAY=:1 firefox-esr "https://www.google.com" &

## Shell & tools
- bash with standard Unix utilities (curl, wget, python3, pip, git)
- Python 3 with pip
- Internet access: yes

## Output files
The agent can write any file and mark it for retrieval by appending its absolute path to /tmp/relay_outputs.txt (one path per line).

The agent controls the computer by taking screenshots and using mouse/keyboard actions. It works best with clear, numbered step-by-step instructions.
`.trim();

const PLAN_AGENT_SYSTEM = `You are a planning assistant helping a user define a precise task for an autonomous computer use agent.

${ENVIRONMENT_CONTEXT}

Your job:
1. Understand what the user wants
2. Ask 1-2 clarifying questions ONLY if genuinely ambiguous
3. Propose a concise plan
4. When the user confirms ("go", "yes", "do it", etc.), call begin_implementation with:
   - finalPlan: the step-by-step task
   - mode: "bash_only" if the task can be done entirely via command line (file creation, text processing, code execution, API calls via curl) or "computer_use" if it requires GUI interaction (browsing websites, using LibreOffice GUI, clicking through apps)

IMPORTANT: Prefer "bash_only" mode whenever possible — it's 10x faster and cheaper. Only use "computer_use" when the task genuinely requires seeing/interacting with a GUI (e.g., navigating a website, filling forms, using a visual app).

Examples of bash_only tasks: write a file, run a script, process data, create documents via CLI, make API calls
Examples of computer_use tasks: browse a website, fill out a form, use LibreOffice GUI, take screenshots of web pages`;

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
  onBeginImplementation: (finalPlan: string, mode: 'bash_only' | 'computer_use') => Promise<void>,
): Promise<void> {
  const agent = registry.get(agentId);
  if (!agent) return;

  const client = new Anthropic({ apiKey: getApiKey() });

  const messages: Anthropic.MessageParam[] = [];

  if (agent.task) {
    // Task provided up front — send it as the first user message
    messages.push({ role: 'user', content: agent.task });
    wsHub.broadcast({
      type: 'plan_message',
      agentId,
      role: 'user',
      text: agent.task,
      timestamp: new Date().toISOString(),
    });
  } else {
    // No task yet — greet and wait for the user's first message
    const greeting = "What would you like me to work on?";
    wsHub.broadcast({
      type: 'plan_message',
      agentId,
      role: 'assistant',
      text: greeting,
      timestamp: new Date().toISOString(),
    });

    console.log(`[planAgent] No task — waiting for initial message for ${agentId}...`);
    const firstMsg = await pollForMessage(agentId, 600_000);
    if (!firstMsg) { console.log(`[planAgent] No initial message — exiting`); return; }

    pendingMessages.delete(agentId);
    registry.update(agentId, { task: firstMsg });
    messages.push({ role: 'user', content: firstMsg });
    wsHub.broadcast({
      type: 'plan_message',
      agentId,
      role: 'user',
      text: firstMsg,
      timestamp: new Date().toISOString(),
    });
  }

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
            description: 'Call this when the user confirms they want to proceed.',
            input_schema: {
              type: 'object' as const,
              properties: {
                finalPlan: {
                  type: 'string',
                  description: 'The complete, step-by-step task description.',
                },
                mode: {
                  type: 'string',
                  enum: ['bash_only', 'computer_use'],
                  description: 'bash_only for CLI-only tasks (faster/cheaper), computer_use for GUI tasks.',
                },
              },
              required: ['finalPlan', 'mode'],
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

        const mode = (toolInput.mode === 'bash_only' ? 'bash_only' : 'computer_use') as 'bash_only' | 'computer_use';
        console.log(`[planAgent] Mode: ${mode}`);
        wsHub.broadcast({ type: 'plan_complete', agentId, mode, timestamp: new Date().toISOString() });
        registry.update(agentId, { task: toolInput.finalPlan });

        await onBeginImplementation(toolInput.finalPlan, mode);
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

  // Plan agent exited without calling begin_implementation — clean up status
  const finalAgent = registry.get(agentId);
  if (finalAgent && (finalAgent.status === 'starting' || finalAgent.status === 'planning')) {
    console.log(`[planAgent] Exited without implementation for ${agentId} — marking as stopped`);
    registry.update(agentId, { status: 'stopped' });
    wsHub.broadcast({ type: 'agent_update', agentId, status: 'stopped' });
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
