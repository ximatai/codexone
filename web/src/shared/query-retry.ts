import { ManagementError } from "./management";

// Statistics share one bounded reader by design; pages issue several reads at
// once, so a busy answer is retried briefly instead of shown as a failure.
const BUSY_ATTEMPTS = 4;

export function retryWhenBusy(failureCount: number, error: unknown) {
  return (
    failureCount < BUSY_ATTEMPTS &&
    error instanceof ManagementError &&
    error.status === 429 &&
    error.code === "usage_query_capacity"
  );
}

export function busyRetryDelay(attempt: number, random = Math.random) {
  return Math.round((attempt + 1) * (200 + random() * 300));
}
