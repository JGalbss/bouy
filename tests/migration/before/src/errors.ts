export class AgentError extends Error {
  readonly code: string;

  constructor(message: string, code = "AGENT_ERROR", options?: ErrorOptions) {
    super(message, options);
    this.name = "AgentError";
    this.code = code;
  }

  get isRetryable(): boolean {
    return false;
  }

  toJSON(): Record<string, unknown> {
    return { name: this.name, code: this.code, message: this.message };
  }
}

export class ModelUnavailableError extends AgentError {
  constructor(
    readonly model: string,
    readonly attempts: number,
    options?: ErrorOptions,
  ) {
    super(`model ${model} is unavailable after ${attempts} attempts`, "MODEL_UNAVAILABLE", options);
    this.name = "ModelUnavailableError";
  }

  override get isRetryable(): boolean {
    return true;
  }
}

export class ToolError extends AgentError {
  constructor(
    readonly tool: string,
    message: string,
  ) {
    super(`${tool}: ${message}`, "TOOL_FAILED");
    this.name = "ToolError";
  }
}

export class TimeoutError extends AgentError {
  constructor(
    readonly operation: string,
    readonly ms: number,
  ) {
    super(`${operation} timed out after ${ms} ms`, "TIMEOUT");
    this.name = "TimeoutError";
  }

  override get isRetryable(): boolean {
    return true;
  }
}

export class QueueClosedError extends AgentError {
  constructor(job: string) {
    super(`queue is closed, cannot accept ${job}`, "QUEUE_CLOSED");
    this.name = "QueueClosedError";
  }
}

export function describeError(error: unknown): string {
  if (error instanceof AgentError) return `${error.name}[${error.code}]: ${error.message}`;
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}
