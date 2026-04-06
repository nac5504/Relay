/**
 * Task-agnostic stall prevention for agent loops.
 *
 * Layers of defense (top to bottom = earliest to last-resort):
 *   1. Soft nudge — at NUDGE_AT_FRAC of the per-step budget, append a text
 *      block to the next user message asking the model to wrap up. One-shot
 *      per step. The model gets a chance to land gracefully.
 *   2. Hard cutoff — at 100% of the per-step budget, the loop force-completes
 *      the active step (marks it done, advances the plan) and tells the model
 *      to move on. Prevents one step from eating the entire iteration cap.
 *   3. Wall-clock guard — if the whole task exceeds MAX_TASK_MS, break the
 *      loop. Catches cases where one tool call hangs and iteration counts
 *      can't see it.
 *
 * State is per-loop-invocation, not persisted in the registry.
 */

import { StructuredPlan } from './types';

export interface StallGuardConfig {
  /** Max iterations the loop can spend on a single plan step. */
  stepIterBudget: number;
  /** Max wall-clock ms the loop can spend on a single plan step. */
  stepTimeBudgetMs: number;
  /** Max wall-clock ms for the entire task, regardless of step state. */
  maxTaskMs: number;
  /** Fraction of step budget at which the soft nudge fires (0..1). */
  nudgeAtFrac: number;
}

export interface StallGuardState {
  activeStepNumber: number | null;
  stepStartedAt: number;
  stepStartIter: number;
  nudgedThisStep: boolean;
}

export function createStallGuardState(): StallGuardState {
  return {
    activeStepNumber: null,
    stepStartedAt: Date.now(),
    stepStartIter: 0,
    nudgedThisStep: false,
  };
}

export type StallGuardDecision =
  | { kind: 'continue' }
  | { kind: 'nudge'; text: string }
  | { kind: 'force_complete'; stepNumber: number; text: string }
  | { kind: 'task_timeout'; reason: string };

/**
 * Inspect the current loop state and decide whether to nudge, force-complete,
 * or abort. Mutates `state` to track per-step counters and one-shot flags.
 */
export function checkStallGuard(
  state: StallGuardState,
  config: StallGuardConfig,
  plan: StructuredPlan | undefined,
  iteration: number,
  taskStartedAt: number,
): StallGuardDecision {
  // Layer 3: global wall-clock guard (works even without a plan)
  const taskElapsedMs = Date.now() - taskStartedAt;
  if (taskElapsedMs > config.maxTaskMs) {
    return {
      kind: 'task_timeout',
      reason: `Task exceeded ${Math.round(config.maxTaskMs / 60000)}min wall-clock budget`,
    };
  }

  // Without a plan, per-step tracking has nothing to anchor to.
  if (!plan) return { kind: 'continue' };

  const activeStep = plan.steps.find(s => s.status === 'active');
  if (!activeStep) return { kind: 'continue' };

  // Detect step transition → reset per-step counters
  if (state.activeStepNumber !== activeStep.stepNumber) {
    state.activeStepNumber = activeStep.stepNumber;
    state.stepStartedAt = Date.now();
    state.stepStartIter = iteration;
    state.nudgedThisStep = false;
  }

  const stepIters = iteration - state.stepStartIter;
  const stepElapsedMs = Date.now() - state.stepStartedAt;
  const overIters = stepIters >= config.stepIterBudget;
  const overTime = stepElapsedMs >= config.stepTimeBudgetMs;

  // Layer 2: hard cutoff
  if (overIters || overTime) {
    const reason = overIters
      ? `iteration budget exhausted (${stepIters}/${config.stepIterBudget})`
      : `time budget exhausted (${Math.round(stepElapsedMs / 1000)}s/${Math.round(config.stepTimeBudgetMs / 1000)}s)`;
    return {
      kind: 'force_complete',
      stepNumber: activeStep.stepNumber,
      text: `[System] Step ${activeStep.stepNumber} has been force-completed because its ${reason}. Do not retry this step. Continue with the next step in the plan.`,
    };
  }

  // Layer 1: soft nudge (one-shot per step)
  if (!state.nudgedThisStep) {
    const iterFrac = stepIters / config.stepIterBudget;
    const timeFrac = stepElapsedMs / config.stepTimeBudgetMs;
    const frac = Math.max(iterFrac, timeFrac);
    if (frac >= config.nudgeAtFrac) {
      state.nudgedThisStep = true;
      return {
        kind: 'nudge',
        text: `[System] You have used ${stepIters}/${config.stepIterBudget} iterations and ${Math.round(stepElapsedMs / 1000)}s on step ${activeStep.stepNumber}. Wrap up with what you already have and call report_step_complete. Do not start new fetches, navigations, or long operations on this step.`,
      };
    }
  }

  return { kind: 'continue' };
}
