'use strict';

// Buoy's version of internal/main/worker_thread: a worker thread runs the
// script that the LOAD_SCRIPT message of its parent names. It differs from
// Node's where Node's module loaders would run: Buoy's compiler loads the
// script (internalBinding('worker').runMain and runSource), and the steps of
// prepareWorkerThreadExecution are the ones that internal/main/buoy runs for
// the main thread.

const {
  ArrayPrototypeForEach,
  ArrayPrototypePushApply,
  ArrayPrototypeSplice,
  AtomicsLoad,
  JSONStringify,
  ObjectDefineProperty,
  PromisePrototypeThen,
  RegExpPrototypeExec,
} = primordials;

const {
  threadId,
  getEnvMessagePort,
  runMain,
  runSource,
} = internalBinding('worker');

const workerIo = require('internal/worker/io');
const {
  messageTypes: {
    LOAD_SCRIPT,
    UP_AND_RUNNING,
    ERROR_MESSAGE,
    COULD_NOT_SERIALIZE_ERROR,
    STDIO_PAYLOAD,
    STDIO_WANTS_MORE_DATA,
  },
  kStdioWantsMoreDataCallback,
} = workerIo;

const { setupMainThreadPort } = require('internal/worker/messaging');
const { onGlobalUncaughtException } = require('internal/process/execution');
const { getOptionValue } = require('internal/options');

let debug = require('internal/util/debuglog').debuglog('worker', (fn) => {
  debug = fn;
});

const assert = require('internal/assert');
const { exitCodes: { kGenericUserError } } = internalBinding('errors');

function prepareWorkerThreadExecution() {
  internalBinding('process_methods').patchProcessObject(process);
  ObjectDefineProperty(process, 'argv0', {
    __proto__: null,
    enumerable: true,
    configurable: false,
    value: process.argv[0],
  });
  process.exitCode = undefined;
  process._exiting = false;
  process.argv[0] = process.execPath;

  const globalConsole = require('internal/console/global');
  const { initializeGlobalConsole } = require('internal/console/constructor');
  initializeGlobalConsole(globalConsole);

  if (getOptionValue('--warnings') && process.env.NODE_NO_WARNINGS !== '1') {
    process.on('warning', require('internal/process/warning').onWarning);
  }
  require('internal/util/debuglog').initializeDebugEnv(process.env.NODE_DEBUG);
  if (getOptionValue('--expose-internals')) {
    require('internal/bootstrap/realm').BuiltinModule.exposeInternals();
  }
  if (getOptionValue('--no-experimental-websocket')) {
    delete globalThis.WebSocket;
    delete globalThis.CloseEvent;
  }
  if (!getOptionValue('--experimental-eventsource')) {
    delete globalThis.EventSource;
  }
  ObjectDefineProperty(process, 'report', {
    __proto__: null,
    enumerable: true,
    configurable: true,
    get() {
      return require('internal/process/report').report;
    },
  });
}

prepareWorkerThreadExecution();

debug(`[${threadId}] is setting up worker child environment`);

const port = getEnvMessagePort();

// A main thread that child_process started with NODE_CHANNEL_FD has an IPC
// channel, which its workers cannot use.
if (process.env.NODE_CHANNEL_FD) {
  const workerThreadSetup = require('internal/process/worker_thread_only');
  ObjectDefineProperty(process, 'channel', {
    __proto__: null,
    enumerable: false,
    get: workerThreadSetup.unavailable('process.channel'),
  });

  ObjectDefineProperty(process, 'connected', {
    __proto__: null,
    enumerable: false,
    get: workerThreadSetup.unavailable('process.connected'),
  });

  process.send = workerThreadSetup.unavailable('process.send()');
  process.disconnect =
    workerThreadSetup.unavailable('process.disconnect()');
}

// The code of eval: true runs as a classic script of the global scope with
// the require, module, and __filename of '[worker eval]', as Node's
// evalScript runs it. The wrapper is a CommonJS module at the working
// directory, so require resolves from there.
function evalWrapper(code) {
  return 'globalThis.module = module; globalThis.exports = exports;\n' +
    'globalThis.__dirname = __dirname; globalThis.require = require;\n' +
    "globalThis.__filename = '[worker eval]';\n" +
    `(0, eval)(${JSONStringify(code)});\n`;
}

function runEntry(promise) {
  if (promise === undefined) return;
  PromisePrototypeThen(promise, undefined, (e) => {
    workerOnGlobalUncaughtException(e, true);
  });
}

