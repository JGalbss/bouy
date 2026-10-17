//! A module's interface to the loader of the runtime (`bouy_module`): what each import
//! reads, and the functions that the loader calls.
//!
//! - `'$module'/0`: the format, the path, the static requests in order, whether the
//!   top-level code awaits, and the link error, if any.
//! - `'$body'/0`: the top-level code of an ES module; a promise when it awaits.
//! - `'$cjs'/0`: the wrapper function of a `CommonJS` module.
//! - `'$json'/0`: the text of a JSON module.
//! - `'$export'/1`: the value of an exported binding, by its key (`link::Binding`).
//! - `'$namespace'/0`: the export names in order, each with a fun that reads it.
//! - `'$resolve'/2`: what a string specifier of the module names, for `import()`,
//!   `require`, and `import.meta.resolve`.
//! - `'$graph'/0`, in the entry module: the path and the Erlang module of every module.

use oxc::ast::ast::{ImportExpression, Program, Statement};

use super::context::{Lowerer, Top};
use super::graph::{Graph, Kind, Resolved, Unit};
use super::link::{Binding, Linked};
use crate::diagnostic::{Code, Diagnostic};
use crate::erlang::{Clause, Expr, Function};
use crate::resolve::Mode;

/// What the lowering of one module knows about the graph.
#[derive(Debug, Clone, Copy)]
pub struct Linking<'c> {
    pub graph: &'c Graph,
    pub unit: usize,
    pub link: &'c Linked,
    pub entry: bool,
}

