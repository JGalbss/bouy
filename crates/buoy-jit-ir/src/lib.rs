//! The typed IR of the native tier (section 17.11 of the contract).
//!
//! The compiler finds islands of typed code: a module-level function whose parameters and
//! result are numbers or booleans, and whose whole call graph is typed code that writes no
//! state outside the objects it creates. It lowers each island to this IR, encodes it with
//! [`Program::encode`], and leaves the bytes in the Erlang module. The native tier decodes
//! them with [`Program::decode`], checks every type, and compiles the functions to machine
//! code with Cranelift.
//!
//! Every value has one of the types of [`Ty`]. A number is an IEEE 754 double, as in
//! JavaScript. An object, an array, or a string is a reference into the native heap of
//! the run; `null` and `undefined` are two reference values that point nowhere. An object
//! stores the id of its class, so a call through an interface dispatches on it.
//!
//! The objects, arrays, and strings that the globals of an entry hold cross the boundary
//! by copy: the run starts with copies of them in its heap, and when it ends, the caller
//! writes the fields of each copy back to its original and makes the objects that the
//! run made and left reachable from them or from the globals it wrote.

mod codec;

pub use codec::DecodeError;

/// The index of a class in [`Program::classes`].
pub type ClassId = u32;
/// The index of a function in [`Program::functions`].
pub type FuncId = u32;
/// The index of a local variable in [`Function::locals`].
pub type LocalId = u32;

/// The classes and functions of the islands of one module.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Program {
    pub classes: Vec<Class>,
    pub functions: Vec<Function>,
    /// The functions that Erlang code calls. Each takes numbers and booleans and returns
    /// a number, a boolean, or nothing.
    pub entries: Vec<FuncId>,
    /// The types of the values that the caller passes after the arguments of an entry:
    /// the variables outside the island that its code reads or writes. A run cannot see
    /// them change, because nothing else runs in the process during it. A run that ends
    /// gives back the values of the globals that [`Expr::SetGlobal`] writes.
    pub globals: Vec<Ty>,
}

/// A class: the layout of its instances and the methods that a dispatch finds.
#[derive(Debug, Clone, PartialEq)]
pub struct Class {
    pub name: String,
    pub parent: Option<ClassId>,
    /// The fields of an instance, those of the parent first, so an instance of a subclass
    /// has the fields of its parent at the same places.
    pub fields: Vec<Ty>,
    /// Each method name and the function it calls, the inherited ones included.
    pub methods: Vec<Method>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Method {
    pub name: String,
    pub function: FuncId,
}

/// A function. A method or a constructor takes its `this` as the first parameter.
#[derive(Debug, Clone, PartialEq)]
pub struct Function {
    pub name: String,
    /// Whether the first parameter is a receiver, which no caller passes as `null` or
    /// `undefined`: a dispatch and a direct call check it, and `new` passes a new object.
    pub receiver: bool,
    /// The parameters are the first locals.
    pub params: u32,
    pub locals: Vec<Ty>,
    pub result: Ty,
    pub body: Vec<Stmt>,
}

/// The type of a value.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Ty {
    /// No value: the result of a function that returns nothing.
    Void,
    Num,
    Bool,
    /// `null` or `undefined`, which every reference type holds too.
    Null,
    /// An instance of the class or of one of its subclasses.
    Object(ClassId),
    /// An instance of any class: the type of an interface.
    Any,
    /// An array of elements of the type.
    Array(Box<Ty>),
    /// A string: a sequence of UTF-16 code units.
    Str,
    /// A typed array of the element type, such as a `Float64Array`. Its elements are
    /// numbers, which a write converts to the element type.
    Typed(TypedKind),
}

/// The element type of a typed array (ECMA-262 Table 71), apart from the BigInt and
/// float16 types, which the native tier does not lower.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TypedKind {
    Int8,
    Uint8,
    Uint8Clamped,
    Int16,
    Uint16,
    Int32,
    Uint32,
    Float32,
    Float64,
}

impl TypedKind {
    /// The kind of the constructor of this name, such as `Float64Array`.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "Int8Array" => Self::Int8,
            "Uint8Array" => Self::Uint8,
            "Uint8ClampedArray" => Self::Uint8Clamped,
            "Int16Array" => Self::Int16,
            "Uint16Array" => Self::Uint16,
            "Int32Array" => Self::Int32,
            "Uint32Array" => Self::Uint32,
            "Float32Array" => Self::Float32,
            "Float64Array" => Self::Float64,
            _ => return None,
        })
    }

    /// The bytes of an element.
    #[must_use]
    pub fn size(self) -> usize {
        match self {
            Self::Int8 | Self::Uint8 | Self::Uint8Clamped => 1,
            Self::Int16 | Self::Uint16 => 2,
            Self::Int32 | Self::Uint32 | Self::Float32 => 4,
            Self::Float64 => 8,
        }
    }

    /// The name of the kind in the engine (`buoy_ref_buffer:kinds/0`).
    #[must_use]
    pub fn engine_name(self) -> &'static str {
        match self {
            Self::Int8 => "int8",
            Self::Uint8 => "uint8",
            Self::Uint8Clamped => "uint8c",
            Self::Int16 => "int16",
            Self::Uint16 => "uint16",
            Self::Int32 => "int32",
            Self::Uint32 => "uint32",
            Self::Float32 => "float32",
            Self::Float64 => "float64",
        }
    }

    /// The kind of an engine name.
    #[must_use]
    pub fn from_engine_name(name: &str) -> Option<Self> {
        [
            Self::Int8,
            Self::Uint8,
            Self::Uint8Clamped,
            Self::Int16,
            Self::Uint16,
            Self::Int32,
            Self::Uint32,
            Self::Float32,
            Self::Float64,
        ]
        .into_iter()
        .find(|kind| kind.engine_name() == name)
    }
}