port.on('message', (message) => {
  if (message.type === LOAD_SCRIPT) {
    port.unref();
    const {
      argv,
      cwdCounter,
      doEval,
      environmentData,
      filename,
      hasStdin,
      publicPort,
      workerData,
      mainThreadPort,
    } = message;

    if (doEval !== 'internal') {
      if (argv !== undefined) {
        ArrayPrototypePushApply(process.argv, argv);
      }

      const publicWorker = require('worker_threads');
      publicWorker.parentPort = publicPort;
      publicWorker.workerData = workerData;
    }

    require('internal/worker').assignEnvironmentData(environmentData);
    setupMainThreadPort(mainThreadPort);

    // The counter is only passed to the workers created by the main thread,
    // not to workers created by other workers.
    let cachedCwd = '';
    let lastCounter = -1;
    const originalCwd = process.cwd;

    process.cwd = function() {
      const currentCounter = AtomicsLoad(cwdCounter, 0);
      if (currentCounter === lastCounter)
        return cachedCwd;
      lastCounter = currentCounter;
      cachedCwd = originalCwd();
      return cachedCwd;
    };
    workerIo.sharedCwdCounter = cwdCounter;

    if (!hasStdin)
      process.stdin.push(null);

    debug(`[${threadId}] starts worker script ${filename} ` +
          `(eval = ${doEval}) at cwd = ${process.cwd()}`);
    port.postMessage({ type: UP_AND_RUNNING });
    const { join } = require('path');
    switch (doEval) {
      case 'classic': {
        const name = '[worker eval]';
        ObjectDefineProperty(process, '_eval', {
          __proto__: null,
          configurable: true,
          enumerable: true,
          value: filename,
        });
        ArrayPrototypeSplice(process.argv, 1, 0, name);
        const module = getOptionValue('--input-type') === 'module';
        // Each code compiles to a module of its own, so the name holds its hash.
        const entry = join(process.cwd(), `[worker eval ${hash(filename)}].${module ? 'mjs' : 'cjs'}`);
        RegExpPrototypeExec(/^/, '');
        runEntry(runSource(entry, module ? filename : evalWrapper(filename)));
        break;
      }

      case 'data-url': {
        const { dataURLProcessor } = require('internal/data_url');
        const { URL } = require('internal/url');
        const { body } = dataURLProcessor(new URL(filename));
        const code = new (require('util').TextDecoder)().decode(body);
        const entry = join(process.cwd(), `[worker data ${hash(filename)}].mjs`);
        RegExpPrototypeExec(/^/, '');
        runEntry(runSource(entry, code));
        break;
      }

      default: {
        ArrayPrototypeSplice(process.argv, 1, 0, filename);
        RegExpPrototypeExec(/^/, '');
        runEntry(runMain(filename));
        break;
      }
    }
  } else if (message.type === STDIO_PAYLOAD) {
    const { stream, chunks } = message;
    ArrayPrototypeForEach(chunks, ({ chunk, encoding }) => {
      process[stream].push(chunk, encoding);
    });
  } else {
    assert(
      message.type === STDIO_WANTS_MORE_DATA,
      `Unknown worker message type ${message.type}`,
    );
    const { stream } = message;
    process[stream][kStdioWantsMoreDataCallback]();
  }
});

// A short hash of a source text, for the name of its module.
function hash(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) {
    h = ((h * 33) ^ text.charCodeAt(i)) >>> 0;
  }
  return `${h.toString(16)}-${text.length}`;
}

function workerOnGlobalUncaughtException(error, fromPromise) {
  debug(`[${threadId}] gets uncaught exception`);
  let handled = false;
  let handlerThrew = false;
  try {
    handled = onGlobalUncaughtException(error, fromPromise);
  } catch (e) {
    error = e;
    handlerThrew = true;
  }
  debug(`[${threadId}] uncaught exception handled = ${handled}`);

  if (handled) {
    return true;
  }

  if (!process._exiting) {
    try {
      process._exiting = true;
      process.exitCode = kGenericUserError;
      if (!handlerThrew) {
        process.emit('exit', process.exitCode);
      }
    } catch {
      // Continue regardless of error.
    }
  }

  let serialized;
  try {
    const { serializeError } = require('internal/error_serdes');
    serialized = serializeError(error);
  } catch {
    // Continue regardless of error.
  }
  debug(`[${threadId}] uncaught exception serialized = ${!!serialized}`);
  if (serialized)
    port.postMessage({
      type: ERROR_MESSAGE,
      error: serialized,
    });
  else
    port.postMessage({ type: COULD_NOT_SERIALIZE_ERROR });

  const { clearAsyncIdStack } = require('internal/async_hooks');
  clearAsyncIdStack();

  process.exit();
}

// Patch the global uncaught exception handler so it gets picked up by
// node::errors::TriggerUncaughtException().
process._fatalException = workerOnGlobalUncaughtException;

require('internal/process/pre_execution').markBootstrapComplete();

// Necessary to reset RegExp statics before user code runs.
RegExpPrototypeExec(/^/, '');

port.start();