impl<'c> Linking<'c> {
    pub fn unit(&self) -> &'c Unit {
        &self.graph.units[self.unit]
    }

    fn module_of(&self, unit: usize) -> String {
        self.graph.units[unit].name.clone()
    }

    /// The Erlang expression that reads a binding.
    pub fn read(&self, binding: &Binding) -> Expr {
        match binding {
            // The key of a CommonJS or JSON export is the export name as a string of
            // the engine, which the loader's snapshot uses.
            Binding::Export { unit, key } => {
                let key = match self.graph.units[*unit].kind {
                    Kind::Esm => Expr::binary(key.clone()),
                    _ => Expr::js_string(key),
                };
                Expr::call(&self.module_of(*unit), "$export", vec![key])
            }
            Binding::Namespace(unit) => Expr::call(
                "bouy_module",
                "namespace",
                vec![Expr::atom(self.module_of(*unit))],
            ),
            Binding::Builtin { name, export } => Expr::call(
                "bouy_module",
                "builtin_export",
                vec![Expr::js_string(name), Expr::js_string(export)],
            ),
            Binding::BuiltinNamespace(name) => Expr::call(
                "bouy_module",
                "builtin_namespace",
                vec![Expr::js_string(name)],
            ),
        }
    }

    /// `'$module'/0`
    fn module_info(&self) -> Function {
        let error = match &self.link.error {
            Some(error) => Expr::Tuple(vec![
                Expr::js_string(error.kind),
                error.code.map_or_else(Expr::undefined, Expr::js_string),
                Expr::js_string(&error.message),
            ]),
            None => Expr::atom("none"),
        };
        self.module_info_with(error)
    }

    fn module_info_with(&self, error: Expr) -> Function {
        let unit = self.unit();
        let kind = match unit.kind {
            Kind::Esm => "esm",
            Kind::CommonJs => "cjs",
            Kind::Json => "json",
        };
        let requests = unit
            .record
            .order
            .iter()
            .filter_map(|specifier| {
                unit.requests
                    .iter()
                    .find_map(|request| match &request.resolved {
                        Resolved::Unit(target, _)
                            if &request.specifier == specifier && request.mode == Mode::Import =>
                        {
                            Some(Expr::atom(self.module_of(*target)))
                        }
                        _ => None,
                    })
            })
            .collect();
        constant(
            "$module",
            Expr::Map(vec![
                (Expr::atom("kind"), Expr::atom(kind)),
                (Expr::atom("path"), Expr::js_string(&path_text(&unit.path))),
                (Expr::atom("requests"), Expr::List(requests)),
                (
                    Expr::atom("async"),
                    Expr::atom(if unit.record.has_await {
                        "true"
                    } else {
                        "false"
                    }),
                ),
                (Expr::atom("error"), error),
            ]),
        )
    }

    /// `'$namespace'/0`
    fn namespace(&self) -> Function {
        let entries = self
            .link
            .namespace
            .iter()
            .map(|(name, binding)| {
                Expr::Tuple(vec![
                    Expr::js_string(name),
                    Expr::Fun {
                        name: None,
                        clauses: vec![Clause {
                            patterns: vec![],
                            guards: vec![],
                            body: vec![self.read(binding)],
                        }],
                    },
                ])
            })
            .collect();
        constant("$namespace", Expr::List(entries))
    }

    /// `'$resolve'/2`
    fn resolver(&self) -> Function {
        let mut clauses: Vec<Clause> = self
            .unit()
            .requests
            .iter()
            .map(|request| {
                let mode = Expr::atom(match request.mode {
                    Mode::Import => "import",
                    Mode::Require => "require",
                });
                let target = match &request.resolved {
                    Resolved::Unit(unit, path) => Expr::Tuple(vec![
                        Expr::js_string(&path_text(path)),
                        Expr::atom(self.module_of(*unit)),
                    ]),
                    Resolved::Path(path) => {
                        Expr::Tuple(vec![Expr::js_string(&path_text(path)), Expr::atom("none")])
                    }
                    Resolved::Builtin(name) => Expr::tagged("builtin", Expr::js_string(name)),
                    Resolved::Missing(failure) => Expr::Tuple(vec![
                        Expr::atom("error"),
                        Expr::js_string(failure.code),
                        Expr::js_string(&failure.message),
                    ]),
                };
                Clause {
                    patterns: vec![Expr::js_string(&request.specifier), mode],
                    guards: vec![],
                    body: vec![target],
                }
            })
            .collect();
        clauses.push(Clause {
            patterns: vec![Expr::var("_"), Expr::var("_")],
            guards: vec![],
            body: vec![Expr::atom("none")],
        });
        Function {
            name: "$resolve".to_owned(),
            clauses,
        }
    }

    /// `'$graph'/0`: every module of the program, for `import()` and `require` of a
    /// specifier that the code computes.
    fn modules(&self) -> Function {
        let entries = self
            .graph
            .units
            .iter()
            .map(|unit| {
                Expr::Tuple(vec![
                    Expr::js_string(&path_text(&unit.path)),
                    Expr::atom(unit.name.clone()),
                ])
            })
            .collect();
        constant("$graph", Expr::List(entries))
    }

    /// The interface functions that every format shares.
    pub fn interface(&self) -> Vec<Function> {
        let mut functions = vec![self.module_info(), self.namespace(), self.resolver()];
        if self.entry {
            functions.push(self.modules());
            functions.push(init_function(&self.unit().name));
        }
        functions
    }

    /// The functions of a module that does not compile: linking or loading it throws
    /// its first diagnostic, a `SyntaxError` for a syntax error, as Node throws one.
    pub fn broken_functions(&self, diagnostics: &[Diagnostic]) -> Vec<Function> {
        let error = diagnostics.first().map_or_else(
            || Expr::atom("none"),
            |diagnostic| {
                let syntax = diagnostic.code == Code::Syntax;
                Expr::Tuple(vec![
                    Expr::js_string(if syntax { "SyntaxError" } else { "Error" }),
                    if syntax {
                        Expr::undefined()
                    } else {
                        Expr::js_string(diagnostic.code.as_str())
                    },
                    Expr::js_string(&diagnostic.to_string()),
                ])
            },
        );
        let broken = Expr::call(
            "bouy_module",
            "broken",
            vec![Expr::atom(self.unit().name.clone())],
        );
        vec![
            self.module_info_with(error),
            constant("$namespace", Expr::List(vec![])),
            self.resolver(),
            constant("$body", broken.clone()),
            constant("$cjs", broken.clone()),
            constant("$json", broken.clone()),
            Function {
                name: "$export".to_owned(),
                clauses: vec![Clause {
                    patterns: vec![Expr::var("_")],
                    guards: vec![],
                    body: vec![broken],
                }],
            },
        ]
    }

    /// The functions of a JSON module.
    pub fn json_functions(&self) -> Vec<Function> {
        let mut functions = self.interface();
        functions.push(constant("$json", Expr::binary(self.unit().source.clone())));
        functions.push(foreign_export(&self.unit().name));
        functions
    }
}

/// `'__init__'/0`: runs the program from this module, then the realm until no work is
/// left.
fn init_function(module: &str) -> Function {
    let main = Expr::Fun {
        name: None,
        clauses: vec![Clause {
            patterns: vec![],
            guards: vec![],
            body: vec![Expr::call(
                "bouy_module",
                "run",
                vec![Expr::atom(module.to_owned())],
            )],
        }],
    };
    constant_body(
        "__init__",
        vec![Expr::call("bouy_jobs", "run_main", vec![main]), Expr::ok()],
    )
}

/// `'$export'/1` of a `CommonJS` or JSON module: the snapshot of `module.exports` that the
/// loader took after it ran the module.
fn foreign_export(module: &str) -> Function {
    Function {
        name: "$export".to_owned(),
        clauses: vec![Clause {
            patterns: vec![Expr::var("Key")],
            guards: vec![],
            body: vec![Expr::call(
                "bouy_module",
                "foreign_export",
                vec![Expr::atom(module.to_owned()), Expr::var("Key")],
            )],
        }],
    }
}

fn constant(name: &str, value: Expr) -> Function {
    constant_body(name, vec![value])
}

fn constant_body(name: &str, body: Vec<Expr>) -> Function {
    Function {
        name: name.to_owned(),
        clauses: vec![Clause {
            patterns: vec![],
            guards: vec![],
            body,
        }],
    }
}

