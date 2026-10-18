//! The module level: module-level names, the functions of the module, `'$body'/0`, the
//! class dispatch `'$class'/1`, and the per-realm module variables.

use oxc::ast::ast::{
    BindingPattern, Declaration, ExportDefaultDeclarationKind, ImportDeclarationSpecifier, Program,
    Statement, VariableDeclarationKind,
};
use oxc::ast_visit::Visit;

use super::analyze;
use super::context::{Cont, Frame, Kind, Local, Lowerer, Top, capitalize, cell_get};
use super::function::{Callee, FnBody, UsesNewTarget, kind_of, length_of};
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
                if import.source.value.as_str() != "buoy" {
                    self.declare_imports(import);
                    continue;
                }
                for specifier in import.specifiers.iter().flatten() {
                    if let ImportDeclarationSpecifier::ImportSpecifier(specifier) = specifier
                        && let Some(symbol) = specifier.local.symbol_id.get()
                    {
                        self.tops
                            .insert(symbol, Top::Buoy(specifier.imported.name().to_string()));
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
                            self.declare_class_binding(symbol, id.name.as_str());
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
                        self.declare_class_binding(symbol, id.name.as_str());
                    }
                }
                Some(Declaration::VariableDeclaration(variables)) if !variables.declare => {
                    for declarator in &variables.declarations {
                        // An exported `const` is a variable, so that an import of it
                        // before its declaration throws. So is a script's `const`, a binding
                        // of the global declarative record that other code reads.
                        let literal = match (&declarator.id, &declarator.init) {
                            (BindingPattern::BindingIdentifier(id), Some(init))
                                if variables.kind == VariableDeclarationKind::Const
                                    && !self.is_script()
                                    && !self.is_exported(id.name.as_str())
                                    && id.symbol_id.get().is_some_and(|symbol| {
                                        self.read_only_after(symbol, declarator.span.end)
                                    }) =>
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
                                // A `var` of a function's name keeps the function binding.
                                if variables.kind.is_var() {
                                    self.tops.entry(symbol).or_insert(top);
                                } else {
                                    self.tops.insert(symbol, top);
                                }
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
        if self.is_script() {
            self.declare_script_globals(program);
        }
    }

    /// Whether every read of `symbol` comes after `end` and outside a function declaration,
    /// which may run first: then no read can find the binding in its dead zone.
    fn read_only_after(&self, symbol: oxc::semantic::SymbolId, end: u32) -> bool {
        let nodes = self.semantic.nodes();
        self.semantic
            .scoping()
            .get_resolved_references(symbol)
            .all(|reference| {
                let node = reference.node_id();
                oxc::span::GetSpan::span(nodes.get_node(node)).start >= end
                    && !nodes.ancestors(node).any(|ancestor| {
                        matches!(ancestor.kind(), oxc::ast::AstKind::Function(function) if function.is_declaration())
                    })
            })
    }

    /// A script's top-level `var` names and functions are properties of the global object.
    /// A function that the code never assigns keeps its Erlang function for calls.
    fn declare_script_globals(&mut self, program: &'a Program<'a>) {
        let mut function_symbols = Vec::new();
        for statement in &program.body {
            if let Statement::FunctionDeclaration(function) = statement
                && let Some(id) = &function.id
                && let Some(symbol) = id.symbol_id.get()
                && let Some(Top::Function { name, length, form }) = self.tops.get(&symbol).cloned()
            {
                self.script_functions.retain(|(other, _, _)| *other != name);
                self.script_functions.push((name.clone(), length, form));
                function_symbols.push(symbol);
            }
        }
        for symbol in top_level_vars(program) {
            let name = self.semantic.scoping().symbol_name(symbol).to_owned();
            if !function_symbols.contains(&symbol) {
                self.script_globals.push(name.clone());
            }
            self.tops.insert(symbol, Top::Global(name));
        }
        for symbol in function_symbols {
            let assigned = self
                .semantic
                .scoping()
                .get_resolved_references(symbol)
                .any(oxc::semantic::Reference::is_write);
            if assigned {
                let name = self.semantic.scoping().symbol_name(symbol).to_owned();
                self.tops.insert(symbol, Top::Global(name));
            }
        }
    }

    /// The form of the static value of a module-level function declaration.
    pub fn function_form(&self, function: &oxc::ast::ast::Function<'_>) -> &'static str {
        match (function.r#async, function.generator) {
            (true, true) => "async_generator",
            (false, true) => "generator",
            (true, false) => "async",
            (false, false) => {
                let mut uses = UsesNewTarget(false);
                uses.visit_formal_parameters(&function.params);
                if let Some(body) = &function.body {
                    uses.visit_function_body(body);
                }
                if uses.0 {
                    "fn_nt"
                } else if self.is_sloppy(function.scope_id.get()) {
                    "sloppy"
                } else {
                    "fn"
                }
            }
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
        // A script's assigned function is a global property instead
        // (`declare_script_globals`).
        let assigned = !self.is_script()
            && self
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
                form: self.function_form(function),
            }
        };
        self.tops.insert(symbol, top);
    }

    /// A top-level class: created by `'$class'/1`, or, when the code assigns to its name or
    /// it is a binding of a script, a module variable that its declaration sets.
    fn declare_class_binding(&mut self, symbol: oxc::semantic::SymbolId, name: &str) {
        let assigned = self
            .semantic
            .scoping()
            .get_resolved_references(symbol)
            .any(oxc::semantic::Reference::is_write);
        if assigned || self.is_script() {
            self.tops.insert(symbol, Top::Var(name.to_owned()));
            let lazy = Expr::local_call("$class", vec![Expr::binary(name.to_owned())]);
            self.var_getter(name, Vec::new(), lazy, Absent::Uninitialized);
        } else {
            self.tops.insert(symbol, Top::Class(name.to_owned()));
        }
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
    pub fn module_functions(&mut self, program: &'a Program<'a>, source: &str) -> Vec<Function> {
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
                        functions.extend(self.module_function(name, function));
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
                            functions.extend(self.module_function(id.name.as_str(), function));
                        }
                    }
                    Some(Declaration::ClassDeclaration(class)) => {
                        if let Some(id) = &class.id
                            && !class.declare
                        {
                            self.module_class(id.name.as_str(), class);
                            // The class is made where the top-level code declares it, so its
                            // static elements run in order.
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
        // A later declaration of a function name replaces an earlier one.
        let mut seen = std::collections::HashSet::new();
        functions.reverse();
        functions.retain(|function: &Function| {
            seen.insert((
                function.name.clone(),
                function.clauses.first().map(|c| c.patterns.len()),
            ))
        });
        functions.reverse();
        self.nested_var_getters(program);
        // A directive is an expression statement too: a script of `'1'` completes with "1".
        let directive = program
            .directives
            .last()
            .map(|directive| Expr::js_string(directive.expression.value.as_str()));
        functions.push(self.body_function(&body, directive));
        functions.push(self.class_dispatch());
        functions.extend(source_functions(program, source));
        functions.push(self.export_function(program));
        functions.extend(self.linking.interface());
        functions.append(&mut self.extra);
        functions
    }

    /// Every Erlang function of the module of eval code: `'__eval__'/3` holds the whole
    /// program, whose declarations are locals of the eval, or bindings of the caller's
    /// variables for the `var` names and functions of sloppy code.
    pub fn eval_module_functions(
        &mut self,
        program: &'a Program<'a>,
        source: &str,
    ) -> Vec<Function> {
        // A directive is an expression statement too: `eval("'1'")` is "1".
        // compile_eval writes the directive of strict eval code before the code.
        let injected = usize::from(self.eval == Some(true));
        let directive = program
            .directives
            .iter()
            .skip(injected)
            .last()
            .map(|directive| Expr::js_string(directive.expression.value.as_str()));
        let body: Vec<&'a Statement<'a>> = program.body.iter().collect();
        let mut functions = vec![self.eval_function(&body, directive)];
        functions.push(self.class_dispatch());
        functions.extend(source_functions(program, source));
        functions.push(self.export_function(program));
        functions.extend(self.linking.interface());
        functions.append(&mut self.extra);
        functions
    }

    /// The call that declares a script's top-level names before its code runs
    /// (`GlobalDeclarationInstantiation`): its `let`, `const`, and classes in the global
    /// declarative record, and its `var` names and functions as properties of the global
    /// object.
    fn declare_script_call(&self, body: &[&'a Statement<'a>]) -> Expr {
        let lexical =
            |name: &str, kind: &str| Expr::Tuple(vec![Expr::js_string(name), Expr::atom(kind)]);
        let lexicals = body
            .iter()
            .flat_map(|statement| match statement {
                Statement::VariableDeclaration(variables) if variables.kind.is_lexical() => {
                    let kind = if variables.kind == VariableDeclarationKind::Const {
                        "immutable"
                    } else {
                        "mutable"
                    };
                    variables
                        .declarations
                        .iter()
                        .flat_map(|declarator| declarator.id.get_binding_identifiers())
                        .map(|id| lexical(id.name.as_str(), kind))
                        .collect()
                }
                Statement::ClassDeclaration(class) => class
                    .id
                    .iter()
                    .map(|id| lexical(id.name.as_str(), "mutable"))
                    .collect(),
                _ => Vec::new(),
            })
            .collect();
        let vars = self
            .script_globals
            .iter()
            .map(|name| Expr::js_string(name))
            .collect();
        let functions = self
            .script_functions
            .iter()
            .map(|(name, length, form)| {
                Expr::Tuple(vec![
                    Expr::js_string(name),
                    self.static_function(name, *length, form),
                ])
            })
            .collect();
        Expr::call(
            "buoy_ref_realm",
            "declare_script",
            vec![
                Expr::atom(self.module.clone()),
                Expr::List(lexicals),
                Expr::List(vars),
                Expr::List(functions),
            ],
        )
    }

    /// `'$body'/0`: the top-level code. A module whose top-level code awaits returns the
    /// promise of its completion.
    pub fn body_function(
        &mut self,
        body: &[&'a Statement<'a>],
        directive: Option<Expr>,
    ) -> Function {
        let mut suspends = analyze::Suspends::default();
        for statement in body {
            suspends.visit_statement(statement);
        }
        self.frame = Frame::default();
        self.frame.sloppy = self.is_sloppy(None);
        let mut code = Vec::new();
        // The `this` of a script's top-level code is the global object of its realm; a
        // module's is undefined.
        if self.is_script() {
            let this = self.fresh("This");
            code.push(Expr::matches(
                Expr::var(this.clone()),
                Expr::call("buoy_ref_realm", "global_object", vec![]),
            ));
            self.frame.this = Some(this);
            code.push(self.declare_script_call(body));
        }
        // A script that is not the entry of a program is one that a host's evalScript
        // runs (`buoy_ref_eval:script/1`): it returns its completion value, as eval does.
        if self.is_script() && !self.linking.entry {
            let completion = self.fresh("Completion");
            code.push(Expr::matches(
                Expr::var(completion.clone()),
                Expr::call(
                    "buoy_heap",
                    "cell",
                    vec![directive.unwrap_or_else(Expr::undefined)],
                ),
            ));
            self.frame.completion = Some(completion.clone());
        }
        let statements = body.to_vec();
        let value = match &self.frame.completion {
            Some(completion) => cell_get(completion),
            None => Expr::undefined(),
        };
        code.extend(if suspends.0 {
            self.async_body(|me| me.stmts(statements, &Cont::Return))
        } else {
            self.stmts(statements, &Cont::Value(value))
        });
        let mut body = self.dead_zone();
        body.extend(code);
        Function {
            name: "$body".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body,
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
        // A class whose name the code assigns is a module variable.
        let variable = class
            .id
            .as_ref()
            .and_then(|id| id.symbol_id.get())
            .is_some_and(|symbol| matches!(self.tops.get(&symbol), Some(Top::Var(_))));
        if variable {
            let created = self.bind(Expr::local_call(
                "$class",
                vec![Expr::binary(name.to_owned())],
            ));
            self.pre.push(Expr::call(
                "erlang",
                "put",
                vec![self.var_key(name), Expr::tagged("v", created)],
            ));
        }
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
                "buoy_heap",
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

    /// The `let` and `const` of the module, or of eval code, are in their dead zone until
    /// the top-level code declares them.
    fn dead_zone(&self) -> Vec<Expr> {
        self.tops
            .iter()
            .filter(|(symbol, top)| {
                matches!(top, Top::Var(_))
                    && self
                        .semantic
                        .scoping()
                        .symbol_flags(**symbol)
                        .is_block_scoped()
            })
            .filter_map(|(_, top)| match top {
                Top::Var(name) => Some(name.clone()),
                _ => None,
            })
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .map(|name| {
                Expr::call(
                    "erlang",
                    "put",
                    vec![self.var_key(&name), Expr::atom("$tdz")],
                )
            })
            .collect()
    }

    /// `'__eval__'/3`: runs the code of an `eval` in the current realm with its `this` and
    /// returns its completion value. Each expression statement of the eval code stores its
    /// value in the completion cell, and the statements whose completion ECMA-262 updates
    /// from empty to undefined reset it (`completion_reset`).
    pub fn eval_function(
        &mut self,
        body: &[&'a Statement<'a>],
        directive: Option<Expr>,
    ) -> Function {
        self.frame = Frame::default();
        self.frame.sloppy = self.is_sloppy(None);
        // The `this` of the eval: the caller's for a direct eval, else the global object.
        // The scope holds the cells of the caller's bindings, in the order of
        // `eval_bindings`.
        let this = self.fresh("This");
        let mut code = Vec::new();
        self.frame.this = Some(this.clone());
        let cells = self
            .eval_bindings
            .iter()
            .map(|(_, cell)| Expr::Tuple(vec![Expr::var("_"), Expr::var(cell.clone())]))
            .collect();
        code.push(Expr::matches(Expr::List(cells), Expr::var("Scope")));
        code.extend(self.eval_context_frame());
        code.extend(self.eval_declarations(body));
        let completion = self.fresh("Completion");
        code.push(Expr::matches(
            Expr::var(completion.clone()),
            Expr::call(
                "buoy_heap",
                "cell",
                vec![directive.unwrap_or_else(Expr::undefined)],
            ),
        ));
        self.frame.completion = Some(completion.clone());
        code.extend(self.stmts(body.to_vec(), &Cont::Value(cell_get(&completion))));
        Function {
            name: "__eval__".to_owned(),
            clauses: vec![Clause {
                patterns: vec![Expr::var(this), Expr::var("Scope"), Expr::var("Context")],
                guards: vec![],
                body: code,
            }],
        }
    }

    /// Reads what the context of a direct eval gives its code from the map `Context`: the
    /// home object, `new.target`, the `this` cell of a derived constructor with its class
    /// and field initializer, and the private names.
    fn eval_context_frame(&mut self) -> Vec<Expr> {
        let context = self.eval_context.clone();
        let mut code = Vec::new();
        let mut take = |me: &mut Self, key: &str| {
            let var = me.fresh(&capitalize(key));
            code.push(Expr::matches(
                Expr::var(var.clone()),
                Expr::call("maps", "get", vec![Expr::atom(key), Expr::var("Context")]),
            ));
            var
        };
        let place = context.place;
        self.frame.in_function = place.has_new_target();
        self.frame.in_field = place == super::EvalPlace::Field;
        if place.has_new_target() {
            self.frame.new_target = Some(take(self, "new_target"));
        }
        let constructor = place == super::EvalPlace::Constructor;
        if constructor {
            self.frame.this_cell = Some(take(self, "this_cell"));
        }
        if place.has_home() {
            let home = take(self, "home");
            let (class, init) = if constructor {
                (Some(take(self, "class")), Some(take(self, "init")))
            } else {
                (None, None)
            };
            self.frame.class = Some(super::context::ClassFrame { home, class, init });
        }
        if !context.privates.is_empty() {
            let keys = take(self, "privates");
            let names = context
                .privates
                .iter()
                .enumerate()
                .map(|(index, name)| {
                    let position = Expr::Integer(i64::try_from(index + 1).unwrap_or(0));
                    let key =
                        Expr::call("erlang", "element", vec![position, Expr::var(keys.clone())]);
                    (name.clone(), key)
                })
                .collect();
            self.privates.push(names);
        }
        code
    }

    /// `EvalDeclarationInstantiation` (ECMA-262 §19.2.1.3): the `var` names and the top-level
    /// functions of the code. Strict code keeps them as locals. In sloppy code, a name
    /// that the caller's function binds is that binding, and every other name is a
    /// binding of the caller's variables: the object of the first `@vars` entry of the
    /// scope, or the global object.
    fn eval_declarations(&mut self, body: &[&'a Statement<'a>]) -> Vec<Expr> {
        let mut vars = analyze::VarDeclarations::default();
        for statement in body {
            vars.visit_statement(statement);
        }
        let functions: Vec<&'a oxc::ast::ast::Function<'a>> = body
            .iter()
            .filter_map(|statement| match statement {
                Statement::FunctionDeclaration(function) if function.body.is_some() => {
                    Some(&**function)
                }
                _ => None,
            })
            .collect();
        let saved = std::mem::take(&mut self.pre);
        if !self.frame.sloppy {
            for symbol in vars.0 {
                if !self.frame.env.contains_key(&symbol) {
                    self.declare_symbol(symbol, Expr::undefined());
                }
            }
            return std::mem::replace(&mut self.pre, saved);
        }
        // The caller's own bindings come before the object of its variables.
        let own: Vec<(String, String)> = self
            .eval_bindings
            .iter()
            .take_while(|(name, _)| name != "@vars")
            .cloned()
            .collect();
        let target = self
            .eval_bindings
            .iter()
            .find(|(name, _)| name == "@vars")
            .map(|(_, object)| object.clone());
        let declare = |me: &mut Self, symbol: oxc::semantic::SymbolId| -> Option<String> {
            let name = me.semantic.scoping().symbol_name(symbol).to_owned();
            if let Some((_, cell)) = own.iter().find(|(binding, _)| *binding == name) {
                me.frame.env.insert(symbol, Local::Cell(cell.clone()));
                return None;
            }
            me.tops.insert(symbol, Top::Global(name.clone()));
            Some(name)
        };
        // The functions exist before the code runs, so the bindings that they read early
        // get their cells first.
        let early = self.early_bindings(body);
        self.pre.extend(early);
        let mut values = Vec::new();
        for function in functions {
            let Some(symbol) = function.id.as_ref().and_then(|id| id.symbol_id.get()) else {
                continue;
            };
            if let Some(name) = declare(self, symbol) {
                let value = self.function_value(function, None);
                values.push(Expr::Tuple(vec![Expr::js_string(&name), value]));
            }
        }
        let mut names = Vec::new();
        for symbol in vars.0 {
            if !self.tops.contains_key(&symbol)
                && !self.frame.env.contains_key(&symbol)
                && let Some(name) = declare(self, symbol)
            {
                names.push(Expr::js_string(&name));
            }
        }
        let call = match target {
            Some(object) => Expr::call(
                "buoy_ref_eval",
                "declare_vars",
                vec![Expr::var(object), Expr::List(names), Expr::List(values)],
            ),
            None => Expr::call(
                "buoy_ref_realm",
                "declare_globals",
                vec![Expr::List(names), Expr::List(values), Expr::atom("true")],
            ),
        };
        self.pre.push(call);
        std::mem::replace(&mut self.pre, saved)
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
        // A read during the initializer, or before the declaration in the main realm,
        // finds the marker: the temporal dead zone, and no endless recursion.
        init.insert(
            0,
            Expr::call("erlang", "put", vec![key.clone(), Expr::atom("$tdz")]),
        );
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
            Absent::Undefined => Expr::call("buoy_module", "hoisted", vec![lazy]),
            Absent::Uninitialized => Expr::call(
                "buoy_module",
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
                        Clause::new(
                            Expr::atom("$tdz"),
                            vec![Expr::call(
                                "buoy_ref_class",
                                "initialized",
                                vec![Expr::atom("$uninitialized"), Expr::js_string(name)],
                            )],
                        ),
                        Clause::new(Expr::undefined(), vec![absent]),
                    ],
                )],
            }],
        });
    }

    /// A module-level function declaration: `'name'(This, Args)`, and `'name'/3`, which
    /// takes new.target, for a function that reads it. A function whose name the code
    /// assigns also gets `'$get_name'/0`, which reads the function until then.
    pub fn module_function(
        &mut self,
        name: &str,
        function: &'a oxc::ast::ast::Function<'a>,
    ) -> Vec<Function> {
        let assigned = function
            .id
            .as_ref()
            .and_then(|id| id.symbol_id.get())
            .is_some_and(|symbol| matches!(self.tops.get(&symbol), Some(Top::Var(_))));
        if assigned {
            let value = self.static_function(
                name,
                length_of(&function.params),
                self.function_form(function),
            );
            self.var_getter(name, Vec::new(), value.clone(), Absent::Value(value));
        }
        self.frame = Frame::default();
        let Some(body) = &function.body else {
            return vec![];
        };
        let length = length_of(&function.params);
        let form = self.function_form(function);
        let kind = kind_of(function.r#async, function.generator);
        let own = matches!(kind, Kind::Generator | Kind::AsyncGenerator)
            .then(|| self.static_function(name, length, form));
        let itself = self
            .needs_callee(function)
            .then(|| self.static_function(name, length, form));
        let code = self.function_code(
            &function.params,
            FnBody::Block(body),
            kind,
            Callee::Function(itself),
            own,
            function.scope_id.get(),
        );
        let Some(new_target) = code.new_target else {
            return vec![Function {
                name: name.to_owned(),
                clauses: vec![Clause {
                    patterns: vec![Expr::var(code.this), Expr::var(code.args)],
                    guards: vec![],
                    body: code.body,
                }],
            }];
        };
        vec![
            Function {
                name: name.to_owned(),
                clauses: vec![Clause {
                    patterns: vec![Expr::var("This"), Expr::var("Args")],
                    guards: vec![],
                    body: vec![Expr::local_call(
                        name,
                        vec![Expr::var("This"), Expr::var("Args"), Expr::undefined()],
                    )],
                }],
            },
            Function {
                name: name.to_owned(),
                clauses: vec![Clause {
                    patterns: vec![
                        Expr::var(code.this),
                        Expr::var(code.args),
                        Expr::var(new_target),
                    ],
                    guards: vec![],
                    body: code.body,
                }],
            },
        ]
    }

    /// The value of a module-level function used as a value: the same term in every realm.
    /// A normal function of sloppy code carries `sloppy` as a fifth element of its id.
    pub fn static_function(&self, name: &str, length: usize, form: &str) -> Expr {
        let mut id = vec![
            Expr::atom(if form == "sloppy" { "fn" } else { form }),
            Expr::atom(self.module.clone()),
            Expr::js_string(if name == "*default*" { "default" } else { name }),
            Expr::Integer(i64::try_from(length).unwrap_or(0)),
        ];
        if form == "sloppy" {
            id.push(Expr::atom("sloppy"));
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

/// `'$source'/0`, the source text of the module, and `'$span'/1`, where the text of
/// each module-level function is in it, for Function.prototype.toString.
pub(super) fn source_functions(program: &Program<'_>, source: &str) -> Vec<Function> {
    let mut spans: Vec<Clause> = program
        .body
        .iter()
        .filter_map(|statement| match declaration(statement) {
            Some(Declaration::FunctionDeclaration(function)) => function.id.as_ref().map(|id| {
                Clause::new(
                    Expr::js_string(id.name.as_str()),
                    vec![Expr::Tuple(vec![
                        Expr::Integer(i64::from(function.span.start)),
                        Expr::Integer(i64::from(function.span.end)),
                    ])],
                )
            }),
            _ => None,
        })
        .collect();
    spans.push(Clause::new(Expr::var("_"), vec![Expr::atom("none")]));
    vec![
        Function {
            name: "$source".to_owned(),
            clauses: vec![Clause {
                patterns: vec![],
                guards: vec![],
                body: vec![Expr::binary(source.to_owned())],
            }],
        },
        Function {
            name: "$span".to_owned(),
            clauses: spans,
        },
    ]
}
