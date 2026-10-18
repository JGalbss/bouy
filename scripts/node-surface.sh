#!/bin/sh
# Writes tests/node/surface.json, the API surface manifest of section 5.7.1 of
# docs/design/testing.md. It runs only the node release of `.node-version`, and it refuses
# another release, as scripts/freeze-expectations.sh does.
#
# A group is a name of `require('node:module').builtinModules` except the `_` and `internal/`
# names, a global that Node adds to the globals of a bare V8 context, `console`, or a name of
# the CommonJS module scope: `require`, `module`, `exports`, `__dirname`, and `__filename`.
# Each group has its own node process, an ES module or, for the module scope, a CommonJS
# module, as its probe in `buoy-suites node-surface` has. So a module that patches another,
# as `domain` patches EventEmitter, changes no other group.
#
# The walk records every own member of the group value, every static member and every
# prototype method and accessor of each function, and each constant, with the members that
# the prototype chain gives, up to Object.prototype and Function.prototype. It descends into
# each own member that holds a function or an object that is not an array, once per object
# in a group. It reads a member of the group value, so a lazy getter such as `fs.ReadStream`
# gives its value, and it records a deeper accessor without calling it. It leaves out the
# symbol keys other than the well-known symbols, and the members of the module cache, the
# path cache, `process.env`, `process.config`, and the listener table `_events` of an
# emitter, whose keys depend on the host or on the process.
#
# Each entry is `"<name>": [typeof, length, docs]`. The typeof of an accessor is `accessor`,
# and the length is the `length` of a function, or null. docs is `documented`,
# `deprecated`, or `undocumented`, from Node's doc/api/all.json at the same tag, which the
# script fetches into the cache. A name starts with its group, `node:<module>` for a
# module, and goes on with `.<key>`, `["<key>"]`, or `[Symbol.<name>]` for each key.
#
# Then run `cargo run --release -p buoy-suites -- node-surface --update` and `pnpm compat`.
#
# Usage: scripts/node-surface.sh

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
pinned="v$(cat "$root/.node-version")"
found=$(node --version)
if [ "$found" != "$pinned" ]; then
    echo "$0: node is $found, and .node-version pins $pinned; run the pinned release" >&2
    exit 1
fi

docs_url="https://nodejs.org/dist/$pinned/docs/api/all.json"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/buoy/node-docs-$pinned"
docs="$cache/all.json"
if [ ! -f "$docs" ]; then
    mkdir -p "$cache"
    curl -fsSL "$docs_url" -o "$docs.partial"
    mv "$docs.partial" "$docs"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/walk.mjs" <<'EOF'
import fs from 'node:fs';
import Module from 'node:module';
import vm from 'node:vm';

const WELL_KNOWN = new Map(
  Object.getOwnPropertyNames(Symbol)
    .filter((name) => typeof Symbol[name] === 'symbol')
    .map((name) => [Symbol[name], name]),
);
// The own keys that every function has.
const FUNCTION_KEYS = new Set(['length', 'name', 'prototype', 'arguments', 'caller']);
// The ends of a prototype chain: the prototypes that every object, function, async function,
// generator function, and generator inherits.
const intrinsic = (source) => Object.getPrototypeOf(vm.runInThisContext(source));
const CHAIN_ENDS = new Set([
  Object.prototype,
  Function.prototype,
  intrinsic('(async function () {})'),
  intrinsic('(function* () {})'),
  intrinsic('(async function* () {})'),
  intrinsic('(function* () {})').prototype,
  intrinsic('(async function* () {})').prototype,
]);
// The objects and the keys whose members depend on the host or on the process.
const HOST_OBJECTS = new Set([Module._cache, Module._pathCache, process.env, process.config]);
const STATE_KEYS = new Set(['_events']);
// The members of a group value whose value depends on how node was started.
const STDIO = new Set(['stdin', 'stdout', 'stderr', '_stdout', '_stderr']);
// The doc pages whose name is not the name of their module.
const DOC_PAGES = { sea: 'single-executable-applications', 'stream/web': 'webstreams', trace_events: 'tracing' };
const LISTS = ['modules', 'miscs', 'globals', 'classes', 'methods', 'properties', 'classMethods', 'ctors'];

