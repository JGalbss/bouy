//! Section 11 of the contract: library imports and globals, and the Erlang modules behind them.

/// What a library import or a global names on the Erlang side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Binding {
    /// A namespace module: `Ns.f(args)` is `Module:'f'(Args)`.
    Namespace(&'static str),
    /// A function: `f(args)` is `Module:'f'(Args)`.
    Function {
        module: &'static str,
        function: &'static str,
    },
    /// A global error class in `buoy_error`, such as `TypeError`.
    ErrorClass(&'static str),
    /// `Boolean`, which converts to a boolean.
    Boolean,
    /// `undefined`, `NaN`, or `Infinity`.
    Constant(&'static str),
    /// `structuredClone`.
    StructuredClone,
    /// `process`, of which only `process.env.NAME` and `process.argv` exist.
    Process,
    /// A host API that Buoy does not provide (error `BUOY207`).
    HostApi,
}

const BUOY_FUNCTIONS: &[&str] = &[
    "spawn",
    "cast",
    "stop",
    "inspect",
    "supervise",
    "child",
    "schedule",
    "cancelSchedule",
    "sleep",
    "withTimeout",
    "self",
];

const EFFECT_NAMESPACES: &[(&str, &str)] = &[
    ("Effect", "buoy_effect"),
    ("Data", "buoy_data"),
    ("Schedule", "buoy_schedule"),
    ("Schema", "buoy_schema"),
    ("Console", "buoy_effect_console"),
    ("Duration", "buoy_duration"),
];

const AI_FUNCTIONS: &[&str] = &[
    "generateText",
    "streamText",
    "tool",
    "stepCountIs",
    "jsonSchema",
];

const OPENAI_FUNCTIONS: &[&str] = &["createOpenAI"];

/// Whether `specifier` names a library rather than a Buoy module.
pub fn is_library(specifier: &str) -> bool {
    matches!(specifier, "buoy" | "effect" | "ai" | "@ai-sdk/openai")
        || effect_submodule(specifier).is_some()
}

/// The binding of `import { name } from "specifier"`.
pub fn named_import(specifier: &str, name: &str) -> Option<Binding> {
    match specifier {
        "buoy" => BUOY_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "buoy",
                function,
            }),
        "effect" if name == "pipe" => Some(Binding::Function {
            module: "buoy_effect",
            function: "pipe",
        }),
        "effect" => EFFECT_NAMESPACES
            .iter()
            .find(|(export, _)| *export == name)
            .map(|(_, module)| Binding::Namespace(module)),
        "ai" => AI_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "buoy_ai",
                function,
            }),
        // `openai` is callable and has methods, `openai.chat(model)`, as a namespace does.
        "@ai-sdk/openai" if name == "openai" => Some(Binding::Namespace("buoy_ai_openai")),
        "@ai-sdk/openai" => OPENAI_FUNCTIONS
            .iter()
            .find(|function| **function == name)
            .map(|function| Binding::Function {
                module: "buoy_ai_openai",
                function,
            }),
        _ => None,
    }
}

/// The binding of `import * as X from "specifier"`.
pub fn namespace_import(specifier: &str) -> Option<Binding> {
    effect_submodule(specifier).map(Binding::Namespace)
}

fn effect_submodule(specifier: &str) -> Option<&'static str> {
    let export = specifier.strip_prefix("effect/")?;
    EFFECT_NAMESPACES
        .iter()
        .find(|(name, _)| *name == export)
        .map(|(_, module)| *module)
}

