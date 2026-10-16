import ts from "typescript";

export interface Diagnostic {
  readonly code: string;
  readonly severity: "error" | "warning";
  readonly message: string;
  readonly file: string;
  readonly line: number;
  readonly column: number;
}

interface Finding {
  readonly code: string;
  readonly severity: Diagnostic["severity"];
  readonly message: string;
}

interface Position {
  readonly line: number;
  readonly column: number;
}

const SEVERITIES: ReadonlyMap<ts.DiagnosticCategory, Diagnostic["severity"]> = new Map([
  [ts.DiagnosticCategory.Warning, "warning"],
]);

const position = (file: ts.SourceFile, offset: number): Position => {
  const { line, character } = file.getLineAndCharacterOfPosition(offset);
  return { line: line + 1, column: character + 1 };
};

export const formatDiagnostic = (diagnostic: Diagnostic): string =>
  `${diagnostic.file}:${diagnostic.line}:${diagnostic.column} - ${diagnostic.severity} ${diagnostic.code}: ${diagnostic.message}`;

export const diagnosticAt = (node: ts.Node, finding: Finding): Diagnostic => {
  const file = node.getSourceFile();
  return { ...finding, file: file.fileName, ...position(file, node.getStart(file)) };
};

export const fromTypeScript = (diagnostic: ts.Diagnostic, optionsOrigin: string): Diagnostic => {
  const finding = {
    code: `TS${diagnostic.code}`,
    severity: SEVERITIES.get(diagnostic.category) ?? "error",
    message: ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n"),
  };
  const file = diagnostic.file;
  if (file === undefined) return { ...finding, file: optionsOrigin, line: 1, column: 1 };
  return { ...finding, file: file.fileName, ...position(file, diagnostic.start ?? 0) };
};
