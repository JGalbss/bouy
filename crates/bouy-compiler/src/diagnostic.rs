//! Compile diagnostics: a code from section 10 of the contract, a position, and a message.

use std::fmt;
use std::path::{Path, PathBuf};

use oxc::span::Span;

/// The rule a diagnostic reports, with its `BOUY` code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Code {
    /// A syntax or semantic error that oxc reports.
    Syntax,
    /// An import of a module that is neither relative nor a library.
    BadImport,
    /// A module-level `let`/`var`, or a module-level value that changes after initialization.
    ModuleState,
    /// `new` on an actor class.
    NewActor,
    /// A closure that rebinds, or reads a later rebinding of, an enclosing variable.
    Capture,
    /// Syntax with no BEAM lowering.
    Unsupported,
    /// A host API that Bouy does not provide.
    HostApi,
}

impl Code {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Syntax => "BOUY200",
            Self::BadImport => "BOUY201",
            Self::ModuleState => "BOUY202",
            Self::NewActor => "BOUY203",
            Self::Capture => "BOUY205",
            Self::Unsupported => "BOUY206",
            Self::HostApi => "BOUY207",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub path: PathBuf,
    pub line: usize,
    pub column: usize,
    pub code: Code,
    pub message: String,
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}: {}: {}",
            self.path.display(),
            self.line,
            self.column,
            self.code.as_str(),
            self.message
        )
    }
}

/// Builds positioned diagnostics for one source file.
#[derive(Debug)]
pub struct Reporter<'s> {
    path: &'s Path,
    source: &'s str,
    pub diagnostics: Vec<Diagnostic>,
}

impl<'s> Reporter<'s> {
    pub fn new(path: &'s Path, source: &'s str) -> Self {
        Self {
            path,
            source,
            diagnostics: Vec::new(),
        }
    }

    pub fn report(&mut self, span: Span, code: Code, message: impl Into<String>) {
        let diagnostic = self.at(span.start as usize, code, message.into());
        if !self.diagnostics.contains(&diagnostic) {
            self.diagnostics.push(diagnostic);
        }
    }

    /// The source text of `span`.
    pub fn text(&self, span: Span) -> &'s str {
        self.source
            .get(span.start as usize..span.end as usize)
            .unwrap_or_default()
    }

    pub fn at(&self, offset: usize, code: Code, message: String) -> Diagnostic {
        let end = (0..=offset.min(self.source.len()))
            .rev()
            .find(|index| self.source.is_char_boundary(*index))
            .unwrap_or(0);
        let before = &self.source[..end];
        let line = before.matches('\n').count() + 1;
        let column = before
            .rfind('\n')
            .map_or(before, |newline| &before[newline + 1..])
            .chars()
            .count()
            + 1;
        Diagnostic {
            path: self.path.to_path_buf(),
            line,
            column,
            code,
            message,
        }
    }
}