fn path_text(path: &std::path::Path) -> String {
    path.to_string_lossy().into_owned()
}

impl<'a> Lowerer<'a, '_> {
    /// The functions of a `CommonJS` module: `'$cjs'/0` evaluates the wrapper function.
    pub fn commonjs_functions(&mut self, program: &'a Program<'a>) -> Vec<Function> {
        let wrapper = program.body.iter().find_map(|statement| match statement {
            Statement::ExpressionStatement(statement) => Some(&statement.expression),
            _ => None,
        });
        let mut body = Vec::new();
        if let Some(wrapper) = wrapper {
            let value = self.expr(wrapper);
            body.append(&mut self.pre);
            body.push(value);
        }
        let mut functions = self.linking.interface();
        functions.push(constant_body("$cjs", body));
        functions.push(foreign_export(&self.module));
        functions.append(&mut self.extra);
        functions
    }

    /// `'$export'/1` of an ES module: one clause for each exported local binding.
    pub fn export_function(&mut self, program: &'a Program<'a>) -> Function {
        let mut clauses = Vec::new();
        for local in self.linking.link.exported_locals.clone() {
            self.frame = super::context::Frame::default();
            self.pre.clear();
            let value = if local == "*default*" {
                self.default_value(program)
            } else {
                match self
                    .semantic
                    .scoping()
                    .get_root_binding(local.as_str().into())
                {
                    Some(symbol) => self.exported_value(symbol),
                    None => continue,
                }
            };
            let mut body = std::mem::take(&mut self.pre);
            body.push(value);
            clauses.push(Clause {
                patterns: vec![Expr::binary(local)],
                guards: vec![],
                body,
            });
        }
        if clauses.is_empty() {
            clauses.push(Clause {
                patterns: vec![Expr::var("Key")],
                guards: vec![],
                body: vec![Expr::call(
                    "erlang",
                    "error",
                    vec![Expr::tagged("no_export", Expr::var("Key"))],
                )],
            });
        }
        Function {
            name: "$export".to_owned(),
            clauses,
        }
    }

    /// The value of an exported local binding. A class reads as uninitialized until its
    /// declaration runs.
    fn exported_value(&mut self, symbol: oxc::semantic::SymbolId) -> Expr {
        match self.tops.get(&symbol).cloned() {
            Some(Top::Class(name)) => self.declared_class(&name),
            _ => self.read_symbol(symbol, oxc::span::Span::default()),
        }
    }

    /// The class `name` once its declaration ran in this realm.
    fn declared_class(&mut self, name: &str) -> Expr {
        let found = self.fresh("C");
        Expr::case(
            Expr::call("erlang", "get", vec![self.class_key(name)]),
            vec![
                Clause::new(
                    Expr::undefined(),
                    vec![Expr::call(
                        "bouy_module",
                        "uninitialized",
                        vec![
                            Expr::js_string(name),
                            Expr::Fun {
                                name: None,
                                clauses: vec![Clause {
                                    patterns: vec![],
                                    guards: vec![],
                                    body: vec![Expr::local_call(
                                        "$class",
                                        vec![Expr::binary(name.to_owned())],
                                    )],
                                }],
                            },
                        ],
                    )],
                ),
                Clause::new(Expr::var(found.clone()), vec![Expr::var(found)]),
            ],
        )
    }

    /// The value of the local `*default*`: an anonymous default function or class, or
    /// the variable that `export default <expression>` sets.
    fn default_value(&mut self, program: &'a Program<'a>) -> Expr {
        use oxc::ast::ast::ExportDefaultDeclarationKind as Default;
        let declaration = program.body.iter().find_map(|statement| match statement {
            Statement::ExportDefaultDeclaration(export) => Some(&export.declaration),
            _ => None,
        });
        match declaration {
            Some(Default::FunctionDeclaration(function)) => {
                self.static_function("*default*", super::function::length_of(&function.params))
            }
            Some(Default::ClassDeclaration(_)) => self.declared_class("default"),
            _ => self.bind(Expr::local_call("$get_*default*", vec![])),
        }
    }

    /// `import(specifier, options)`: a promise of the namespace.
    pub fn dynamic_import(&mut self, import: &'a ImportExpression<'a>) -> Expr {
        let specifier = self.expr(&import.source);
        let specifier = self.bind(specifier);
        let options = match &import.options {
            Some(options) => self.expr(options),
            None => Expr::undefined(),
        };
        let phase = match import.phase {
            Some(oxc::ast::ast::ImportPhase::Source) => "source",
            Some(oxc::ast::ast::ImportPhase::Defer) => "defer",
            None => "evaluation",
        };
        self.bind(Expr::call(
            "bouy_module",
            "dynamic_import",
            vec![
                Expr::atom(self.module.clone()),
                specifier,
                options,
                Expr::atom(phase),
            ],
        ))
    }

    /// `import.meta`
    pub fn import_meta(&mut self) -> Expr {
        self.bind(Expr::call(
            "bouy_module",
            "meta",
            vec![Expr::atom(self.module.clone())],
        ))
    }
}