/// The binding of an identifier that no declaration in the module resolves.
pub fn global(name: &str) -> Option<Binding> {
    let binding = match name {
        "console" => Binding::Namespace("buoy_console"),
        "Math" => Binding::Namespace("buoy_math"),
        "JSON" => Binding::Namespace("buoy_json"),
        "Object" => Binding::Namespace("buoy_object"),
        "Array" => Binding::Namespace("buoy_array"),
        "Number" => Binding::Namespace("buoy_number"),
        "String" => Binding::Namespace("buoy_string"),
        "Date" => Binding::Namespace("buoy_date"),
        "performance" => Binding::Namespace("buoy_performance"),
        "Promise" => Binding::Namespace("buoy_task"),
        "Map" => Binding::Namespace("buoy_map"),
        "Set" => Binding::Namespace("buoy_set"),
        "Error" | "TypeError" | "RangeError" | "SyntaxError" => {
            Binding::ErrorClass(error_class_name(name))
        }
        "Boolean" => Binding::Boolean,
        "parseInt" | "parseFloat" => Binding::Function {
            module: "buoy_number",
            function: if name == "parseInt" {
                "parseInt"
            } else {
                "parseFloat"
            },
        },
        "isNaN" => Binding::Function {
            module: "buoy_number",
            function: "$isNaN",
        },
        "isFinite" => Binding::Function {
            module: "buoy_number",
            function: "$isFinite",
        },
        "undefined" => Binding::Constant("undefined"),
        "NaN" => Binding::Constant("NaN"),
        "Infinity" => Binding::Constant("Infinity"),
        "structuredClone" => Binding::StructuredClone,
        "process" => Binding::Process,
        "setTimeout" | "setInterval" | "setImmediate" | "queueMicrotask" | "globalThis"
        | "clearTimeout" | "clearInterval" => Binding::HostApi,
        _ => return None,
    };
    Some(binding)
}

/// The JavaScript name and the functions of each namespace module, global or from a library:
/// what `Ns.f(args)` may call. The runtime module exports each function as `f/1`.
const GLOBAL_FUNCTIONS: &[(&str, &str, &[&str])] = &[
    (
        "buoy_console",
        "console",
        &["log", "error", "warn", "info", "debug"],
    ),
    (
        "buoy_math",
        "Math",
        &[
            "abs", "acos", "acosh", "asin", "asinh", "atan", "atan2", "atanh", "cbrt", "ceil",
            "clz32", "cos", "cosh", "exp", "expm1", "floor", "fround", "hypot", "imul", "log",
            "log10", "log1p", "log2", "max", "min", "pow", "random", "round", "sign", "sin",
            "sinh", "sqrt", "tan", "tanh", "trunc",
        ],
    ),
    ("buoy_json", "JSON", &["parse", "stringify"]),
    (
        "buoy_object",
        "Object",
        &[
            "keys",
            "values",
            "entries",
            "fromEntries",
            "assign",
            "freeze",
            "hasOwn",
            "is",
            "create",
            "getOwnPropertyNames",
            "groupBy",
            "setPrototypeOf",
        ],
    ),
    ("buoy_array", "Array", &["isArray", "from", "of"]),
    (
        "buoy_number",
        "Number",
        &[
            "isInteger",
            "isSafeInteger",
            "isFinite",
            "isNaN",
            "parseFloat",
            "parseInt",
        ],
    ),
    ("buoy_string", "String", &["fromCharCode", "fromCodePoint"]),
    ("buoy_date", "Date", &["now"]),
    ("buoy_performance", "performance", &["now"]),
    (
        "buoy_task",
        "Promise",
        &["all", "allSettled", "race", "any", "resolve", "reject"],
    ),
    ("buoy_map", "Map", &["groupBy"]),
    ("buoy_set", "Set", &[]),
    // The `openai` import of "@ai-sdk/openai" (section 14).
    ("buoy_ai_openai", "openai", &["chat", "languageModel"]),
    // The namespaces of "effect" (section 13). `Data` has no runtime module: it is only the
    // base of an error class.
    (
        "buoy_effect",
        "Effect",
        &[
            "succeed",
            "fail",
            "sync",
            "try",
            "promise",
            "tryPromise",
            "die",
            "gen",
            "fn",
            "fnUntraced",
            "map",
            "flatMap",
            "andThen",
            "tap",
            "catch",
            "catchTag",
            "catchTags",
            "mapError",
            "orElseSucceed",
            "result",
            "match",
            "ensuring",
            "as",
            "asVoid",
            "zip",
            "all",
            "forEach",
            "sleep",
            "timeout",
            "retry",
            "race",
            "runPromise",
            "runSync",
        ],
    ),
    (
        "buoy_schedule",
        "Schedule",
        &["recurs", "spaced", "exponential", "fixed"],
    ),
    (
        "buoy_schema",
        "Schema",
        &[
            "Struct",
            "Literal",
            "Array",
            "Union",
            "optional",
            "decodeUnknownSync",
            "decodeUnknownEffect",
            "is",
        ],
    ),
    (
        "buoy_effect_console",
        "Console",
        &["log", "error", "warn", "info", "debug"],
    ),
    (
        "buoy_duration",
        "Duration",
        &[
            "millis", "seconds", "minutes", "hours", "toMillis", "format",
        ],
    ),
];

