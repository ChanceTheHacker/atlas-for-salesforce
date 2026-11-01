/**
 * How long to wait before status check number `attempt` (0 first). Checks start after half a
 * second, so a job that finishes quickly shows at once, and slow down to `cap` milliseconds,
 * the interval every check used to wait.
 */
export const pollDelay = (attempt, cap = 3000) => Math.min(cap, 500 * (attempt + 1));
