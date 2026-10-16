// Structured logging: one JSON object per line, so the log shipper can index every field.

export enum LogLevel {
  Debug = 10,
  Info = 20,
  Warn = 30,
  Error = 40,
}

export type LogFields = Record<string, unknown>;

export interface LoggerOptions {
  level?: LogLevel;
  bindings?: LogFields;
  /** Milliseconds since the epoch. Injected so tests get stable timestamps. */
  clock?: () => number;
  write?: (line: string) => void;
}

const LEVELS_BY_NAME: Record<string, LogLevel> = {
  debug: LogLevel.Debug,
  info: LogLevel.Info,
  warn: LogLevel.Warn,
  error: LogLevel.Error,
};

export class Logger {
  static #root: Logger | undefined;

  readonly #level: LogLevel;
  readonly #bindings: LogFields;
  readonly #clock: () => number;
  readonly #write: (line: string) => void;

  constructor(options: LoggerOptions = {}) {
    this.#level = options.level ?? LogLevel.Info;
    this.#bindings = options.bindings ?? {};
    this.#clock = options.clock ?? Date.now;
    this.#write = options.write ?? ((line) => console.log(line));
  }

  /** The process-wide logger. Modules that are not handed a logger use this one. */
  static get root(): Logger {
    if (!Logger.#root) {
      Logger.#root = new Logger();
    }
    return Logger.#root;
  }

  static configure(options: LoggerOptions): Logger {
    Logger.#root = new Logger(options);
    return Logger.#root;
  }

  static parseLevel(name: string): LogLevel {
    const level = LEVELS_BY_NAME[name.trim().toLowerCase()];
    if (level === undefined) {
      throw new RangeError(`unknown log level "${name}"`);
    }
    return level;
  }

  get level(): LogLevel {
    return this.#level;
  }

  get levelName(): string {
    return LogLevel[this.#level].toLowerCase();
  }

  child(bindings: LogFields): Logger {
    return new Logger({
      level: this.#level,
      bindings: { ...this.#bindings, ...bindings },
      clock: this.#clock,
      write: this.#write,
    });
  }

  isEnabled(level: LogLevel): boolean {
    return level >= this.#level;
  }

  debug(msg: string, fields?: LogFields): void {
    this.#log(LogLevel.Debug, msg, fields);
  }

  info(msg: string, fields?: LogFields): void {
    this.#log(LogLevel.Info, msg, fields);
  }

  warn(msg: string, fields?: LogFields): void {
    this.#log(LogLevel.Warn, msg, fields);
  }

  error(msg: string, fields?: LogFields): void {
    this.#log(LogLevel.Error, msg, fields);
  }

  #log(level: LogLevel, msg: string, fields: LogFields = {}): void {
    if (!this.isEnabled(level)) return;
    const entry = {
      time: new Date(this.#clock()).toISOString(),
      level: LogLevel[level].toLowerCase(),
      msg,
      ...this.#bindings,
      ...fields,
    };
    this.#write(JSON.stringify(entry, serializeErrors));
  }
}

// JSON.stringify drops the message and name of an Error, because they are not own enumerable.
function serializeErrors(_key: string, value: unknown): unknown {
  if (value instanceof Error) {
    return { name: value.name, message: value.message };
  }
  return value;
}