/// The global name of a global namespace module, such as `console` for `buoy_console`, when
/// `Ns.name(args)` names no function that the runtime provides.
pub fn missing_global_function(module: &str, name: &str) -> Option<&'static str> {
    let (_, global, functions) = GLOBAL_FUNCTIONS
        .iter()
        .find(|(namespace, _, _)| *namespace == module)?;
    (!functions.contains(&name)).then_some(*global)
}

fn error_class_name(name: &str) -> &'static str {
    match name {
        "TypeError" => "TypeError",
        "RangeError" => "RangeError",
        "SyntaxError" => "SyntaxError",
        _ => "Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each function of the table is exported by its runtime module, so that a call never
    /// reaches an Erlang `undef`.
    #[test]
    fn global_functions_exist_in_the_runtime() {
        let runtime = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/src");
        for (module, global, functions) in GLOBAL_FUNCTIONS {
            let path = find_file(&runtime, &format!("{module}.erl"))
                .unwrap_or_else(|| panic!("runtime/src holds no {module}.erl"));
            let source = std::fs::read_to_string(&path)
                .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
            let exports: String = source
                .lines()
                .filter(|line| line.starts_with("-export("))
                .collect();
            for function in *functions {
                // `Promise.allSettled` compiles to `buoy_task:all_settled/1` (section 7).
                let function = if *function == "allSettled" {
                    "all_settled"
                } else {
                    function
                };
                assert!(
                    exports.contains(&format!("{function}/1"))
                        || exports.contains(&format!("'{function}'/1")),
                    "{global}.{function} is not exported by {module}"
                );
            }
        }
    }

    /// The path of the file `name` in `directory` or one of its subdirectories.
    fn find_file(directory: &std::path::Path, name: &str) -> Option<std::path::PathBuf> {
        std::fs::read_dir(directory)
            .ok()?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find_map(|path| {
                if path.is_dir() {
                    find_file(&path, name)
                } else {
                    (path.file_name()? == name).then_some(path)
                }
            })
    }

    #[test]
    fn resolves_library_imports() {
        assert!(is_library("effect/Effect"));
        assert!(!is_library("lodash"));
        assert_eq!(
            named_import("effect", "Effect"),
            Some(Binding::Namespace("buoy_effect"))
        );
        assert_eq!(named_import("buoy", "nope"), None);
        assert_eq!(
            namespace_import("effect/Schema"),
            Some(Binding::Namespace("buoy_schema"))
        );
    }

    #[test]
    fn resolves_ai_imports() {
        assert_eq!(
            named_import("ai", "generateText"),
            Some(Binding::Function {
                module: "buoy_ai",
                function: "generateText"
            })
        );
        assert_eq!(
            named_import("@ai-sdk/openai", "openai"),
            Some(Binding::Namespace("buoy_ai_openai"))
        );
        assert_eq!(missing_global_function("buoy_ai_openai", "chat"), None);
        assert_eq!(
            missing_global_function("buoy_ai_openai", "responses"),
            Some("openai")
        );
    }
}
