//! Linking: what each import of a module refers to, and the exports of each namespace,
//! by the `ResolveExport` and `GetExportedNames` algorithms of the spec over the graph. A
//! `CommonJS` module exports `default`, `module.exports`, and the names that Node's
//! cjs-module-lexer finds, and a JSON module exports `default`.
//!
//! An import that does not resolve is an error of the module that the runtime throws
//! when it links the graph, as Node does, and not a compile error: a module that only a
//! failing `import()` reaches must not stop the program.

use std::collections::HashMap;

use super::graph::{Graph, Imported, Kind, Resolved, Unit};
use crate::resolve::Mode;

/// What an import, an export, or a namespace property reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Binding {
    /// A binding of a module of the graph, by the key of its `'$export'/1`: the local name
    /// for an ES module, the export name for a `CommonJS` or JSON module.
    Export { unit: usize, key: String },
    /// The namespace object of a module of the graph.
    Namespace(usize),
    /// An export of a built-in module.
    Builtin { name: String, export: String },
    /// The namespace of a built-in module.
    BuiltinNamespace(String),
}

/// An error that linking the module throws.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkError {
    /// `SyntaxError`, or `Error` for a module that resolution did not find.
    pub kind: &'static str,
    pub code: Option<&'static str>,
    pub message: String,
}

/// The link facts of one module.
#[derive(Debug, Default)]
pub struct Linked {
    /// What each import binding reads, by its local name.
    pub imports: HashMap<String, Binding>,
    /// The local names that `'$export'/1` reads, for an ES module.
    pub exported_locals: Vec<String>,
    /// The namespace: each export name, in code unit order, and what it reads.
    pub namespace: Vec<(String, Binding)>,
    pub error: Option<LinkError>,
}

enum Resolution {
    Found(Binding),
    Ambiguous,
    NotFound,
}

/// `(export name, specifier, imported)`
type Indirect = (String, String, Imported);

struct Linker<'g> {
    graph: &'g Graph,
    /// The local exports of each ES module after the spec's rewrite: an export of an
    /// imported name becomes an indirect export.
    locals: Vec<Vec<(String, String)>>,
    indirect: Vec<Vec<Indirect>>,
    cjs_names: HashMap<usize, Vec<String>>,
}

/// Links every module of the graph.
pub fn link(graph: &Graph) -> Vec<Linked> {
    let mut linker = Linker {
        graph,
        locals: Vec::new(),
        indirect: Vec::new(),
        cjs_names: HashMap::new(),
    };
    for unit in &graph.units {
        let (locals, indirect) = rewrite(unit);
        linker.locals.push(locals);
        linker.indirect.push(indirect);
    }
    (0..graph.units.len())
        .map(|index| linker.linked(index))
        .collect()
}

/// The spec's rewrite of the export entries of `ParseModule`: `import { a } from 'm';
/// export { a }` is an indirect export of `a` from `m`. A re-exported namespace import
/// stays local.
fn rewrite(unit: &Unit) -> (Vec<(String, String)>, Vec<Indirect>) {
    let mut locals = Vec::new();
    let mut indirect = unit.record.indirect.clone();
    for (export, local) in &unit.record.locals {
        match unit
            .record
            .imports
            .iter()
            .find(|(name, _, _)| name == local)
        {
            Some((_, specifier, Imported::Name(imported))) => indirect.push((
                export.clone(),
                specifier.clone(),
                Imported::Name(imported.clone()),
            )),
            _ => locals.push((export.clone(), local.clone())),
        }
    }
    (locals, indirect)
}

