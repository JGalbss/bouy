//! The shared state of the reference lowering: what a name refers to, the frame of the
//! function being lowered, the continuation of a statement, and the small builders that
//! every part of the lowering uses.

use std::collections::HashMap;

use oxc::ast::ast::Expression;
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::Span;

use super::analyze::Analysis;
use super::suspend::is_marker;
use crate::diagnostic::{Code, Reporter};
use crate::erlang::{Clause, Expr, Function};

/// What a module-level name refers to.
#[derive(Debug, Clone)]
pub enum Top {
    /// A function declaration: the Erlang function `'name'/2`, its `length`, and its kind
    /// (`normal`, `generator`, `async`, or `async_generator`).
    Function {
        name: String,
        length: usize,
        kind: &'static str,
    },
    /// A class: created once per realm by `'$class'/1`.
    Class(String),
    /// A `const` or `let`: one per realm, in the process dictionary.
    Var(String),
    /// A `const` with a literal initializer, inlined.
    Literal(Expr),
    /// A function imported from "bouy".
    Bouy(String),
    /// A `var` or a function of a script's top-level code: a property of the global
    /// object (ECMA-262 §16.1.7).
    Global(String),
}

#[derive(Debug, Clone)]
pub enum Local {
    /// A single-assignment variable: the Erlang name of its current version.
    Var(String),
    /// A heap cell: the Erlang variable that holds `{'$c', Id}`.
    Cell(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Kind {
    #[default]
    Sync,
    Async,
    Generator,
}

/// How `return v` ends the function.
#[derive(Debug, Clone, Default)]
pub enum Ret {
    /// The value is the result of the Erlang fun.
    #[default]
    Value,
    /// An async function: call its Resolve fun.
    Resolve(String),
    /// A generator: `{done, V}`.
    Generator,
    /// A constructor: the value when it is an object, else `this`.
    Constructor,
}

/// Where control goes when a statement completes normally.
#[derive(Debug, Clone)]
pub enum Cont<'a> {
    /// Call the join fun `fun` with `args`, then the current values of `vars`. `region`
    /// is the depth of suspending `try` statements where the fun was made.
    Call {
        fun: String,
        args: Vec<Expr>,
        vars: Vec<SymbolId>,
        region: usize,
    },
    /// Fall off the end of the function.
    Return,
    /// Evaluate to this value: the completion of a reified `try` block.
    Value(Expr),
    /// The next iteration of a `for` loop: copy the per-iteration cells, run the update,
    /// and call the loop fun.
    Next {
        update: Option<&'a Expression<'a>>,
        fun: String,
        vars: Vec<SymbolId>,
        copies: Vec<SymbolId>,
        region: usize,
    },
    /// The test of a `do...while` loop, then the loop fun or `exit`.
    Test {
        test: &'a Expression<'a>,
        fun: String,
        vars: Vec<SymbolId>,
        exit: Box<Cont<'a>>,
        region: usize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetKind {
    Loop,
    Switch,
    Label,
}

/// A statement that `break` or `continue` targets.
#[derive(Debug, Clone)]
pub struct Target<'a> {
    pub kind: TargetKind,
    pub labels: Vec<String>,
    pub brk: Cont<'a>,
    pub cont: Option<Cont<'a>>,
}

/// A `try` without suspension points: its body yields completions (`normal`,
/// `{return, V}`, `{jump, I, IsContinue}`) instead of jumping, because the code after an
/// Erlang `try` must not run inside it.
#[derive(Debug, Clone)]
pub struct Reify {
    /// Targets below this index are outside the `try`.
    pub base: usize,
    /// The targets the body jumps to, and whether as a continue.
    pub jumps: Vec<(usize, bool)>,
}

/// The class around a method, for `super` and fields.
#[derive(Debug, Clone)]
pub struct ClassFrame {
    pub name: String,
    /// The home object: the prototype for instance methods, the class for static ones.
    pub home: String,
    /// The variable that holds the value of the `extends` clause.
    pub parent: Option<String>,
    /// In a constructor: the variable of new.target and the fields to define after
    /// `super(...)`.
    pub new_target: Option<String>,
    pub span: Span,
}

/// The state of the function being lowered.
#[derive(Debug, Clone, Default)]
pub struct Frame<'a> {
    pub env: HashMap<SymbolId, Local>,
    /// The Erlang variable of `this`, or none for `undefined`.
    pub this: Option<String>,
    pub kind: Kind,
    pub ret: Ret,
    pub targets: Vec<Target<'a>>,
    /// The depth of suspending `try` statements around the code.
    pub region: usize,
    /// The handler fun of each region, outermost first.
    pub handlers: Vec<String>,
    /// The Reject fun of an async function.
    pub reject: Option<String>,
    pub reify: Vec<Reify>,
    pub class: Option<ClassFrame>,
    /// Labels for the next loop, from labeled statements.
    pub labels: Vec<String>,
    /// The Erlang variable of the `arguments` object of the nearest non-arrow function.
    pub arguments: Option<String>,
    /// The Erlang variable of `new.target` in an ordinary function that reads it.
    pub new_target: Option<String>,
    /// Sloppy-mode code: a failed write does not throw, and a function called without a
    /// receiver sees the global object as `this`.
    pub sloppy: bool,
    /// The value of the function itself, for `arguments.callee`.
    pub callee: Option<Expr>,
    /// The `with` statements around the code, outermost first.
    pub withs: Vec<super::with::WithScope>,
}

pub struct Lowerer<'a, 'c> {
    pub semantic: &'a Semantic<'a>,
    pub analysis: &'c Analysis,
    pub reporter: Reporter<'c>,
    pub module: String,
    pub tops: HashMap<SymbolId, Top>,
    pub counter: usize,
    /// Module functions that classes and module variables need.
    pub extra: Vec<Function>,
    pub frame: Frame<'a>,
    /// The code that must run before the expression being lowered.
    pub pre: Vec<Expr>,
    /// The classes of the module, for `'$class'/1`.
    pub classes: Vec<String>,
    /// The `var` names and the function declarations of a script's top-level code, which
    /// become properties of the global object before the code runs.
    pub script_globals: Vec<String>,
    pub script_functions: Vec<(String, usize, &'static str)>,
    /// The code of an `eval`, and whether it is strict: the module runs in the realm that
    /// compiled it, and its `'__eval__'/0` returns the completion value.
    pub eval: Option<bool>,
}

impl Lowerer<'_, '_> {
    pub fn fresh(&mut self, base: &str) -> String {
        self.counter += 1;
        let clean: String = base
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
            .collect();
        let first = clean.chars().next().unwrap_or('V');
        if first.is_ascii_uppercase() {
            format!("{clean}_{}", self.counter)
        } else {
            format!("V_{clean}_{}", self.counter)
        }
    }

