import { Array as Arr } from "effect";
import ts from "typescript";
import { constituents, type Project } from "./Project.ts";

export interface Actor {
  readonly declaration: ts.ClassLikeDeclaration;
  readonly instance: ts.Type;
  readonly classes: ReadonlyArray<ts.ClassLikeDeclaration>;
}

export const className = (actor: ts.ClassLikeDeclaration): string => {
  if (actor.name !== undefined) return actor.name.text;
  const holder = actor.parent;
  if (ts.isVariableDeclaration(holder) && ts.isIdentifier(holder.name)) return holder.name.text;
  return "(anonymous class)";
};

export const memberLabel = (actor: ts.ClassLikeDeclaration, member: ts.ClassElement): string =>
  `${className(actor)}.${member.name?.getText() ?? "constructor"}`;

export const instanceMembers = (actor: ts.ClassLikeDeclaration): ReadonlyArray<ts.ClassElement> =>
  actor.members.filter(
    (member) =>
      !ts.isClassStaticBlockDeclaration(member) &&
      (ts.getCombinedModifierFlags(member) & ts.ModifierFlags.Static) === 0,
  );

export class Actors {
  readonly #project: Project;
  readonly #spawners: ReadonlySet<ts.Declaration>;

  constructor(project: Project, spawners: ReadonlySet<ts.Declaration>) {
    this.#project = project;
    this.#spawners = spawners;
  }

  find(): ReadonlyArray<Actor> {
    const checker = this.#project.checker;
    const instances = new Set(
      this.#project.nodes
        .filter(ts.isCallExpression)
        .filter((call) => this.#isSpawn(call))
        .flatMap((call) => call.arguments.slice(0, 1))
        .flatMap((argument) => constituents(checker.getTypeAtLocation(argument)))
        .flatMap((constructor) => constructor.getConstructSignatures())
        .map((signature) => signature.getReturnType()),
    );
    return [...instances].flatMap((instance) =>
      Arr.fromNullishOr(instance.getSymbol()).flatMap((symbol) =>
        this.#ownedClasses(symbol).map((declaration) => ({
          declaration,
          instance,
          classes: this.#lineage(symbol),
        })),
      ),
    );
  }

  #isSpawn(call: ts.CallExpression): boolean {
    const signature = this.#project.checker.getResolvedSignature(call);
    return signature !== undefined && this.#spawners.has(signature.getDeclaration());
  }

  #lineage(symbol: ts.Symbol): ReadonlyArray<ts.ClassLikeDeclaration> {
    const bases = this.#project.checker.getDeclaredTypeOfSymbol(symbol).getBaseTypes() ?? [];
    return [
      ...this.#ownedClasses(symbol),
      ...bases
        .flatMap(constituents)
        .flatMap((base) => Arr.fromNullishOr(base.getSymbol()))
        .flatMap((base) => this.#lineage(base)),
    ];
  }

  #ownedClasses(symbol: ts.Symbol): ReadonlyArray<ts.ClassLikeDeclaration> {
    return (symbol.declarations ?? [])
      .filter(ts.isClassLike)
      .filter((declaration) => this.#project.owns(declaration));
  }
}