// The documented names of all.json: a function or a property by its name, and a member of a
// class as `<class>.prototype.<member>` or, when static, `<class>.<member>`, also with the
// class name without its module, as `Readable.prototype.read` for `stream.Readable`. A
// property heading holds only its type, so a property is `<page>.<name>`, and in a class
// both the static and the prototype name. A name that one section documents is documented,
// even when another section deprecates it. `pages` holds the status of each doc page.
const loadDocs = (file) => {
  const statuses = new Map();
  const pages = new Map();
  const pageModules = { globals: '', ...Object.fromEntries(Object.entries(DOC_PAGES).map(([module, page]) => [page, module])) };
  const pageOf = (source) => source.replace(/^doc\/api\/|\.md$/g, '');
  const note = (name, deprecated) => {
    if (!deprecated || !statuses.has(name)) statuses.set(name, deprecated ? 'deprecated' : 'documented');
  };
  const codeName = (textRaw) => {
    const code = /`([^`]+)`/.exec(textRaw ?? '');
    return code && code[1].replace(/^new\s+/, '').replace(/[([].*$|\s+extends\s.*$/s, '').trim();
  };
  const visit = (node, list, inherited, klass, page) => {
    const deprecated = inherited || node.stability === 0 || /^DEP\d+:/.test(node.textRaw ?? '');
    const typed = list === 'properties' && /^(Type:|\{)/.test(node.textRaw ?? '');
    const code = typed ? null : codeName(node.textRaw);
    const name = typed ? node.name : code;
    const short = klass?.split('.').pop();
    const here = node.source ? (pageModules[pageOf(node.source)] ?? pageOf(node.source)) : page;
    let inner = klass;
    if (name && list === 'classes') {
      inner = name;
      note(name, deprecated);
    } else if (name && klass && ['methods', 'properties', 'classMethods'].includes(list)) {
      const member = name.split('.').pop();
      const isStatic =
        list === 'classMethods' || /^Static\b/.test(node.textRaw) || name.startsWith(`${klass}.`) || name.startsWith(`${short}.`);
      const tails = code === null ? ['.', '.prototype.'] : [isStatic ? '.' : '.prototype.'];
      for (const tail of tails) {
        note(klass + tail + member, deprecated);
        note(short + tail + member, deprecated);
      }
    } else if (name) {
      note(code ?? [here, name].filter(Boolean).join('.'), deprecated);
    }
    for (const key of LISTS) for (const child of node[key] ?? []) visit(child, key, deprecated, inner, here);
  };
  const docs = JSON.parse(fs.readFileSync(file, 'utf8'));
  for (const page of docs.modules) pages.set(pageOf(page.source), page.stability === 0 ? 'deprecated' : 'documented');
  visit(docs, null, false, undefined, '');
  const statusOf = (names) => {
    const found = names.map((name) => statuses.get(name));
    return found.find((status) => status === 'documented') ?? found.find(Boolean) ?? 'undocumented';
  };
  return { statusOf, pages };
};

const keyText = (key) => {
  if (typeof key === 'symbol') return WELL_KNOWN.has(key) ? `[Symbol.${WELL_KNOWN.get(key)}]` : null;
  if (/^[A-Za-z_$][\w$]*$/.test(key)) return `.${key}`;
  return /^[^\]"\\]*$/.test(key) ? `[${JSON.stringify(key)}]` : null;
};
const shape = (value) => [typeof value, typeof value === 'function' ? value.length : null];
const isWalked = (value) =>
  typeof value === 'function' || (typeof value === 'object' && value !== null && !Array.isArray(value));

// A member of the group value is read, so a lazy getter gives its value. A deeper accessor
// is not called.
const ACCESSOR = Symbol('accessor');
const valueOf = (object, key, descriptor, isGroupMember) => {
  if ('value' in descriptor) return descriptor.value;
  if (!isGroupMember) return ACCESSOR;
  try {
    return object[key];
  } catch {
    return ACCESSOR;
  }
};

// Records the members of `object` and of its prototype chain under `name`, and descends into
// each own member that holds a function or an object.
const members = (group, name, object, keys) => {
  const named = new Set();
  for (let holder = object; holder !== null && !CHAIN_ENDS.has(holder); holder = Object.getPrototypeOf(holder)) {
    const constructor = Object.getOwnPropertyDescriptor(holder, 'constructor')?.value;
    const owner = typeof holder === 'function' ? holder.name : typeof constructor === 'function' ? `${constructor.name}.prototype` : null;
    for (const key of Reflect.ownKeys(holder)) {
      const text = keyText(key);
      if (text === null || key === 'constructor' || named.has(key) || (typeof holder === 'function' && FUNCTION_KEYS.has(key))) continue;
      named.add(key);
      const descriptor = Object.getOwnPropertyDescriptor(holder, key);
      const path = [...keys, typeof key === 'symbol' ? text : key];
      const docNames = group.prefixes.map((prefix) => [prefix, ...path].filter(Boolean).join('.'));
      if (owner && typeof key === 'string') docNames.push(`${owner}.${key}`);
      const value = valueOf(object, key, descriptor, keys.length === 0);
      const found = value === ACCESSOR ? ['accessor', null] : shape(value);
      group.lines.push(`    ${JSON.stringify(name + text)}: ${JSON.stringify([...found, group.docs.statusOf(docNames)])}`);
      const isSkipped = STATE_KEYS.has(key) || (keys.length === 0 && STDIO.has(key));
      // An inherited member is recorded, and its own walk belongs to the class that owns it.
      if (holder === object && value !== ACCESSOR && !isSkipped) descend(group, name + text, value, path);
    }
  }
};

const descend = (group, name, value, keys) => {
  if (!isWalked(value) || group.seen.has(value) || HOST_OBJECTS.has(value)) return;
  group.seen.add(value);
  members(group, name, value, keys);
  const prototype = typeof value === 'function' ? Object.getOwnPropertyDescriptor(value, 'prototype')?.value : undefined;
  if (isWalked(prototype) && !group.seen.has(prototype)) {
    group.seen.add(prototype);
    members(group, `${name}.prototype`, prototype, [...keys, 'prototype']);
  }
};

// The doc names of a module: `fs` for node:fs, `fs.promises` and `fsPromises` for
// node:fs/promises, and the bare name, which classes such as `Buffer` use.
const modulePrefixes = (module) => {
  const [base, rest] = module.split('/');
  const camel = rest ? base + rest[0].toUpperCase() + rest.slice(1) : base;
  return [...new Set([module.replace('/', '.'), camel, base, ''])];
};

// Appends the entries of the group `name`, whose value is `value`, to the file `output`.
export const writeGroup = (docsFile, output, name, value) => {
  const docs = loadDocs(docsFile);
  const module = name.startsWith('node:') ? name.slice('node:'.length) : null;
  const status =
    module === null ? docs.statusOf([name]) : (docs.pages.get(DOC_PAGES[module] ?? module.split('/')[0]) ?? 'undocumented');
  const group = { docs, prefixes: module === null ? [name] : modulePrefixes(module), seen: new Set([globalThis]), lines: [] };
  group.lines.push(`    ${JSON.stringify(name)}: ${JSON.stringify([...shape(value), status])}`);
  descend(group, name, value, []);
  fs.appendFileSync(output, `${group.lines.join('\n')}\n`);
};

// `groups` prints the modules and the globals, and `<group> <docs> <output>` walks one.
if (import.meta.main) {
  const [name, docs, output] = process.argv.slice(2);
  if (name === 'groups') {
    const modules = Module.builtinModules
      .filter((module) => !module.startsWith('_') && !module.startsWith('internal/'))
      .map((module) => `node:${module.replace(/^node:/, '')}`);
    const bare = new Set(vm.runInNewContext('Object.getOwnPropertyNames(globalThis)'));
    const globals = Object.getOwnPropertyNames(globalThis).filter((global) => !bare.has(global));
    console.log([...modules, ...globals, 'console'].join('\n'));
  } else {
    const value = name.startsWith('node:') ? process.getBuiltinModule(name) : globalThis[name];
    writeGroup(docs, output, name, value);
  }
}
EOF

cat >"$work/scope.cjs" <<'EOF'
'use strict';
const { writeGroup } = require('./walk.mjs');

const [name, docs, output] = process.argv.slice(2);
const scope = { require, module, exports, __dirname, __filename };
writeGroup(docs, output, name, scope[name]);
EOF

# The environment of the freeze script, with no stdin and no stdout, so a stream of
# `process` has the same type in every run.
walk() {
    env -i PATH="$PATH" HOME="$HOME" TZ=Etc/UTC LANG=C.UTF-8 NO_COLOR=1 CI=1 TMPDIR="$work" \
        node "$@" "$docs" "$work/entries" </dev/null >/dev/null
}

groups=$(env -i PATH="$PATH" HOME="$HOME" node "$work/walk.mjs" groups)
host=$(env -i PATH="$PATH" HOME="$HOME" node -p 'process.platform + "-" + process.arch')
# The group names hold no spaces.
for group in $groups; do
    walk "$work/walk.mjs" "$group"
done
for name in require module exports __dirname __filename; do
    walk "$work/scope.cjs" "$name"
done

{
    printf '{\n  "node": "%s",\n  "host": "%s",\n  "docs": "%s",\n  "entries": {\n' \
        "$pinned" "$host" "$docs_url"
    LC_ALL=C sort "$work/entries" | sed '$!s/$/,/'
    printf '  }\n}\n'
} >"$work/surface.json"
mv "$work/surface.json" "$root/tests/node/surface.json"
echo "$0: wrote tests/node/surface.json with $(grep -c '^    "' "$root/tests/node/surface.json") entries" >&2
