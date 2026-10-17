//! The reference-semantics lowering (prototype, `bouy run --semantics reference`).
//!
//! Objects live in the heap of a realm (`bouy_heap`) and have identity. A local variable
//! that a closure changes or sees change, or that a `try` or a conditional expression
//! changes, is a heap cell. Every other local is a single-assignment Erlang variable with
//! versions.
//!
//! Statements lower in continuation-passing style. A compound statement gets the rest of
//! its block as a join fun, whose parameters are the versions of the variables that the
//! statement changes, and every path of the statement ends in a tail call. A loop is a
//! named fun that calls itself. Expressions lower in A-normal form: each step binds a
//! fresh variable, so the Erlang code keeps the evaluation order of JavaScript.
//!
//! `await` and `yield` leave a marker in the code of a statement. `seal` splits a body at
//! each marker: the rest of the body becomes the fun that a promise reaction or `next()`
//! calls later. A `try` that holds a suspension point is a region: each segment of its
//! body runs inside an Erlang `try` whose handler is the `catch` clause, and a jump out of
//! the region returns `{'$k', Fun, Args}` so that the wrapper calls `Fun` outside the
//! Erlang `try`.

mod analyze;
mod class;
mod expr;
mod pattern;
mod stmt;

use std::collections::HashMap;

use oxc::ast::ast::{
    BindingPattern, Declaration, ExportDefaultDeclarationKind, Expression, FormalParameters,
    FunctionBody, ImportDeclarationSpecifier, Program, Statement, VariableDeclarationKind,
};
use oxc::ast_visit::Visit;
use oxc::semantic::{Semantic, SymbolId};
use oxc::span::Span;

use crate::diagnostic::{Code, Diagnostic, Reporter};
use crate::erlang::{self, CatchClause, Clause, Expr, Function};
use crate::graph;
use crate::parse::with_program;

use analyze::Analysis;

/// What a module-level name refers to.
#[derive(Debug, Clone)]
pub enum Top {
    /// A function declaration: the Erlang function `'name'/2`.
    Function(String),
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
}

/// Lowers `module` with reference semantics.
pub fn lower_module(module: &graph::Module) -> Result<String, Vec<Diagnostic>> {
    with_program(&module.path, &module.source, |program, semantic| {
        let analysis = analyze::analyze(program, semantic);
        let mut lowerer = Lowerer {
            semantic,
            analysis: &analysis,
            reporter: Reporter::new(&module.path, &module.source),
            module: module.name.clone(),
            tops: HashMap::new(),
            counter: 0,
            extra: Vec::new(),
            frame: Frame::default(),
            pre: Vec::new(),
            classes: Vec::new(),
        };
        lowerer.declare(program);
        let functions = lowerer.module_functions(program);
        if lowerer.reporter.diagnostics.is_empty() {
            Ok(erlang::print_module(&erlang::Module {
                name: module.name.clone(),
                functions,
            }))
        } else {
            Err(lowerer.reporter.diagnostics)
        }
    })?
}

/// The declarations of a statement at module level, export or not.
fn declaration<'r, 'a>(statement: &'r Statement<'a>) -> Option<&'r Declaration<'a>> {
    match statement {
        Statement::ExportDeclaration(export) => Some(&export.declaration),
        _ => statement.as_declaration(),
    }
}

