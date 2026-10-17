//! The shared state of the reference lowering: what a name refers to, the frame of the
//! function being lowered, the continuation of a statement, and the small builders that
//! every part of the lowering uses.

use std::collections::HashMap;

use oxc::ast::ast::Expression;
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::Span;

use super::analyze::Analysis;
use crate::diagnostic::{Code, Reporter};
use crate::erlang::{Clause, Expr, Function};

/// What a module-level name refers to.
#[derive(Debug, Clone)]
pub enum Top {
    /// A function declaration: the Erlang function `'name'/2`, its `length`, and the
    /// form of its static function value (`fn`, `async`, `generator`, `async_generator`,
    /// or `fn_nt` for a function that reads `new.target`).
    Function {
        name: String,
        length: usize,
        form: &'static str,
    },
    /// A class: created once per realm by `'$class'/1`.
    Class(String),
    /// A `const` or `let`: one per realm, in the process dictionary.
    Var(String),
    /// A `const` with a literal initializer, inlined.
    Literal(Expr),
    /// A function imported from "bouy".
    Bouy(String),
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
    AsyncGenerator,
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
    /// The nesting order among the reified `try`s and the finally frames.
    pub order: usize,
    /// The targets the body jumps to, and whether as a continue.
    pub jumps: Vec<(usize, bool)>,
}

/// The class or object literal around a method, for `super` and fields.
#[derive(Debug, Clone)]
pub struct ClassFrame {
    /// The home object: the prototype for instance methods, the class for static ones,
    /// or the object of an object literal method.
    pub home: String,
    /// The class constructor, whose prototype `super(...)` constructs.
    pub class: Option<String>,
    /// The fun that adds the private methods and the fields of the class to `this`.
    pub init: Option<String>,
}

/// A statement whose code must run when control leaves it abruptly: a `try` with a
/// `finally` block, or a `for...of` loop, which closes its iterator. `fun` takes the
/// completion: `normal`, `{throw, E}`, `{return, V}`, or `{jump, Index, IsContinue}`.
#[derive(Debug, Clone)]
pub struct FinallyFrame {
    pub fun: String,
    /// The nesting order among the reified `try`s and the finally frames.
    pub order: usize,
    /// Targets below this index are outside the statement.
    pub base: usize,
    /// The region depth where `fun` was made.
    pub region: usize,
    /// The jumps that leave the statement.
    pub jumps: Vec<(usize, bool)>,
    /// A loop target whose `continue` stays inside: the loop of a `for...of`.
    pub stays: Option<usize>,
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
    /// The cell of `this` in a derived constructor, which `super(...)` binds.
    pub this_cell: Option<String>,
    /// The Erlang variable of `new.target`, or none for `undefined`.
    pub new_target: Option<String>,
    /// The Yield fun of an async generator.
    pub yield_fun: Option<String>,
    /// The statements around the code whose code runs on an abrupt completion.
    pub finally: Vec<FinallyFrame>,
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
    /// The private names of the class bodies around the code, innermost last: each
    /// name and the Erlang expression of its key.
    pub privates: Vec<Vec<(String, Expr)>>,
    /// The class bindings of the class bodies around the code, which are constant there.
    pub class_bindings: Vec<SymbolId>,
    /// The bindings that code reads before their declaration runs (`early`).
    pub early: std::collections::HashSet<SymbolId>,
    /// The resource cell of the `using` declaration being lowered.
    pub using_stacks: Vec<String>,
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

    /// The nesting order of the next reified `try` or finally frame.
    pub fn next_order(&self) -> usize {
        self.frame.reify.len() + self.frame.finally.len()
    }

    /// Whether the innermost frame that catches abrupt completions is a reified `try`.
    pub fn reify_innermost(&self) -> bool {
        match (self.frame.reify.last(), self.frame.finally.last()) {
            (Some(reify), Some(finally)) => reify.order > finally.order,
            (Some(_), None) => true,
            _ => false,
        }
    }

    pub fn this_expr(&self) -> Expr {
        if let Some(cell) = &self.frame.this_cell {
            return Expr::call("bouy_ref_class", "this_of", vec![Expr::var(cell.clone())]);
        }
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