    pub fn unsupported(&mut self, span: Span, what: &str) -> Expr {
        self.reporter.report(
            span,
            Code::Unsupported,
            format!("{what} is not supported by the reference-semantics prototype"),
        );
        Expr::undefined()
    }

    pub fn symbol_of(&self, reference: Option<oxc::semantic::ReferenceId>) -> Option<SymbolId> {
        reference.and_then(|id| self.semantic.scoping().get_reference(id).symbol_id())
    }

    /// The current value of a variable: its version, or the read of its cell.
    pub fn current(&self, symbol: SymbolId) -> Expr {
        match self.frame.env.get(&symbol) {
            Some(Local::Var(name)) => Expr::var(name.clone()),
            Some(Local::Cell(name)) => cell_get(name),
            None => Expr::undefined(),
        }
    }

    /// The Erlang value that carries a variable into a join fun: the version, or the cell.
    pub fn carried(&self, symbol: SymbolId) -> Expr {
        match self.frame.env.get(&symbol) {
            Some(Local::Var(name) | Local::Cell(name)) => Expr::var(name.clone()),
            None => Expr::undefined(),
        }
    }

    /// Binds fresh parameter names for `vars` in the environment and returns them.
    pub fn rebind_params(&mut self, vars: &[SymbolId]) -> Vec<Expr> {
        vars.iter()
            .map(|symbol| {
                let name = self.semantic.scoping().symbol_name(*symbol).to_owned();
                let fresh = self.fresh(&capitalize(&name));
                let local = match self.frame.env.get(symbol) {
                    Some(Local::Cell(_)) => Local::Cell(fresh.clone()),
                    _ => Local::Var(fresh.clone()),
                };
                self.frame.env.insert(*symbol, local);
                Expr::var(fresh)
            })
            .collect()
    }