impl<'a> Lowerer<'a, '_> {
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

    /// Classifies the module-level names.
    fn declare(&mut self, program: &'a Program<'a>) {
        for statement in &program.body {
            if let Statement::ImportDeclaration(import) = statement {
                if !import.import_kind.is_value() {
                    continue;
                }
                if import.source.value.as_str() != "bouy" {
                    self.reporter.report(
                        import.span,
                        Code::BadImport,
                        "the reference-semantics prototype compiles one module and imports only from \"bouy\"",
                    );
                    continue;
                }
                for specifier in import.specifiers.iter().flatten() {
                    if let ImportDeclarationSpecifier::ImportSpecifier(specifier) = specifier
                        && let Some(symbol) = specifier.local.symbol_id.get()
                    {
                        self.tops
                            .insert(symbol, Top::Bouy(specifier.imported.name().to_string()));
                    }
                }
                continue;
            }
            if let Statement::ExportDefaultDeclaration(export) = statement {
                match &export.declaration {
                    ExportDefaultDeclarationKind::FunctionDeclaration(function) => {
                        if let Some(id) = &function.id
                            && let Some(symbol) = id.symbol_id.get()
                        {
                            self.tops.insert(symbol, Top::Function(id.name.to_string()));
                        }
                    }
                    ExportDefaultDeclarationKind::ClassDeclaration(class) => {
                        if let Some(id) = &class.id
                            && let Some(symbol) = id.symbol_id.get()
                        {
                            self.tops.insert(symbol, Top::Class(id.name.to_string()));
                        }
                    }
                    _ => {}
                }
                continue;
            }
            match declaration(statement) {
                Some(Declaration::FunctionDeclaration(function)) => {
                    if let Some(id) = &function.id
                        && let Some(symbol) = id.symbol_id.get()
                        && function.body.is_some()
                    {
                        self.tops.insert(symbol, Top::Function(id.name.to_string()));
                    }
                }
                Some(Declaration::ClassDeclaration(class)) => {
                    if let Some(id) = &class.id
                        && let Some(symbol) = id.symbol_id.get()
                        && !class.declare
                    {
                        self.tops.insert(symbol, Top::Class(id.name.to_string()));
                    }
                }
                Some(Declaration::VariableDeclaration(variables)) if !variables.declare => {
                    for declarator in &variables.declarations {
                        let literal = match (&declarator.id, &declarator.init) {
                            (BindingPattern::BindingIdentifier(_), Some(init))
                                if variables.kind == VariableDeclarationKind::Const =>
                            {
                                expr::literal(init)
                            }
                            _ => None,
                        };
                        for id in declarator.id.get_binding_identifiers() {
                            if let Some(symbol) = id.symbol_id.get() {
                                let top = match &literal {
                                    Some(value) => Top::Literal(value.clone()),
                                    None => Top::Var(id.name.to_string()),
                                };
                                self.tops.insert(symbol, top);
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }

    /// Every Erlang function of the module.
    fn module_functions(&mut self, program: &'a Program<'a>) -> Vec<Function> {
        let mut functions = Vec::new();
        let mut body: Vec<&'a Statement<'a>> = Vec::new();
        for statement in &program.body {
            match statement {
                Statement::ImportDeclaration(_) => {}
                Statement::ExportDefaultDeclaration(export) => match &export.declaration {
                    ExportDefaultDeclarationKind::FunctionDeclaration(function) => {
                        if let Some(id) = &function.id {
                            functions.push(self.module_function(id.name.as_str(), function));
                        }
                    }
                    ExportDefaultDeclarationKind::ClassDeclaration(class) => {
                        if let Some(id) = &class.id {
                            self.module_class(id.name.as_str(), class);
                        }
                    }
                    _ => {
                        self.unsupported(export.span, "this `export default`");
                    }
                },
                _ => match declaration(statement) {
                    Some(Declaration::FunctionDeclaration(function)) => {
                        if let Some(id) = &function.id
                            && function.body.is_some()
                        {
                            functions.push(self.module_function(id.name.as_str(), function));
                        }
                    }
                    Some(Declaration::ClassDeclaration(class)) => {
                        if let Some(id) = &class.id
                            && !class.declare
                        {
                            self.module_class(id.name.as_str(), class);
                        }
                    }
                    Some(Declaration::VariableDeclaration(variables)) if !variables.declare => {
                        self.module_variables(variables);
                        body.push(statement);
                    }
                    Some(_) => {}
                    None => body.push(statement),
                },
            }
        }
        functions.push(self.init(&body));
        functions.push(self.class_dispatch());
        functions.append(&mut self.extra);
        functions
    }

    /// `'__init__'/0`: runs the top-level code as the first job of the main realm, then
    /// the realm until no work is left.
    fn init(&mut self, body: &[&'a Statement<'a>]) -> Function {
        let mut suspends = analyze::Suspends::default();
        for statement in body {
            suspends.visit_statement(statement);
        }
        self.frame = Frame::default();
        let statements = body.to_vec();
        let code = if suspends.0 {
            self.async_body(|me| me.stmts(statements, &Cont::Return))
        } else {
            self.stmts(statements, &Cont::Value(Expr::undefined()))
        };
        let main = Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: code,
            }],
        };
        Function {
            name: "__init__".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: vec![Expr::call("bouy_jobs", "run_main", vec![main]), Expr::ok()],
            }],
        }
    }

    /// `'$class'/1`: the class of this realm, created on first use.
    fn class_dispatch(&mut self) -> Function {
        let mut clauses: Vec<Clause> = self
            .classes
            .iter()
            .map(|name| {
                let key = self.class_key(name);
                let found = Expr::var("C");
                Clause::new(
                    Expr::binary(name.clone()),
                    vec![Expr::case(
                        Expr::call("erlang", "get", vec![key]),
                        vec![
                            Clause::new(
                                Expr::undefined(),
                                vec![Expr::local_call(&format!("{name}#make"), vec![])],
                            ),
                            Clause::new(found.clone(), vec![found]),
                        ],
                    )],
                )
            })
            .collect();
        clauses.push(Clause::new(
            Expr::var("Name"),
            vec![Expr::call(
                "erlang",
                "error",
                vec![Expr::Tuple(vec![Expr::atom("no_class"), Expr::var("Name")])],
            )],
        ));
        Function {
            name: "$class".to_owned(),
            clauses,
        }
    }

    pub fn class_key(&self, name: &str) -> Expr {
        Expr::Tuple(vec![
            Expr::atom("$class"),
            Expr::atom(self.module.clone()),
            Expr::binary(name.to_owned()),
        ])
    }

    pub fn var_key(&self, name: &str) -> Expr {
        Expr::Tuple(vec![
            Expr::atom("$m"),
            Expr::atom(self.module.clone()),
            Expr::binary(name.to_owned()),
        ])
    }

    /// `'$get_x'/0` for each module variable: its value in this realm, initialized on first
    /// read in a realm whose top-level code did not run, such as an actor.
    fn module_variables(&mut self, variables: &'a oxc::ast::ast::VariableDeclaration<'a>) {
        for declarator in &variables.declarations {
            let mut suspends = analyze::Suspends::default();
            if let Some(init) = &declarator.init {
                suspends.visit_expression(init);
            }
            // An initializer that awaits cannot run lazily in another realm: there the
            // variable reads as undefined.
            let simple = match &declarator.id {
                BindingPattern::BindingIdentifier(_) if !suspends.0 => declarator.init.as_ref(),
                _ => None,
            };
            for id in declarator.id.get_binding_identifiers() {
                let Some(symbol) = id.symbol_id.get() else {
                    continue;
                };
                if !matches!(self.tops.get(&symbol), Some(Top::Var(_))) {
                    continue;
                }
                self.frame = Frame::default();
                self.pre.clear();
                let value = match simple {
                    Some(init) => self.expr(init),
                    None => Expr::undefined(),
                };
                let mut init = std::mem::take(&mut self.pre);
                let key = self.var_key(id.name.as_str());
                init.push(Expr::matches(Expr::var("V"), value));
                init.push(Expr::call(
                    "erlang",
                    "put",
                    vec![key.clone(), Expr::tagged("v", Expr::var("V"))],
                ));
                init.push(Expr::var("V"));
                self.extra.push(Function {
                    name: format!("$get_{}", id.name),
                    clauses: vec![Clause {
                        patterns: vec![],
                        guards: vec![],
                        body: vec![Expr::case(
                            Expr::call("erlang", "get", vec![key]),
                            vec![
                                Clause::new(
                                    Expr::tagged("v", Expr::var("Found")),
                                    vec![Expr::var("Found")],
                                ),
                                Clause::new(Expr::undefined(), init),
                            ],
                        )],
                    }],
                });
            }
        }
        self.frame = Frame::default();
    }

    /// A module-level function declaration: `'name'(This, Args)`.
    fn module_function(
        &mut self,
        name: &str,
        function: &'a oxc::ast::ast::Function<'a>,
    ) -> Function {
        self.frame = Frame::default();
        let Some(body) = &function.body else {
            return Function {
                name: name.to_owned(),
                clauses: vec![],
            };
        };
        let (this, args, code) = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind_of(function.r#async, function.generator),
            Callee::Function(None),
        );
        Function {
            name: name.to_owned(),
            clauses: vec![Clause {
                patterns: vec![Expr::var(this), Expr::var(args)],
                guards: vec![],
                body: code,
            }],
        }
    }

    /// The value of a module-level function used as a value: the same term in every realm.
    pub fn static_function(&self, name: &str) -> Expr {
        Expr::Tuple(vec![
            Expr::atom("$f"),
            Expr::Tuple(vec![
                Expr::atom("fn"),
                Expr::atom(self.module.clone()),
                Expr::binary(name.to_owned()),
            ]),
            Expr::FunRef {
                module: Some(self.module.clone()),
                function: name.to_owned(),
                arity: 2,
            },
        ])
    }

    /// Lowers a function: returns the names of its `This` and `Args` parameters and its
    /// body.
    pub fn function_code(
        &mut self,
        params: &'a FormalParameters<'a>,
        body: FnBody<'a>,
        kind: Kind,
        callee: Callee,
    ) -> (String, String, Vec<Expr>) {
        let this_param = self.fresh("This");
        let args = self.fresh("Args");
        let outer = std::mem::take(&mut self.frame);
        let outer_pre = std::mem::take(&mut self.pre);
        let (this, class) = match callee {
            Callee::Arrow => (outer.this.clone(), outer.class.clone()),
            Callee::Function(class) => (Some(this_param.clone()), class),
        };
        self.frame = Frame {
            env: outer.env.clone(),
            this,
            kind,
            class,
            ..Frame::default()
        };
        let code = match kind {
            Kind::Sync => {
                let mut code = self.params(params, &args);
                code.extend(self.body(body));
                code
            }
            Kind::Async => {
                let args_var = args.clone();
                self.async_body(move |me| {
                    let mut code = me.params(params, &args_var);
                    code.extend(me.body(body));
                    code
                })
            }
            Kind::Generator => {
                let mut code = self.params(params, &args);
                self.frame.ret = Ret::Generator;
                let inner = self.body(body);
                code.push(Expr::call(
                    "bouy_ref",
                    "make_generator",
                    vec![Expr::Fun {
                        name: None,
                        clauses: vec![Clause {
                            patterns: vec![],
                            guards: vec![],
                            body: inner,
                        }],
                    }],
                ));
                code
            }
        };
        self.frame = outer;
        self.pre = outer_pre;
        (this_param, args, code)
    }

    /// The code of an async function body: `bouy_jobs:async_call(fun(Resolve, Reject) ->
    /// ... end)`, its first segment wrapped so a throw rejects.
    pub fn async_body(&mut self, lower: impl FnOnce(&mut Self) -> Vec<Expr>) -> Vec<Expr> {
        let resolve = self.fresh("Resolve");
        let reject = self.fresh("Reject");
        self.frame.kind = Kind::Async;
        self.frame.ret = Ret::Resolve(resolve.clone());
        self.frame.reject = Some(reject.clone());
        let code = lower(self);
        let wrapped = self.wrap_with(code, Some(reject.clone()));
        vec![Expr::call(
            "bouy_jobs",
            "async_call",
            vec![Expr::Fun {
                name: None,
                clauses: vec![Clause {
                    patterns: vec![Expr::var(resolve), Expr::var(reject)],
                    guards: vec![],
                    body: vec![wrapped],
                }],
            }],
        )]
    }

    fn body(&mut self, body: FnBody<'a>) -> Vec<Expr> {
        match body {
            FnBody::Block(block) => self.stmts(block.statements.iter().collect(), &Cont::Return),
            FnBody::Expr(expression) => {
                let value = self.expr(expression);
                let mut code = std::mem::take(&mut self.pre);
                code.push(self.ret(value));
                self.seal(code)
            }
        }
    }

    /// Binds the parameters from the argument list `args`.
    pub fn params(&mut self, params: &'a FormalParameters<'a>, args: &str) -> Vec<Expr> {
        let saved = std::mem::take(&mut self.pre);
        for (index, param) in params.items.iter().enumerate() {
            let position = Expr::Integer(i64::try_from(index + 1).unwrap_or(i64::MAX));
            let arg = Expr::call("bouy_rt", "arg", vec![position, Expr::var(args)]);
            let value = match &param.initializer {
                None => arg,
                Some(default) => {
                    let given = self.bind(arg);
                    let fallback = self.branch(|me| me.expr(default));
                    self.bind(Expr::case(
                        given.clone(),
                        vec![
                            Clause::new(Expr::undefined(), fallback),
                            Clause::new(Expr::var("_"), vec![given]),
                        ],
                    ))
                }
            };
            self.declare_pattern(&param.pattern, value);
        }
        if let Some(rest) = &params.rest {
            let position = Expr::Integer(i64::try_from(params.items.len() + 1).unwrap_or(i64::MAX));
            let value = Expr::call(
                "bouy_heap",
                "new_array",
                vec![Expr::call(
                    "bouy_rt",
                    "rest",
                    vec![position, Expr::var(args)],
                )],
            );
            let value = self.bind(value);
            self.declare_pattern(&rest.rest.argument, value);
        }
        std::mem::replace(&mut self.pre, saved)
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

    /// The expression that ends the function with `value`.
    pub fn ret(&mut self, value: Expr) -> Expr {
        if !self.frame.reify.is_empty() {
            return Expr::tagged("return", value);
        }
        match self.frame.ret.clone() {
            Ret::Value => value,
            Ret::Generator => Expr::tagged("done", value),
            Ret::Resolve(resolve) => Expr::Apply(Box::new(Expr::var(resolve)), vec![value]),
            Ret::Constructor => {
                let this = self.this_expr();
                if value == Expr::undefined() {
                    return this;
                }
                let v = self.fresh("R");
                Expr::case(
                    value,
                    vec![
                        Clause::guarded(
                            Expr::var(v.clone()),
                            vec![Expr::call(
                                "bouy_heap",
                                "is_object",
                                vec![Expr::var(v.clone())],
                            )],
                            vec![Expr::var(v)],
                        ),
                        Clause::new(Expr::var("_"), vec![this]),
                    ],
                )
            }
        }
    }

    pub fn this_expr(&self) -> Expr {
        match &self.frame.this {
            Some(name) => Expr::var(name.clone()),
            None => Expr::undefined(),
        }
    }

    /// A call of a continuation fun made at region depth `region`: direct, or, from
    /// inside a deeper suspending `try`, returned to the wrapper of the segment so that it
    /// runs outside the Erlang `try`.
    pub fn call_cont(&self, name: &str, args: Vec<Expr>, region: usize) -> Expr {
        if self.frame.region > region {
            Expr::Tuple(vec![
                Expr::atom("$k"),
                Expr::var(name.to_owned()),
                Expr::List(args),
            ])
        } else {
            Expr::Apply(Box::new(Expr::var(name.to_owned())), args)
        }
    }

    /// The code that completes a statement normally with continuation `k`.
    pub fn jump(&mut self, k: &Cont<'a>) -> Vec<Expr> {
        match k {
            Cont::Call {
                fun,
                args,
                vars,
                region,
            } => {
                let mut all = args.clone();
                all.extend(vars.iter().map(|v| self.carried(*v)));
                vec![self.call_cont(fun, all, *region)]
            }
            Cont::Value(value) => vec![value.clone()],
            Cont::Return => vec![self.ret(Expr::undefined())],
            Cont::Next {
                update,
                fun,
                vars,
                copies,
                region,
            } => {
                let saved_env = self.frame.env.clone();
                let saved = std::mem::take(&mut self.pre);
                for symbol in copies {
                    let value = self.current(*symbol);
                    let cell = self.fresh("Cell");
                    self.pre.push(Expr::matches(
                        Expr::var(cell.clone()),
                        Expr::call("bouy_heap", "cell", vec![value]),
                    ));
                    self.frame.env.insert(*symbol, Local::Cell(cell));
                }
                if let Some(update) = update {
                    self.effect(update);
                }
                let args = vars.iter().map(|v| self.carried(*v)).collect();
                let call = self.call_cont(fun, args, *region);
                let mut code = std::mem::replace(&mut self.pre, saved);
                code.push(call);
                self.frame.env = saved_env;
                code
            }
            Cont::Test {
                test,
                fun,
                vars,
                exit,
                region,
            } => {
                let saved_env = self.frame.env.clone();
                let saved = std::mem::take(&mut self.pre);
                let condition = self.test(test);
                let args = vars.iter().map(|v| self.carried(*v)).collect();
                let again = self.call_cont(fun, args, *region);
                let out = self.jump(exit);
                let mut code = std::mem::replace(&mut self.pre, saved);
                code.push(boolean_case(condition, vec![again], out));
                self.frame.env = saved_env;
                code
            }
        }
    }

    /// Wraps `code` so that a throw goes to `handler`, and `{'$k', F, A}` runs `F`
    /// outside the Erlang `try`. Without a handler the code is unchanged.
    pub fn wrap_with(&mut self, code: Vec<Expr>, handler: Option<String>) -> Expr {
        let Some(handler) = handler else {
            return block(code);
        };
        let reason = self.fresh("Reason");
        let stack = self.fresh("Stack");
        let error = self.fresh("E");
        let fun = self.fresh("F");
        let args = self.fresh("A");
        let other = self.fresh("Other");
        let attempt = Expr::Try {
            body: code,
            catches: vec![CatchClause {
                class: Expr::atom("error"),
                reason: Expr::var(reason.clone()),
                stack: stack.clone(),
                body: vec![Expr::Tuple(vec![
                    Expr::atom("$raised"),
                    Expr::call(
                        "bouy_ref",
                        "caught",
                        vec![Expr::var(reason), Expr::var(stack)],
                    ),
                ])],
            }],
            after: vec![],
        };
        Expr::case(
            attempt,
            vec![
                Clause::new(
                    Expr::Tuple(vec![Expr::atom("$raised"), Expr::var(error.clone())]),
                    vec![Expr::Apply(
                        Box::new(Expr::var(handler)),
                        vec![Expr::var(error)],
                    )],
                ),
                Clause::new(
                    Expr::Tuple(vec![
                        Expr::atom("$k"),
                        Expr::var(fun.clone()),
                        Expr::var(args.clone()),
                    ]),
                    vec![Expr::call(
                        "erlang",
                        "apply",
                        vec![Expr::var(fun), Expr::var(args)],
                    )],
                ),
                Clause::new(Expr::var(other.clone()), vec![Expr::var(other)]),
            ],
        )
    }

    /// The fun that receives a throw at this point: the handler of the innermost
    /// suspending `try`, or Reject. None in a generator outside such a `try`.
    pub fn handler(&self) -> Option<String> {
        self.frame
            .handlers
            .last()
            .cloned()
            .or_else(|| self.frame.reject.clone())
    }

    /// Splits `code` at its first suspension marker: the rest of the code becomes the
    /// continuation fun of the `await` or the `yield`.
    pub fn seal(&mut self, mut code: Vec<Expr>) -> Vec<Expr> {
        let Some(index) = code.iter().position(is_marker) else {
            return code;
        };
        let after = code.split_off(index + 1);
        let Some(Expr::Call { function, args, .. }) = code.pop() else {
            return code;
        };
        let after = self.seal(after);
        let [Expr::Var(var), value, handler] = <[Expr; 3]>::try_from(args).unwrap_or([
            Expr::var("_"),
            Expr::undefined(),
            Expr::atom("none"),
        ]) else {
            return code;
        };
        let handler = match handler {
            Expr::Var(name) => Some(name),
            _ => None,
        };
        let resumed = self.wrap_with(after, handler.clone());
        if function == "await" {
            let reject = handler.map_or_else(Expr::undefined, Expr::var);
            code.push(Expr::call(
                "bouy_jobs",
                "await",
                vec![
                    value,
                    Expr::Fun {
                        name: None,
                        clauses: vec![Clause::new(Expr::var(var), vec![resumed])],
                    },
                    reject,
                ],
            ));
            return code;
        }
        let resumption = self.fresh("Resumption");
        let thrown = self.fresh("Thrown");
        let returned = self.fresh("Returned");
        let throw = match handler {
            Some(handler) => Expr::Apply(
                Box::new(Expr::var(handler)),
                vec![Expr::var(thrown.clone())],
            ),
            None => throw_value(Expr::var(thrown.clone())),
        };
        let continuation = Expr::Fun {
            name: None,
            clauses: vec![Clause::new(
                Expr::var(resumption.clone()),
                vec![Expr::case(
                    Expr::var(resumption),
                    vec![
                        Clause::new(Expr::tagged("next", Expr::var(var)), vec![resumed]),
                        Clause::new(Expr::tagged("throw", Expr::var(thrown)), vec![throw]),
                        Clause::new(
                            Expr::tagged("return", Expr::var(returned.clone())),
                            vec![Expr::tagged("done", Expr::var(returned))],
                        ),
                    ],
                )],
            )],
        };
        code.push(Expr::Tuple(vec![Expr::atom("yield"), value, continuation]));
        code
    }

    /// A suspension marker: `seal` turns it into an `await` or a `yield`.
    pub fn marker(&mut self, kind: &str, value: Expr) -> Expr {
        let var = self.fresh("Resumed");
        let handler = self.handler().map_or_else(|| Expr::atom("none"), Expr::var);
        self.pre.push(Expr::call(
            "$suspend",
            kind,
            vec![Expr::var(var.clone()), value, handler],
        ));
        Expr::var(var)
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

/// What `this` and `super` mean in a function.
#[derive(Debug, Clone)]
pub enum Callee {
    /// An arrow function: the `this` and the class of the enclosing function.
    Arrow,
    /// A function with its own `this`, and the class frame of a method.
    Function(Option<ClassFrame>),
}

/// The body of a function: a block, or the expression of an arrow function.
#[derive(Clone, Copy)]
pub enum FnBody<'a> {
    Block(&'a FunctionBody<'a>),
    Expr(&'a Expression<'a>),
}

pub fn kind_of(is_async: bool, generator: bool) -> Kind {
    match (is_async, generator) {
        (_, true) => Kind::Generator,
        (true, false) => Kind::Async,
        (false, false) => Kind::Sync,
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

fn is_marker(expr: &Expr) -> bool {
    matches!(expr, Expr::Call { module: Some(module), .. } if module == "$suspend")
}

pub fn capitalize(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
        None => "V".to_owned(),
    }
}
