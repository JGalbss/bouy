//! The module level: module-level names, the functions of the module, `'__init__'/0`,
//! the class dispatch `'$class'/1`, and the per-realm module variables.

use oxc::ast::ast::{
    BindingPattern, Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier, Program,
    Statement, VariableDeclarationKind,
};
use oxc::ast_visit::Visit;

use super::analyze;
use super::context::{Cont, Frame, Lowerer, Top};
use super::function::{Callee, FnBody, Itself, kind_of, length_of};
use super::literal::literal;
use crate::diagnostic::Code;
use crate::erlang::{Clause, Expr, Function};

/// The declarations of a statement at module level, export or not.
pub fn declaration<'r, 'a>(statement: &'r Statement<'a>) -> Option<&'r Declaration<'a>> {
    match statement {
        Statement::ExportDeclaration(export) => Some(&export.declaration),
        _ => statement.as_declaration(),
    }
}

impl<'a> Lowerer<'a, '_> {
    /// Classifies the module-level names.
    pub fn declare(&mut self, program: &'a Program<'a>) {
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
                        self.declare_function(function);
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
                Some(Declaration::FunctionDeclaration(function)) if function.body.is_some() => {
                    self.declare_function(function);
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
                                literal(init)
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
        // A `var` in a block or a loop of the top-level code is a module variable too.
        for symbol in top_level_vars(program) {
            let name = self.semantic.scoping().symbol_name(symbol).to_owned();
            self.tops.entry(symbol).or_insert(Top::Var(name));
        }
        // The `var` names of strict eval code belong to the eval.
        if self.is_script() && (self.eval.is_none() || self.is_sloppy(None)) {
            self.declare_script_globals(program);
        }
    }

    /// A script's top-level `var` names and functions are properties of the global object.
    /// A function that the code never assigns keeps its Erlang function for calls.
    fn declare_script_globals(&mut self, program: &'a Program<'a>) {
        for symbol in top_level_vars(program) {
            let name = self.semantic.scoping().symbol_name(symbol).to_owned();
            self.script_globals.push(name.clone());
            self.tops.insert(symbol, Top::Global(name));
        }
        for statement in &program.body {
            if let Statement::FunctionDeclaration(function) = statement
                && let Some(id) = &function.id
                && let Some(symbol) = id.symbol_id.get()
                && let Some(Top::Function { name, length, kind }) = self.tops.get(&symbol).cloned()
            {
                self.script_functions.push((name.clone(), length, kind));
                let assigned = self
                    .semantic
                    .scoping()
                    .get_resolved_references(symbol)
                    .any(oxc::semantic::Reference::is_write);
                if assigned {
                    self.tops.insert(symbol, Top::Global(name));
                }
            }
        }
    }

    /// A module-level function declaration: the Erlang function of its name.
    fn declare_function(&mut self, function: &'a oxc::ast::ast::Function<'a>) {
        if let Some(id) = &function.id
            && let Some(symbol) = id.symbol_id.get()
        {
            let kind = self.value_kind(function);
            self.tops.insert(
                symbol,
                Top::Function {
                    name: id.name.to_string(),
                    length: length_of(&function.params),
                    kind,
                },
            );
        }
    }

    /// Every Erlang function of the module.
    pub fn module_functions(&mut self, program: &'a Program<'a>) -> Vec<Function> {
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
        self.nested_var_getters(program);
        functions.push(match self.eval {
            Some(_) => self.eval_function(&body),
            None => self.init(&body),
        });
        functions.push(self.class_dispatch());
        functions.append(&mut self.extra);
        functions
    }

    /// The call that makes a script's `var` names and functions properties of the global
    /// object before its code runs.
    fn declare_globals_call(&self) -> Expr {
        let vars = self
            .script_globals
            .iter()
            .map(|name| Expr::js_string(name))
            .collect();
        let functions = self
            .script_functions
            .iter()
            .map(|(name, length, kind)| {
                Expr::Tuple(vec![
                    Expr::js_string(name),
                    self.static_function(name, *length, kind),
                ])
            })
            .collect();
        Expr::call(
            "bouy_ref_realm",
            "declare_globals",
            vec![Expr::List(vars), Expr::List(functions)],
        )
    }

    /// `'__init__'/0`: runs the top-level code as the first job of the main realm, then
    /// the realm until no work is left.
    pub fn init(&mut self, body: &[&'a Statement<'a>]) -> Function {
        let mut suspends = analyze::Suspends::default();
        for statement in body {
            suspends.visit_statement(statement);
        }
        self.frame = Frame::default();
        self.frame.sloppy = self.is_sloppy(None);
        let mut code = Vec::new();
        // The `this` of a script's top-level code is the global object; a module's is
        // undefined.
        if self.is_script() {
            let this = self.fresh("This");
            code.push(Expr::matches(
                Expr::var(this.clone()),
                Expr::Tuple(vec![Expr::atom("$o"), Expr::atom("globalThis")]),
            ));
            self.frame.this = Some(this);
            let vars = self
                .script_globals
                .iter()
                .map(|name| Expr::js_string(name))
                .collect();
            let functions = self
                .script_functions
                .clone()
                .into_iter()
                .map(|(name, length, kind)| {
                    Expr::Tuple(vec![
                        Expr::js_string(&name),
                        self.static_function(&name, length, kind),
                    ])
                })
                .collect();
            code.push(Expr::call(
                "bouy_ref_realm",
                "declare_globals",
                vec![Expr::List(vars), Expr::List(functions)],
            ));
        }
        let statements = body.to_vec();
        code.extend(if suspends.0 {
            self.async_body(|me| me.stmts(statements, &Cont::Return))
        } else {
            self.stmts(statements, &Cont::Value(Expr::undefined()))
        });
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

    /// `'__eval__'/0`: runs the code of an `eval` in the current realm and returns the value
    /// of its last statement when that is an expression statement.
    pub fn eval_function(&mut self, body: &[&'a Statement<'a>]) -> Function {
        self.frame = Frame::default();
        self.frame.sloppy = self.is_sloppy(None);
        let this = self.fresh("This");
        let mut code = vec![Expr::matches(
            Expr::var(this.clone()),
            Expr::Tuple(vec![Expr::atom("$o"), Expr::atom("globalThis")]),
        )];
        self.frame.this = Some(this);
        if !self.script_globals.is_empty() || !self.script_functions.is_empty() {
            code.push(self.declare_globals_call());
        }
        let (init, last) = match body.split_last() {
            Some((Statement::ExpressionStatement(last), init)) => (init.to_vec(), Some(last)),
            _ => (body.to_vec(), None),
        };
        match last {
            None => code.extend(self.stmts(init, &Cont::Value(Expr::undefined()))),
            Some(last) => {
                let saved = std::mem::take(&mut self.pre);
                let value = self.expr(&last.expression);
                let mut tail = std::mem::replace(&mut self.pre, saved);
                tail.push(value);
                let join = self.fresh("K");
                code.push(Expr::matches(
                    Expr::var(join.clone()),
                    Expr::Fun {
                        name: None,
                        clauses: vec![Clause {
                            patterns: vec![],
                            guards: vec![],
                            body: tail,
                        }],
                    },
                ));
                let next = Cont::Call {
                    fun: join,
                    args: vec![],
                    vars: vec![],
                    region: 0,
                };
                code.extend(self.stmts(init, &next));
            }
        }
        Function {
            name: "__eval__".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: code,
            }],
        }
    }

    /// `'$class'/1`: the class of this realm, created on first use.
    pub fn class_dispatch(&mut self) -> Function {
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
    pub fn module_variables(&mut self, variables: &'a oxc::ast::ast::VariableDeclaration<'a>) {
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
                if !matches!(self.tops.get(&symbol), Some(Top::Var(_)))
                    || self.has_getter(id.name.as_str())
                {
                    continue;
                }
                self.frame = Frame::default();
                self.pre.clear();
                let value = match simple {
                    Some(init) => self.named_expr(init, Some(Expr::js_string(id.name.as_str()))),
                    None => Expr::undefined(),
                };
                let init = std::mem::take(&mut self.pre);
                self.var_getter(id.name.as_str(), init, value);
            }
        }
        self.frame = Frame::default();
    }

    /// `'$get_x'/0` for a `var` of a block or a loop of the top-level code: undefined
    /// until its declaration runs.
    fn nested_var_getters(&mut self, program: &'a Program<'a>) {
        for symbol in top_level_vars(program) {
            let name = self.semantic.scoping().symbol_name(symbol).to_owned();
            if matches!(self.tops.get(&symbol), Some(Top::Var(_))) && !self.has_getter(&name) {
                self.var_getter(&name, Vec::new(), Expr::undefined());
            }
        }
    }

    fn has_getter(&self, name: &str) -> bool {
        let getter = format!("$get_{name}");
        self.extra.iter().any(|function| function.name == getter)
    }

    /// `'$get_x'/0`: the value of the module variable in this realm, from `init` and
    /// `value` on the first read in a realm whose top-level code did not set it.
    fn var_getter(&mut self, name: &str, mut init: Vec<Expr>, value: Expr) {
        let key = self.var_key(name);
        init.push(Expr::matches(Expr::var("V"), value));
        init.push(Expr::call(
            "erlang",
            "put",
            vec![key.clone(), Expr::tagged("v", Expr::var("V"))],
        ));
        init.push(Expr::var("V"));
        self.extra.push(Function {
            name: format!("$get_{name}"),
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

    /// A module-level function declaration: `'name'(This, Args)`.
    pub fn module_function(
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
        let itself = if self.needs_callee(function) {
            Itself::Static(self.static_function(
                name,
                length_of(&function.params),
                self.value_kind(function),
            ))
        } else {
            Itself::None
        };
        let (this, args, code) = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind_of(function.r#async, function.generator),
            Callee::Function(None),
            function.scope_id.get(),
            &itself,
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
    /// A function that is not `normal` carries its kind as a fifth element of its id.
    pub fn static_function(&self, name: &str, length: usize, kind: &str) -> Expr {
        let mut id = vec![
            Expr::atom("fn"),
            Expr::atom(self.module.clone()),
            Expr::js_string(name),
            Expr::Integer(i64::try_from(length).unwrap_or(0)),
        ];
        if kind != "normal" {
            id.push(Expr::atom(kind));
        }
        Expr::Tuple(vec![
            Expr::atom("$f"),
            Expr::Tuple(id),
            Expr::FunRef {
                module: Some(self.module.clone()),
                function: name.to_owned(),
                arity: 2,
            },
        ])
    }
}

/// The `var` names of the top-level code, outside functions.
fn top_level_vars(program: &Program<'_>) -> Vec<oxc::semantic::SymbolId> {
    let mut vars = analyze::VarDeclarations::default();
    for statement in &program.body {
        vars.visit_statement(statement);
    }
    vars.0
}