impl Ty {
    /// Whether the values of the type are references.
    #[must_use]
    pub fn is_reference(&self) -> bool {
        matches!(
            self,
            Self::Null | Self::Object(_) | Self::Any | Self::Array(_) | Self::Str | Self::Typed(_)
        )
    }
}

/// Why a run stops and the Erlang tier runs the call again from its start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bail {
    /// The code throws. The Erlang tier throws the same value.
    Throw = 1,
    /// A property read or write on `null` or `undefined`: a `TypeError`.
    Nullish = 2,
    /// An array index outside the elements, or one that would make a hole.
    Index = 3,
    /// A call through an interface on a class without the method.
    Dispatch = 4,
    /// The native stack is full.
    Stack = 5,
    /// The native heap of the run is full.
    Memory = 6,
    /// A value is `undefined` where its type has no such value, such as the result of a
    /// function that ends without a `return`.
    Undefined = 7,
}

impl Bail {
    /// The reason of a code, as [`Bail`] numbers them.
    #[must_use]
    pub fn from_code(code: u8) -> Option<Self> {
        Some(match code {
            1 => Self::Throw,
            2 => Self::Nullish,
            3 => Self::Index,
            4 => Self::Dispatch,
            5 => Self::Stack,
            6 => Self::Memory,
            7 => Self::Undefined,
            _ => return None,
        })
    }

