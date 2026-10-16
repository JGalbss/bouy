use std::collections::HashMap;

use oxc::allocator::{Allocator, CloneIn, Vec as ArenaVec};
use oxc::ast::ast::{
    ArrowFunctionExpression, Declaration, DoWhileStatement, ExportDefaultDeclarationKind,
    ForInStatement, ForOfStatement, ForStatement, Function, Program, Statement, StaticBlock,
    WhileStatement,
};
use oxc::ast::builder::AstBuilder;
use oxc::ast_visit::{VisitMut, walk_mut};
use oxc::parser::Parser;
use oxc::span::{SPAN, SourceType};
use oxc::syntax::scope::ScopeFlags;

use crate::INTRINSICS_MODULE;

const PREEMPTION_POINT: &str = "if (__bouy.tick()) await __bouy.pause();";

pub struct Lowering {
    pub preemption_points: usize,
    pub located_classes: Vec<String>,
}

pub fn lower<'a>(allocator: &'a Allocator, program: &mut Program<'a>) -> Lowering {
    let mut points = PreemptionPoints {
        allocator,
        point: statement(allocator, PREEMPTION_POINT),
        async_scopes: vec![false],
        inserted: 0,
    };
    points.visit_program(program);
    let located_classes = locate_exported_classes(allocator, program);
    if points.inserted > 0 || !located_classes.is_empty() {
        let import = format!("import * as __bouy from {INTRINSICS_MODULE:?};");
        program
            .body
            .insert(0, statement(allocator, allocator.alloc_str(&import)));
    }
    Lowering {
        preemption_points: points.inserted,
        located_classes,
    }
}

fn statement<'a>(allocator: &'a Allocator, source: &'a str) -> Statement<'a> {
    Parser::new(allocator, source, SourceType::mjs())
        .parse()
        .program
        .body
        .into_iter()
        .next()
        .unwrap_or_else(|| unreachable!("the snippet `{source}` holds one statement"))
}

struct PreemptionPoints<'a> {
    allocator: &'a Allocator,
    point: Statement<'a>,
    async_scopes: Vec<bool>,
    inserted: usize,
}

impl<'a> PreemptionPoints<'a> {
    fn guard(&mut self, body: &mut Statement<'a>) {
        if !self.async_scopes.last().copied().unwrap_or(false) {
            return;
        }
        self.inserted += 1;
        let point = self.point.clone_in(self.allocator);
        if let Statement::BlockStatement(block) = body {
            block.body.insert(0, point);
            return;
        }
        let ast = AstBuilder::new(self.allocator);
        let original = std::mem::replace(body, Statement::new_empty_statement(SPAN, &ast));
        let block = ArenaVec::from_array_in([point, original], &self.allocator);
        *body = Statement::new_block_statement(SPAN, block, &ast);
    }
}

impl<'a> VisitMut<'a> for PreemptionPoints<'a> {
    fn visit_function(&mut self, function: &mut Function<'a>, flags: ScopeFlags) {
        self.async_scopes.push(function.r#async);
        walk_mut::walk_function(self, function, flags);
        self.async_scopes.pop();
    }

    fn visit_arrow_function_expression(&mut self, arrow: &mut ArrowFunctionExpression<'a>) {
        self.async_scopes.push(arrow.r#async);
        walk_mut::walk_arrow_function_expression(self, arrow);
        self.async_scopes.pop();
    }

    fn visit_static_block(&mut self, block: &mut StaticBlock<'a>) {
        self.async_scopes.push(false);
        walk_mut::walk_static_block(self, block);
        self.async_scopes.pop();
    }

    fn visit_for_statement(&mut self, loop_statement: &mut ForStatement<'a>) {
        walk_mut::walk_for_statement(self, loop_statement);
        self.guard(&mut loop_statement.body);
    }

    fn visit_for_in_statement(&mut self, loop_statement: &mut ForInStatement<'a>) {
        walk_mut::walk_for_in_statement(self, loop_statement);
        self.guard(&mut loop_statement.body);
    }

    fn visit_for_of_statement(&mut self, loop_statement: &mut ForOfStatement<'a>) {
        walk_mut::walk_for_of_statement(self, loop_statement);
        self.guard(&mut loop_statement.body);
    }

    fn visit_while_statement(&mut self, loop_statement: &mut WhileStatement<'a>) {
        walk_mut::walk_while_statement(self, loop_statement);
        self.guard(&mut loop_statement.body);
    }

    fn visit_do_while_statement(&mut self, loop_statement: &mut DoWhileStatement<'a>) {
        walk_mut::walk_do_while_statement(self, loop_statement);
        self.guard(&mut loop_statement.body);
    }
}

fn locate_exported_classes<'a>(allocator: &'a Allocator, program: &mut Program<'a>) -> Vec<String> {
    let exported = exported_names(&program.body);
    let mut located = Vec::new();
    let mut body = ArenaVec::with_capacity_in(program.body.len() + exported.len(), &allocator);
    for item in program.body.drain(..) {
        let class = declared_class(&item);
        body.push(item);
        let Some((local, export)) = class.and_then(|local| exported.get(local).map(|e| (local, e)))
        else {
            continue;
        };
        let call = format!("__bouy.locate({local}, import.meta.url, {export:?});");
        body.push(statement(allocator, allocator.alloc_str(&call)));
        located.push(local.to_string());
    }
    program.body = body;
    located
}

fn declared_class<'a>(item: &Statement<'a>) -> Option<&'a str> {
    match item {
        Statement::ClassDeclaration(class) => class.id.as_ref().map(|id| id.name.as_str()),
        Statement::ExportDeclaration(export) => match &export.declaration {
            Declaration::ClassDeclaration(class) => class.id.as_ref().map(|id| id.name.as_str()),
            _ => None,
        },
        Statement::ExportDefaultDeclaration(export) => match &export.declaration {
            ExportDefaultDeclarationKind::ClassDeclaration(class) => {
                class.id.as_ref().map(|id| id.name.as_str())
            }
            _ => None,
        },
        _ => None,
    }
}

fn exported_names<'a>(body: &[Statement<'a>]) -> HashMap<&'a str, String> {
    let mut names = HashMap::new();
    for item in body {
        match item {
            Statement::ExportDeclaration(_) => {
                if let Some(local) = declared_class(item) {
                    names.insert(local, local.to_string());
                }
            }
            Statement::ExportNamedDeclaration(export) => {
                for specifier in &export.specifiers {
                    names.insert(
                        specifier.local.name().as_str(),
                        specifier.exported.to_string(),
                    );
                }
            }
            Statement::ExportDefaultDeclaration(_) => {
                if let Some(local) = declared_class(item) {
                    names.insert(local, "default".to_string());
                }
            }
            _ => {}
        }
    }
    names
}
