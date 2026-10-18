'use strict';

// Buoy's main script, in place of internal/main/run_main_module: the steps of
// prepareMainThreadExecution (internal/process/pre_execution) that a program
// needs before its code runs. Buoy's compiler links the program, so Node's
// module loaders do not run.

const {
  NumberParseInt,
  ObjectDefineProperty,
} = primordials;

const { getOptionValue } = require('internal/options');

function patchProcessObject() {
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

  // As expandArgv1 of run_main_module: the code of -e and -p has no script.
  const expandArgv1 = !getOptionValue('[has_eval_string]') && !getOptionValue('--print');
  if (expandArgv1 && process.argv[1] && process.argv[1][0] !== '-') {
    process.argv[1] = require('path').resolve(process.argv[1]);
  }

  const globalConsole = require('internal/console/global');
  const { initializeGlobalConsole } = require('internal/console/constructor');
  initializeGlobalConsole(globalConsole);

  addReadOnlyProcessAlias('_eval', '--eval');
  addReadOnlyProcessAlias('_print_eval', '--print');
  addReadOnlyProcessAlias('_syntax_check_only', '--check');
  addReadOnlyProcessAlias('_forceRepl', '--interactive');
  addReadOnlyProcessAlias('_preload_modules', '--require');
  addReadOnlyProcessAlias('noDeprecation', '--no-deprecation');
  addReadOnlyProcessAlias('noProcessWarnings', '--no-warnings');
  addReadOnlyProcessAlias('traceProcessWarnings', '--trace-warnings');
  addReadOnlyProcessAlias('throwDeprecation', '--throw-deprecation');
  addReadOnlyProcessAlias('profProcess', '--prof-process');
  addReadOnlyProcessAlias('traceDeprecation', '--trace-deprecation');
  addReadOnlyProcessAlias('_breakFirstLine', '--inspect-brk', false);
  addReadOnlyProcessAlias('_breakNodeFirstLine', '--inspect-brk-node', false);
}

function addReadOnlyProcessAlias(name, option, enumerable = true) {
  const value = getOptionValue(option);
  if (value) {
    ObjectDefineProperty(process, name, {
      __proto__: null,
      writable: false,
      configurable: true,
      enumerable,
      value,
    });
  }
}

function setupWarningHandler() {
  const { onWarning } = require('internal/process/warning');
  if (getOptionValue('--warnings') &&
    process.env.NODE_NO_WARNINGS !== '1') {
    process.on('warning', onWarning);
  }
}

function setupDebugEnv() {
  require('internal/util/debuglog').initializeDebugEnv(process.env.NODE_DEBUG);
  if (getOptionValue('--expose-internals')) {
    require('internal/bootstrap/realm').BuiltinModule.exposeInternals();
  }
}

function setupNavigator() {
  if (getOptionValue('--no-experimental-global-navigator')) {
    return;
  }
  const {
    exposeLazyInterfaces,
    defineReplaceableLazyAttribute,
  } = require('internal/util');
  exposeLazyInterfaces(globalThis, 'internal/navigator', ['Navigator']);
  defineReplaceableLazyAttribute(globalThis, 'internal/navigator', ['navigator'], false);
}

function initializeReport() {
  ObjectDefineProperty(process, 'report', {
    __proto__: null,
    enumerable: true,
    configurable: true,
    get() {
      const { report } = require('internal/process/report');
      return report;
    },
  });
}

function initializeDeprecations() {
  // DEP0103: process.binding('util').isX reads the checkers of util.types.
  const utilBinding = internalBinding('util');
  const types = require('internal/util/types');
  for (const name of [
    'isArrayBuffer', 'isArrayBufferView', 'isAsyncFunction', 'isDataView',
    'isDate', 'isExternal', 'isMap', 'isMapIterator', 'isNativeError',
    'isPromise', 'isRegExp', 'isSet', 'isSetIterator', 'isTypedArray',
    'isUint8Array', 'isAnyArrayBuffer',
  ]) {
    utilBinding[name] = types[name];
  }
}

// https://websockets.spec.whatwg.org/
function setupWebsocket() {
  if (getOptionValue('--no-experimental-websocket')) {
    delete globalThis.WebSocket;
    delete globalThis.CloseEvent;
  }
}

// https://html.spec.whatwg.org/multipage/server-sent-events.html
function setupEventsource() {
  if (!getOptionValue('--experimental-eventsource')) {
    delete globalThis.EventSource;
  }
}

// --env-file and --env-file-if-exists, which node reads in C++ before the
// bootstrap: a variable of the environment wins over the file.
function loadEnvFiles() {
  for (const file of getOptionValue('--env-file')) {
    process.loadEnvFile(file);
  }
  for (const file of getOptionValue('--env-file-if-exists')) {
    try {
      process.loadEnvFile(file);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
  }
}

// A child that child_process.fork started talks to its parent on the
// descriptor of NODE_CHANNEL_FD, as setupChildProcessIpcChannel does.
function setupChildProcessIpcChannel() {
  if (process.env.NODE_CHANNEL_FD) {
    const fd = NumberParseInt(process.env.NODE_CHANNEL_FD, 10);
    delete process.env.NODE_CHANNEL_FD;
    const serializationMode = process.env.NODE_CHANNEL_SERIALIZATION_MODE || 'json';
    delete process.env.NODE_CHANNEL_SERIALIZATION_MODE;
    require('child_process')._forkChild(fd, serializationMode);
  }
}

// Node's CommonJS loader: Buoy's compiler links the program, but the REPL,
// the code of -e, and the programs that require internal/modules/cjs/loader
// read Module.builtinModules and the search paths, as initializeCJSLoader
// sets them.
function initializeCJS() {
  require('internal/modules/cjs/loader').initializeCJS();
}

// The ESM loader of Node runs the modules that node:vm, createRequire, and
// import() of a vm script hand it, as initializeModuleLoaders sets it up.
function initializeESM() {
  require('internal/modules/esm/utils').initializeESM();
}

// As setupVmModules of pre_execution.
function setupVmModules() {
  if (getOptionValue('--experimental-vm-modules')) {
    const {
      Module, SourceTextModule, SyntheticModule,
    } = require('internal/vm/module');
    const vm = require('vm');
    vm.Module = Module;
    vm.SourceTextModule = SourceTextModule;
    vm.SyntheticModule = SyntheticModule;
  }
}

// The code of -e and -p reads each built-in module as a global, as
// internal/main/eval_string gives it.
function setupEvalGlobals() {
  if (getOptionValue('--eval')) {
    require('internal/modules/helpers').addBuiltinLibsToObject(globalThis, '<eval>');
  }
}

// The tracing of async_hooks when --trace-event-categories enables it.
function setupTraceCategoryState() {
  const { isTraceCategoryEnabled } = internalBinding('trace_events');
  const { toggleTraceCategoryState } = require('internal/process/per_thread');
  toggleTraceCategoryState(isTraceCategoryEnabled('node.async_hooks'));
}

// Web Storage needs SQLite, which Buoy lacks, as a node built without it does.
patchProcessObject();
setupTraceCategoryState();
loadEnvFiles();
setupWebsocket();
setupEventsource();
initializeReport();
initializeDeprecations();
setupNavigator();
setupWarningHandler();
setupDebugEnv();
setupChildProcessIpcChannel();
setupVmModules();
initializeCJS();
initializeESM();
setupEvalGlobals();
require('internal/process/pre_execution').markBootstrapComplete();