    /// Whether the code of `scope` is sloppy. Bouy runs TypeScript as ES modules, which are
    /// strict, as Node does for a package of `"type": "module"`. A JavaScript script is
    /// sloppy unless a directive makes it strict.
    pub fn is_sloppy(&self, scope: Option<oxc::semantic::ScopeId>) -> bool {
        let scoping = self.semantic.scoping();
        !self.semantic.source_type().is_typescript()
            && !scoping
                .scope_flags(scope.unwrap_or_else(|| scoping.root_scope_id()))
                .is_strict_mode()
    }

    /// Whether the code is a JavaScript script, whose top-level `this` is the global object.
    pub fn is_script(&self) -> bool {
        let source_type = self.semantic.source_type();
        !source_type.is_typescript() && !source_type.is_module()
    }

    pub fn this_expr(&self) -> Expr {
        match &self.frame.this {
            Some(name) => Expr::var(name.clone()),
            None => Expr::undefined(),
        }
    }

    /// Lowers `f` in a buffer of its own, for a branch of an expression: the code, then
    /// the value.
    pub fn branch(&mut self, f: impl FnOnce(&mut Self) -> Expr) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        let value = f(self);
        let mut code = std::mem::replace(&mut self.pre, saved);
        code.push(value);
        if code.iter().any(is_marker) {
            self.reporter.report(
                Span::default(),
                Code::Unsupported,
                "`await` or `yield` inside a conditional part of an expression is not supported by the reference-semantics prototype",
            );
        }
        code
    }

    /// Binds a non-trivial value to a fresh variable, so that it runs at this point.
    pub fn bind(&mut self, value: Expr) -> Expr {
        if value.is_trivial() {
            return value;
        }
        let name = self.fresh("T");
        self.pre.push(Expr::matches(Expr::var(name.clone()), value));
        Expr::var(name)
    }
}

pub fn cell_get(name: &str) -> Expr {
    Expr::call(
        "erlang",
        "get",
        vec![Expr::call(
            "erlang",
            "element",
            vec![Expr::Integer(2), Expr::var(name.to_owned())],
        )],
    )
}

pub fn cell_set(name: &str, value: Expr) -> Expr {
    Expr::call(
        "bouy_heap",
        "cell_set",
        vec![Expr::var(name.to_owned()), value],
    )
}

pub fn throw_value(value: Expr) -> Expr {
    Expr::call(
        "erlang",
        "error",
        vec![Expr::Tuple(vec![Expr::atom("$throw"), value])],
    )
}

pub fn boolean_case(test: Expr, yes: Vec<Expr>, no: Vec<Expr>) -> Expr {
    Expr::case(
        test,
        vec![
            Clause::new(Expr::atom("true"), yes),
            Clause::new(Expr::atom("false"), no),
        ],
    )
}

pub fn block(mut code: Vec<Expr>) -> Expr {
    if code.len() == 1 {
        return code.remove(0);
    }
    Expr::Block(code)
}

pub fn capitalize(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => "V".to_owned(),
    }
}