    /// The name of the reason, which the Erlang tier reports.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Throw => "throw",
            Self::Nullish => "nullish",
            Self::Index => "index",
            Self::Dispatch => "dispatch",
            Self::Stack => "stack",
            Self::Memory => "memory",
            Self::Undefined => "undefined",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Stmt {
    Expr(Expr),
    If(Expr, Vec<Stmt>, Vec<Stmt>),
    /// A loop. Each turn tests `cond` (before the body, or after it when `test_after`),
    /// runs `body`, and then `update`. `continue` goes to `update`.
    Loop {
        cond: Option<Expr>,
        body: Vec<Stmt>,
        update: Vec<Stmt>,
        test_after: bool,
    },
    /// Leaves the loop `depth` levels out, 0 for the innermost.
    Break(u32),
    /// Goes to the update of the loop `depth` levels out.
    Continue(u32),
    Return(Option<Expr>),
    Bail(Bail),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    Num(f64),
    Bool(bool),
    Null,
    Undefined,
    /// A string literal, as its UTF-16 code units.
    Str(Vec<u16>),
    Local(LocalId),
    /// The value of [`Program::globals`] at the index.
    Global(u32),
    /// Stores the value in the global at the index, and is the value.
    SetGlobal(u32, Box<Expr>),
    /// Stores the value in the local, and is the value.
    SetLocal(LocalId, Box<Expr>),
    Unary(Unary, Box<Expr>),
    Binary(Binary, Box<Expr>, Box<Expr>),
    /// `&&` and `||` on booleans.
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    /// `test ? then : otherwise`, with the type of the result.
    Cond(Ty, Box<Expr>, Box<Expr>, Box<Expr>),
    /// Field `index` of an object of the class or of a subclass. `null` and `undefined`
    /// bail with [`Bail::Nullish`].
    Field(Box<Expr>, ClassId, u32),
    SetField(Box<Expr>, ClassId, u32, Box<Expr>),
    /// The length of an array, a typed array, or a string.
    Length(Box<Expr>),
    /// An element of an array or a typed array. An index outside the elements reads
    /// `undefined` from an array of references and bails from any other array.
    Index(Box<Expr>, Box<Expr>),
    /// Writes an element. The index of an array may be the length, which appends; an
    /// index of a typed array outside its elements bails.
    SetIndex(Box<Expr>, Box<Expr>, Box<Expr>),
    /// Appends an element, and is the new length.
    Push(Box<Expr>, Box<Expr>),
    /// Removes the first element of an array of references and is it, or `undefined` when
    /// the array is empty.
    Shift(Box<Expr>),
    /// The string of the concatenation of the parts: numbers, booleans, strings, and
    /// `null` or `undefined`, each converted as `ToString` does.
    Text(Vec<Expr>),
    /// Bails with the reason. The type is that of the place where it stands.
    Fail(Bail, Ty),
    /// Runs the statements, which neither return nor leave a loop around the block, and
    /// is the value of the expression.
    Block(Vec<Stmt>, Box<Expr>),
    Call(FuncId, Vec<Expr>),
    /// Calls the method of the class of the first argument.
    Dispatch {
        method: String,
        args: Vec<Expr>,
        result: Ty,
    },
    /// A new instance of the class, whose constructor runs with the arguments.
    New(ClassId, FuncId, Vec<Expr>),
    /// A new array of these elements.
    ArrayOf(Ty, Vec<Expr>),
    /// A new array of a length, with every element the value.
    ArrayFill(Ty, Box<Expr>, Box<Expr>),
    /// A new typed array of a length, with every element zero: `new Float64Array(n)`.
    NewTyped(TypedKind, Box<Expr>),
    Math(MathFn, Vec<Expr>),
    /// Evaluates each expression, and is the value of the last.
    Seq(Vec<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unary {
    /// `-x` on a number.
    Neg,
    /// `!x` on a boolean.
    Not,
    /// `~x`.
    BitNot,
    /// The truth value of a number, a string, or a reference (`ToBoolean`).
    Truthy,
    /// Whether a reference is `null` or `undefined`.
    Nullish,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Binary {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Pow,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
    UShr,
    Lt,
    Le,
    Gt,
    Ge,
    /// `===` on two numbers, two booleans, two strings by their code units, or two
    /// references.
    Eq,
    Ne,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MathFn {
    Sqrt,
    Abs,
    Floor,
    Ceil,
    Trunc,
    Round,
    Min,
    Max,
    Sign,
    Sin,
    Cos,
    Tan,
    Atan,
    Atan2,
    Exp,
    Log,
    Pow,
}

impl MathFn {
    /// The function of `Math.<name>`, and its arity.
    #[must_use]
    pub fn from_name(name: &str) -> Option<(Self, usize)> {
        Some(match name {
            "sqrt" => (Self::Sqrt, 1),
            "abs" => (Self::Abs, 1),
            "floor" => (Self::Floor, 1),
            "ceil" => (Self::Ceil, 1),
            "trunc" => (Self::Trunc, 1),
            "round" => (Self::Round, 1),
            "min" => (Self::Min, 2),
            "max" => (Self::Max, 2),
            "sign" => (Self::Sign, 1),
            "sin" => (Self::Sin, 1),
            "cos" => (Self::Cos, 1),
            "tan" => (Self::Tan, 1),
            "atan" => (Self::Atan, 1),
            "atan2" => (Self::Atan2, 2),
            "exp" => (Self::Exp, 1),
            "log" => (Self::Log, 1),
            "pow" => (Self::Pow, 2),
            _ => return None,
        })
    }
}

/// The JavaScript `ToInt32` of a number (ECMA-262 §7.1.6).
#[must_use]
pub fn to_int32(value: f64) -> i32 {
    if !value.is_finite() {
        return 0;
    }
    let modulo = value.trunc().rem_euclid(4_294_967_296.0);
    // `modulo` is an integer in [0, 2^32), so the conversion is exact.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let bits = modulo as u32;
    i32::from_ne_bytes(bits.to_ne_bytes())
}

/// The JavaScript `Number::exponentiate` (ECMA-262 §6.1.6.1.3): IEEE 754 `pow`, except
/// that an exponent of NaN gives NaN and a base of absolute value 1 with an infinite
/// exponent gives NaN.
#[must_use]
pub fn exponentiate(base: f64, exponent: f64) -> f64 {
    if exponent.is_nan() || (base.abs().to_bits() == 1.0_f64.to_bits() && exponent.is_infinite()) {
        return f64::NAN;
    }
    base.powf(exponent)
}

/// The JavaScript `Math.round` (ECMA-262 §21.3.2.28): the integer closest to the value,
/// the larger one on a tie, with the sign of the value for a result of zero.
#[must_use]
pub fn round(value: f64) -> f64 {
    if !value.is_finite() || value.fract() == 0.0 {
        return value;
    }
    if value > 0.0 && value < 0.5 {
        return 0.0;
    }
    if (-0.5..0.0).contains(&value) {
        return -0.0;
    }
    let floor = value.floor();
    if value - floor >= 0.5 {
        floor + 1.0
    } else {
        floor
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn int32_wraps_like_javascript() {
        assert_eq!(to_int32(f64::NAN), 0);
        assert_eq!(to_int32(f64::INFINITY), 0);
        assert_eq!(to_int32(2_147_483_648.0), -2_147_483_648);
        assert_eq!(to_int32(4_294_967_297.5), 1);
        assert_eq!(to_int32(-1.9), -1);
        assert_eq!(to_int32(-4_294_967_297.0), -1);
    }

    #[test]
    fn round_and_pow_follow_the_special_cases() {
        assert_eq!(round(2.5).to_bits(), 3.0_f64.to_bits());
        assert_eq!(round(-2.5).to_bits(), (-2.0_f64).to_bits());
        assert!(round(-0.2).is_sign_negative());
        assert!(exponentiate(1.0, f64::INFINITY).is_nan());
        assert!(exponentiate(f64::NAN, 0.0).eq(&1.0));
    }
}
