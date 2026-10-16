import { statSync } from "node:fs";
import { dirname } from "node:path";
import { Array as Arr, Effect, Schema } from "effect";
import ts from "typescript";
import { fromTypeScript, type Diagnostic } from "./Diagnostic.ts";
import { descendants } from "./Syntax.ts";

export class CheckFailed extends Schema.TaggedError<CheckFailed>()("CheckFailed", {
  entry: Schema.String,
  reason: Schema.String,
}) {
  override get message(): string {
    return `Cannot check ${this.entry}: ${this.reason}`;
  }
}

const DEFAULTS: ts.CompilerOptions = {
  strict: true,
  target: ts.ScriptTarget.ES2024,
  lib: ["lib.es2024.full.d.ts", "lib.esnext.disposable.d.ts"],
  types: ["*"],
  module: ts.ModuleKind.NodeNext,
  moduleResolution: ts.ModuleResolutionKind.NodeNext,
  allowImportingTsExtensions: true,
  noEmit: true,
  skipLibCheck: true,
};

const CONFIG_HOST: ts.ParseConfigFileHost = {
  ...ts.sys,
  onUnRecoverableConfigFileDiagnostic: () => undefined,
};

export const constituents = (type: ts.Type): ReadonlyArray<ts.Type> => {
  if (type.isUnionOrIntersection()) return type.types;
  return [type];
};

export const isObjectType = (type: ts.Type): type is ts.ObjectType =>
  (type.flags & ts.TypeFlags.Object) !== 0;

export class Project {
  readonly program: ts.Program;
  readonly checker: ts.TypeChecker;
  readonly sources: ReadonlyArray<ts.SourceFile>;
  readonly nodes: ReadonlyArray<ts.Node>;
  readonly #owned: ReadonlySet<ts.SourceFile>;
  readonly #optionsOrigin: string;
  readonly #streamKeys: ReadonlySet<string>;

  private constructor(program: ts.Program, optionsOrigin: string) {
    this.program = program;
    this.checker = program.getTypeChecker();
    this.sources = program
      .getSourceFiles()
      .filter((file) => !file.isDeclarationFile && !program.isSourceFileFromExternalLibrary(file));
    this.nodes = this.sources.flatMap(descendants);
    this.#owned = new Set(this.sources);
    this.#optionsOrigin = optionsOrigin;
    this.#streamKeys = new Set(
      Arr.fromNullishOr(this.global("AsyncIterable"))
        .flatMap((symbol) =>
          this.checker.getPropertiesOfType(this.checker.getDeclaredTypeOfSymbol(symbol)),
        )
        .map((property) => property.name),
    );
  }

  static readonly load = Effect.fn("Project.load")(function* (entry: string) {
    const stats = yield* Effect.try({
      try: () => statSync(entry),
      catch: (cause) => {
        if (cause instanceof Error) return new CheckFailed({ entry, reason: cause.message });
        return new CheckFailed({ entry, reason: String(cause) });
      },
    });
    if (!stats.isFile()) return yield* new CheckFailed({ entry, reason: "it is not a file" });
    const directory = dirname(entry);
    const config = ts.findConfigFile(directory, (file) => ts.sys.fileExists(file));
    if (config === undefined) {
      const host = { ...ts.createCompilerHost(DEFAULTS), getCurrentDirectory: () => directory };
      return new Project(ts.createProgram({ rootNames: [entry], options: DEFAULTS, host }), entry);
    }
    const parsed = ts.getParsedCommandLineOfConfigFile(config, {}, CONFIG_HOST);
    if (parsed === undefined) {
      return yield* new CheckFailed({ entry, reason: `${config} cannot be read` });
    }
    const program = ts.createProgram({
      rootNames: [entry],
      options: parsed.options,
      configFileParsingDiagnostics: parsed.errors,
    });
    return new Project(program, config);
  });

  typeCheck(): ReadonlyArray<Diagnostic> {
    return ts
      .getPreEmitDiagnostics(this.program)
      .map((diagnostic) => fromTypeScript(diagnostic, this.#optionsOrigin));
  }

  owns(node: ts.Node): boolean {
    return this.#owned.has(node.getSourceFile());
  }

  global(name: string): ts.Symbol | undefined {
    return this.checker.resolveName(name, undefined, ts.SymbolFlags.Type, false);
  }

  symbolAt(node: ts.Node): ts.Symbol | undefined {
    const symbol = this.#valueSymbolAt(node);
    if (symbol === undefined) return undefined;
    return this.resolve(symbol);
  }

  resolve(symbol: ts.Symbol): ts.Symbol {
    if ((symbol.flags & ts.SymbolFlags.Alias) === 0)
      return this.checker.getExportSymbolOfSymbol(symbol);
    return this.checker.getExportSymbolOfSymbol(this.checker.getAliasedSymbol(symbol));
  }

  isThenable(type: ts.Type): boolean {
    return constituents(type).some((member) => {
      const then = this.checker.getPropertyOfType(member, "then");
      return (
        then !== undefined && this.checker.getTypeOfSymbol(then).getCallSignatures().length > 0
      );
    });
  }

  isAsyncIterable(type: ts.Type): boolean {
    return constituents(type).some((member) =>
      this.checker
        .getPropertiesOfType(member)
        .some((property) => this.#streamKeys.has(property.name)),
    );
  }

  unwrapPromise(type: ts.Type): ts.Type {
    if (!this.isThenable(type)) return type;
    return this.checker.getAwaitedType(type) ?? type;
  }

  typeArguments(type: ts.Type): ReadonlyArray<ts.Type> {
    if (!this.#isTypeReference(type)) return [];
    return this.checker.getTypeArguments(type);
  }

  #isTypeReference(type: ts.Type): type is ts.TypeReference {
    return isObjectType(type) && (type.objectFlags & ts.ObjectFlags.Reference) !== 0;
  }

  #valueSymbolAt(node: ts.Node): ts.Symbol | undefined {
    const holder = node.parent;
    if (ts.isShorthandPropertyAssignment(holder) && holder.name === node) {
      return this.checker.getShorthandAssignmentValueSymbol(holder);
    }
    return this.checker.getSymbolAtLocation(node);
  }
}
