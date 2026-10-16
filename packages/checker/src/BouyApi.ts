import { Array as Arr } from "effect";
import ts from "typescript";
import { constituents, type Project } from "./Project.ts";

const MODULES: ReadonlySet<string> = new Set(["bouy", "bouy/std"]);
const SPAWNERS: ReadonlySet<string> = new Set(["spawn", "child", "pool"]);
const REF = "Ref";

export class BouyApi {
  readonly spawners: ReadonlySet<ts.Declaration>;
  readonly refClasses: ReadonlySet<ts.Symbol>;

  constructor(project: Project) {
    const checker = project.checker;
    const modules = new Set(
      project.program
        .getSourceFiles()
        .flatMap((file) => file.statements)
        .flatMap((statement) => this.#bouySpecifier(statement))
        .flatMap((specifier) => Arr.fromNullishOr(checker.getSymbolAtLocation(specifier))),
    );
    const exports = [...modules]
      .flatMap((module) => checker.getExportsOfModule(module))
      .map((symbol) => project.resolve(symbol));
    this.spawners = new Set(
      exports
        .filter((symbol) => SPAWNERS.has(symbol.name))
        .flatMap((symbol) => checker.getTypeOfSymbol(symbol).getCallSignatures())
        .map((signature) => signature.getDeclaration()),
    );
    this.refClasses = new Set(
      exports
        .filter((symbol) => symbol.name === REF)
        .flatMap((symbol) => constituents(checker.getDeclaredTypeOfSymbol(symbol)))
        .flatMap((type) => Arr.fromNullishOr(type.getSymbol()))
        .filter((symbol) => (symbol.flags & ts.SymbolFlags.Class) !== 0),
    );
  }

  #bouySpecifier(statement: ts.Statement): ReadonlyArray<ts.StringLiteral> {
    if (!ts.isImportDeclaration(statement) && !ts.isExportDeclaration(statement)) return [];
    const specifier = statement.moduleSpecifier;
    if (specifier === undefined || !ts.isStringLiteral(specifier)) return [];
    if (!MODULES.has(specifier.text)) return [];
    return [specifier];
  }
}
