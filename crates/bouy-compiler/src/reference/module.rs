//! The module level: module-level names, the functions of the module, `'$body'/0`, the
//! class dispatch `'$class'/1`, and the per-realm module variables.

use oxc::ast::ast::{
    BindingPattern, Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier, Program,
    Statement, VariableDeclarationKind,
};
use oxc::ast_visit::Visit;

use super::analyze;
use super::context::{Cont, Frame, Lowerer, Top};
use super::function::{Callee, FnBody, kind_of, length_of};
use super::literal::literal;
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
                    self.declare_imports(import);
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
                            self.declare_function(symbol, id.name.as_str(), function);
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
                        self.declare_function(symbol, id.name.as_str(), function);
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
                        // An exported `const` is a variable, so that an import of it
                        // before its declaration throws.
                        let literal = match (&declarator.id, &declarator.init) {
                            (BindingPattern::BindingIdentifier(id), Some(init))
                                if variables.kind == VariableDeclarationKind::Const
                                    && !self.is_exported(id.name.as_str()) =>
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
    }

    /// A module-level function declaration: the Erlang function `'name'/2`, or, when the
    /// code assigns to its name, a module variable that holds the function until then.
    fn declare_function(
        &mut self,
        symbol: oxc::semantic::SymbolId,
        name: &str,
        function: &'a oxc::ast::ast::Function<'a>,
    ) {
        let assigned = self
            .semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(oxc::semantic::Reference::is_write);
        let top = if assigned {
            Top::Var(name.to_owned())
        } else {
            Top::Function {
                name: name.to_owned(),
                length: length_of(&function.params),
            }
        };
        self.tops.insert(symbol, top);
    }

    /// The import bindings of a declaration, as linking resolved them.
    /// An import that did not link reads as undefined: the module throws its link
    /// error before its code runs.
    fn declare_imports(&mut self, import: &oxc::ast::ast::ImportDeclaration<'a>) {
        for specifier in import.specifiers.iter().flatten() {
            let local = specifier.local();
            let Some(symbol) = local.symbol_id.get() else {
                continue;
            };
            let top = match self.linking.link.imports.get(local.name.as_str()) {
                Some(binding) => Top::Import(binding.clone()),
                None => Top::Literal(Expr::undefined()),
            };
            self.tops.insert(symbol, top);
        }
    }

    /// Every Erlang function of the module.
    pub fn module_functions(&mut self, program: &'a Program<'a>) -> Vec<Function> {
        let mut functions = Vec::new();
        let mut body: Vec<&'a Statement<'a>> = Vec::new();
        for statement in &program.body {
            match statement {
                Statement::ImportDeclaration(_)
                | Statement::ExportFromDeclaration(_)
                | Statement::ExportAllDeclaration(_) => {}
                Statement::ExportDefaultDeclaration(export) => match &export.declaration {
                    ExportDefaultDeclarationKind::FunctionDeclaration(function) => {
                        let name = function
                            .id
                            .as_ref()
                            .map_or("*default*", |id| id.name.as_str());
                        functions.push(self.module_function(name, function));
                    }
                    ExportDefaultDeclarationKind::ClassDeclaration(class) => {
                        let name = class.id.as_ref().map_or("default", |id| id.name.as_str());
                        self.module_class(name, class);
                        body.push(statement);
                    }
                    ExportDefaultDeclarationKind::TSInterfaceDeclaration(_) => {}
                    other => {
                        if let Some(expression) = other.as_expression() {
                            self.default_getter(expression);
                        }
                        body.push(statement);
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
                            body.push(statement);
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
        functions.push(self.body_function(&body));
        functions.push(self.class_dispatch());
        functions.push(self.export_function(program));
        functions.extend(self.linking.interface());
        functions.append(&mut self.extra);
        functions
    }

    /// `'$body'/0`: the top-level code. A module whose top-level code awaits returns the
    /// promise of its completion.
    pub fn body_function(&mut self, body: &[&'a Statement<'a>]) -> Function {
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
        Function {
            name: "$body".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: code,
            }],
        }
    }

    /// Whether the module exports the local binding `name`.
    pub fn is_exported(&self, name: &str) -> bool {
        self.linking
            .link
            .exported_locals
            .iter()
            .any(|local| local == name)
    }

    /// The code of a top-level class declaration: it creates the class in this realm, so
    /// that its static members run in order and an import of it is initialized.
    ///
    /// A superclass expression that awaits runs here, in the top-level code, and the
    /// class reads its value from `{'$heritage', Module, Name}`.
    pub fn declare_class(&mut self, name: &str, class: &'a oxc::ast::ast::Class<'a>) {
        if let Some(heritage) = class.heritage.as_ref().filter(|_| heritage_suspends(class)) {
            let value = self.expr(&heritage.expression);
            let value = self.bind(value);
            self.pre.push(Expr::call(
                "erlang",
                "put",
                vec![self.heritage_key(name), value],
            ));
        }
        self.pre.push(Expr::local_call(
            "$class",
            vec![Expr::binary(name.to_owned())],
        ));
    }

    /// Where the top-level code leaves the superclass of the class `name`.
    pub fn heritage_key(&self, name: &str) -> Expr {
        Expr::Tuple(vec![
            Expr::atom("$heritage"),
            Expr::atom(self.module.clone()),
            Expr::binary(name.to_owned()),
        ])
    }

    /// `export default <expression>`: the variable `*default*`.
    /// An anonymous function takes the name `default`, as `NamedEvaluation` gives it.
    pub fn export_default(&mut self, expression: &'a oxc::ast::ast::Expression<'a>) {
        use oxc::ast::ast::Expression as E;
        let value = self.expr(expression);
        let value = self.bind(value);
        let anonymous = match expression.without_parentheses() {
            E::FunctionExpression(function) => function.id.is_none(),
            E::ArrowFunctionExpression(_) => true,
            E::ClassExpression(class) => class.id.is_none(),
            _ => false,
        };
        if anonymous {
            self.pre.push(Expr::call(
                "bouy_heap",
                "define",
                vec![
                    value.clone(),
                    Expr::binary("name"),
                    Expr::Map(vec![
                        (Expr::atom("value"), Expr::binary("default")),
                        (Expr::atom("writable"), Expr::atom("false")),
                        (Expr::atom("enumerable"), Expr::atom("false")),
                        (Expr::atom("configurable"), Expr::atom("true")),
                    ]),
                ],
            ));
        }
        let key = self.var_key("*default*");
        self.pre.push(Expr::call(
            "erlang",
            "put",
            vec![key, Expr::tagged("v", value)],
        ));
    }

    /// `'$get_*default*'/0`, which an actor realm initializes on first read.
    fn default_getter(&mut self, expression: &'a oxc::ast::ast::Expression<'a>) {
        let mut suspends = analyze::Suspends::default();
        suspends.visit_expression(expression);
        self.frame = Frame::default();
        self.pre.clear();
        let value = if suspends.0 {
            Expr::undefined()
        } else {
            self.expr(expression)
        };
        let init = std::mem::take(&mut self.pre);
        self.var_getter("*default*", init, value, Absent::Uninitialized);
        self.frame = Frame::default();
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
                    Some(init) => self.expr(init),
                    None => Expr::undefined(),
                };
                let init = std::mem::take(&mut self.pre);
                let absent = if variables.kind == VariableDeclarationKind::Var {
                    Absent::Undefined
                } else {
                    Absent::Uninitialized
                };
                self.var_getter(id.name.as_str(), init, value, absent);
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
                self.var_getter(&name, Vec::new(), Expr::undefined(), Absent::Undefined);
            }
        }
    }

    fn has_getter(&self, name: &str) -> bool {
        let getter = format!("$get_{name}");
        self.extra.iter().any(|function| function.name == getter)
    }

    /// `'$get_x'/0`: the value of the module variable in this realm. Before its
    /// declaration runs, a `let` or `const` throws a `ReferenceError` and a `var` (when
    /// `hoisted`) reads as undefined. An actor realm, whose top-level code does not run,
    /// sets the variable from `init` and `value` on its first read.
    fn var_getter(&mut self, name: &str, mut init: Vec<Expr>, value: Expr, absent: Absent) {
        let key = self.var_key(name);
        init.push(Expr::matches(Expr::var("V"), value));
        init.push(Expr::call(
            "erlang",
            "put",
            vec![key.clone(), Expr::tagged("v", Expr::var("V"))],
        ));
        init.push(Expr::var("V"));
        let lazy = Expr::Fun {
            name: None,
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: init,
            }],
        };
        let absent = match absent {
            Absent::Undefined => Expr::call("bouy_module", "hoisted", vec![lazy]),
            Absent::Uninitialized => Expr::call(
                "bouy_module",
                "uninitialized",
                vec![Expr::js_string(name), lazy],
            ),
            Absent::Value(value) => value,
        };
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
                        Clause::new(Expr::undefined(), vec![absent]),
                    ],
                )],
            }],
        });
    }

    /// A module-level function declaration: `'name'(This, Args)`. A function whose name
    /// the code assigns also gets `'$get_name'/0`, which reads the function until then.
    pub fn module_function(
        &mut self,
        name: &str,
        function: &'a oxc::ast::ast::Function<'a>,
    ) -> Function {
        let assigned = function
            .id
            .as_ref()
            .and_then(|id| id.symbol_id.get())
            .is_some_and(|symbol| matches!(self.tops.get(&symbol), Some(Top::Var(_))));
        if assigned {
            let value = self.static_function(name, length_of(&function.params));
            self.var_getter(name, Vec::new(), value.clone(), Absent::Value(value));
        }
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
    pub fn static_function(&self, name: &str, length: usize) -> Expr {
        Expr::Tuple(vec![
            Expr::atom("$f"),
            Expr::Tuple(vec![
                Expr::atom("fn"),
                Expr::atom(self.module.clone()),
                Expr::js_string(if name == "*default*" { "default" } else { name }),
                Expr::Integer(i64::try_from(length).unwrap_or(0)),
            ]),
            Expr::FunRef {
                module: Some(self.module.clone()),
                function: name.to_owned(),
                arity: 2,
            },
        ])
    }
}

/// Whether the superclass expression of a top-level class awaits.
pub fn heritage_suspends(class: &oxc::ast::ast::Class<'_>) -> bool {
    class.heritage.as_ref().is_some_and(|heritage| {
        let mut suspends = analyze::Suspends::default();
        suspends.visit_expression(&heritage.expression);
        suspends.0
    })
}

/// What a module variable reads before its declaration runs.
enum Absent {
    /// A `let`, `const`, or `*default*`: a `ReferenceError`.
    Uninitialized,
    /// A `var`.
    Undefined,
    /// A function declaration whose name the code assigns: the function.
    Value(Expr),
}

/// The `var` names of the top-level code, outside functions.
fn top_level_vars(program: &Program<'_>) -> Vec<oxc::semantic::SymbolId> {
    let mut vars = analyze::VarDeclarations::default();
    for statement in &program.body {
        vars.visit_statement(statement);
    }
    vars.0
}