impl Linker<'_> {
    fn unit(&self, index: usize) -> &Unit {
        &self.graph.units[index]
    }

    /// What `specifier` of `index` names for `import`.
    fn target(&self, index: usize, specifier: &str) -> Option<&Resolved> {
        self.unit(index)
            .requests
            .iter()
            .find(|request| request.specifier == specifier && request.mode == Mode::Import)
            .map(|request| &request.resolved)
    }

    fn linked(&mut self, index: usize) -> Linked {
        let unit = self.unit(index);
        let typescript = unit.source_type().is_typescript();
        let mut linked = Linked::default();
        if unit.kind == Kind::Esm {
            linked.exported_locals = dedupe(self.locals[index].iter().map(|(_, l)| l.clone()));
            linked.error = self.missing(index);
            for (local, specifier, imported) in unit.record.imports.clone() {
                let found = self.import(index, &specifier, &imported);
                match found {
                    Ok(Some(binding)) => {
                        linked.imports.insert(local, binding);
                    }
                    Ok(None) => {}
                    Err(error) => {
                        // TypeScript erases an import of a type, which no module exports.
                        if typescript && error.kind == "SyntaxError" {
                            continue;
                        }
                        linked.error.get_or_insert(error);
                    }
                }
            }
            for (export, specifier, imported) in self.indirect[index].clone() {
                if let Imported::Name(name) = &imported
                    && let Err(error) =
                        self.import(index, &specifier, &Imported::Name(name.clone()))
                    && !(typescript && error.kind == "SyntaxError")
                {
                    let _ = export;
                    linked.error.get_or_insert(error);
                }
            }
        }
        let mut names = self.exported_names(index, &mut Vec::new());
        names.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
        for name in names {
            if let Resolution::Found(binding) = self.resolve_export(index, &name, &mut Vec::new()) {
                linked.namespace.push((name, binding));
            }
        }
        linked
    }

    /// The first static request that resolution did not find.
    fn missing(&self, index: usize) -> Option<LinkError> {
        self.unit(index).record.order.iter().find_map(|specifier| {
            match self.target(index, specifier) {
                Some(Resolved::Missing(failure)) => Some(LinkError {
                    kind: "Error",
                    code: Some(failure.code),
                    message: failure.message.clone(),
                }),
                _ => None,
            }
        })
    }

    /// What an import of `imported` from `specifier` reads.
    fn import(
        &mut self,
        index: usize,
        specifier: &str,
        imported: &Imported,
    ) -> Result<Option<Binding>, LinkError> {
        let Some(target) = self.target(index, specifier).cloned() else {
            return Ok(None);
        };
        match (target, imported) {
            (Resolved::Unit(unit, _), Imported::Namespace) => Ok(Some(Binding::Namespace(unit))),
            (Resolved::Unit(unit, _), Imported::Name(name)) => {
                match self.resolve_export(unit, name, &mut Vec::new()) {
                    Resolution::Found(binding) => Ok(Some(binding)),
                    Resolution::Ambiguous => Err(LinkError {
                        kind: "SyntaxError",
                        code: None,
                        message: format!(
                            "The requested module '{specifier}' contains conflicting star exports for name '{name}'"
                        ),
                    }),
                    Resolution::NotFound => Err(LinkError {
                        kind: "SyntaxError",
                        code: None,
                        message: self.not_exported(unit, specifier, name),
                    }),
                }
            }
            (Resolved::Builtin(builtin), Imported::Namespace) => {
                Ok(Some(Binding::BuiltinNamespace(builtin)))
            }
            (Resolved::Builtin(builtin), Imported::Name(name)) => Ok(Some(Binding::Builtin {
                name: builtin,
                export: name.clone(),
            })),
            (Resolved::Missing(failure), _) => Err(LinkError {
                kind: "Error",
                code: Some(failure.code),
                message: failure.message,
            }),
            (Resolved::Path(_), _) => Ok(None),
        }
    }

    /// Node's message for a name that a module does not export.
    fn not_exported(&self, unit: usize, specifier: &str, name: &str) -> String {
        if self.unit(unit).kind == Kind::CommonJs {
            return format!(
                "Named export '{name}' not found. The requested module '{specifier}' is a CommonJS module, which may not support all module.exports as named exports.\nCommonJS modules can always be imported via the default export, for example using:\n\nimport pkg from '{specifier}';\nconst {{ {name} }} = pkg;\n"
            );
        }
        format!("The requested module '{specifier}' does not provide an export named '{name}'")
    }

    /// `ResolveExport`
    fn resolve_export(
        &mut self,
        index: usize,
        name: &str,
        visited: &mut Vec<(usize, String)>,
    ) -> Resolution {
        if self.unit(index).kind != Kind::Esm {
            return if self.cjs_exports(index).iter().any(|known| known == name) {
                Resolution::Found(Binding::Export {
                    unit: index,
                    key: name.to_owned(),
                })
            } else {
                Resolution::NotFound
            };
        }
        if visited
            .iter()
            .any(|(unit, known)| *unit == index && known == name)
        {
            return Resolution::NotFound;
        }
        visited.push((index, name.to_owned()));
        if let Some((_, local)) = self.locals[index].iter().find(|(export, _)| export == name) {
            return Resolution::Found(Binding::Export {
                unit: index,
                key: local.clone(),
            });
        }
        if let Some((_, specifier, imported)) = self.indirect[index]
            .iter()
            .find(|(export, _, _)| export == name)
            .cloned()
        {
            return match (self.target(index, &specifier).cloned(), imported) {
                (Some(Resolved::Unit(unit, _)), Imported::Namespace) => {
                    Resolution::Found(Binding::Namespace(unit))
                }
                (Some(Resolved::Unit(unit, _)), Imported::Name(imported)) => {
                    self.resolve_export(unit, &imported, visited)
                }
                (Some(Resolved::Builtin(builtin)), Imported::Namespace) => {
                    Resolution::Found(Binding::BuiltinNamespace(builtin))
                }
                (Some(Resolved::Builtin(builtin)), Imported::Name(imported)) => {
                    Resolution::Found(Binding::Builtin {
                        name: builtin,
                        export: imported,
                    })
                }
                _ => Resolution::NotFound,
            };
        }
        if name == "default" {
            return Resolution::NotFound;
        }
        let mut star: Option<Binding> = None;
        for specifier in self.unit(index).record.stars.clone() {
            let Some(Resolved::Unit(unit, _)) = self.target(index, &specifier).cloned() else {
                continue;
            };
            match self.resolve_export(unit, name, visited) {
                Resolution::Ambiguous => return Resolution::Ambiguous,
                Resolution::Found(binding) => match &star {
                    None => star = Some(binding),
                    Some(known) if *known == binding => {}
                    Some(_) => return Resolution::Ambiguous,
                },
                Resolution::NotFound => {}
            }
        }
        star.map_or(Resolution::NotFound, Resolution::Found)
    }

    /// `GetExportedNames`
    fn exported_names(&mut self, index: usize, visited: &mut Vec<usize>) -> Vec<String> {
        if self.unit(index).kind != Kind::Esm {
            return self.cjs_exports(index);
        }
        if visited.contains(&index) {
            return Vec::new();
        }
        visited.push(index);
        let mut names: Vec<String> = self.locals[index]
            .iter()
            .map(|(export, _)| export.clone())
            .chain(
                self.indirect[index]
                    .iter()
                    .map(|(export, _, _)| export.clone()),
            )
            .collect();
        for specifier in self.unit(index).record.stars.clone() {
            let Some(Resolved::Unit(unit, _)) = self.target(index, &specifier).cloned() else {
                continue;
            };
            for name in self.exported_names(unit, visited) {
                if name != "default" && !names.contains(&name) {
                    names.push(name);
                }
            }
        }
        names
    }

    /// The export names of a `CommonJS` or JSON module.
    fn cjs_exports(&mut self, index: usize) -> Vec<String> {
        if let Some(names) = self.cjs_names.get(&index) {
            return names.clone();
        }
        // A cycle of re-exports reads the names found so far.
        self.cjs_names.insert(index, Vec::new());
        let unit = self.unit(index);
        let mut names = vec!["default".to_owned()];
        if unit.kind == Kind::CommonJs {
            names.push("module.exports".to_owned());
            names.extend(unit.record.cjs_names.iter().cloned());
            let reexports: Vec<usize> = unit
                .record
                .cjs_reexports
                .iter()
                .filter_map(|specifier| {
                    unit.requests
                        .iter()
                        .find_map(|request| match &request.resolved {
                            Resolved::Unit(target, _)
                                if &request.specifier == specifier
                                    && request.mode == Mode::Require =>
                            {
                                Some(*target)
                            }
                            _ => None,
                        })
                })
                .collect();
            for target in reexports {
                for name in self.exported_names(target, &mut Vec::new()) {
                    if name != "default" && name != "module.exports" {
                        names.push(name);
                    }
                }
            }
        }
        let names = dedupe(names.into_iter());
        self.cjs_names.insert(index, names.clone());
        names
    }
}

fn dedupe(items: impl Iterator<Item = String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for item in items {
        if !out.contains(&item) {
            out.push(item);
        }
    }
    out
}
