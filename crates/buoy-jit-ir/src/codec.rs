//! The bytes of a [`Program`]: each value writes a tag byte for its variant and then its
//! fields in order. Integers are little-endian `u32`, numbers the eight bytes of the
//! double, strings a length and UTF-8, and sequences a length and the items.

use std::fmt;

use super::{
    Bail, Binary, Class, Expr, Function, MathFn, Method, Program, Stmt, Ty, TypedKind, Unary,
};

/// The first bytes of an encoded program, with the version of the format.
const MAGIC: &[u8; 4] = b"BNI4";

/// Bytes that are not a program of this version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError {
    pub offset: usize,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "the native IR is malformed at byte {}", self.offset)
    }
}

impl std::error::Error for DecodeError {}

impl Program {
    /// The bytes of the program.
    #[must_use]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        self.write(&mut out);
        out
    }

    /// The program of bytes that [`Program::encode`] wrote.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut reader = Reader { bytes, at: 0 };
        if reader.take(MAGIC.len())? != MAGIC {
            return Err(DecodeError { offset: 0 });
        }
        let program = Self::read(&mut reader)?;
        if reader.at != bytes.len() {
            return Err(reader.error());
        }
        Ok(program)
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn error(&self) -> DecodeError {
        DecodeError { offset: self.at }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.at.checked_add(count).ok_or_else(|| self.error())?;
        let slice = self.bytes.get(self.at..end).ok_or_else(|| self.error())?;
        self.at = end;
        Ok(slice)
    }

    fn byte(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], DecodeError> {
        let slice = self.take(N)?;
        slice.try_into().map_err(|_| self.error())
    }
}

/// A value that has bytes.
trait Codec: Sized {
    fn write(&self, out: &mut Vec<u8>);
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError>;
}

impl Codec for u32 {
    fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_le_bytes());
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        Ok(Self::from_le_bytes(reader.array()?))
    }
}

impl Codec for u16 {
    fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_le_bytes());
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        Ok(Self::from_le_bytes(reader.array()?))
    }
}

impl Codec for f64 {
    fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.to_le_bytes());
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        Ok(Self::from_le_bytes(reader.array()?))
    }
}

impl Codec for bool {
    fn write(&self, out: &mut Vec<u8>) {
        out.push(u8::from(*self));
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        match reader.byte()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(reader.error()),
        }
    }
}

/// A length, which the format writes as a `u32`.
fn write_len(len: usize, out: &mut Vec<u8>) {
    u32::try_from(len).unwrap_or(u32::MAX).write(out);
}

fn read_len(reader: &mut Reader<'_>) -> Result<usize, DecodeError> {
    let len = usize::try_from(u32::read(reader)?).map_err(|_| reader.error())?;
    // Every item takes at least one byte, so a longer length is malformed.
    if len > reader.bytes.len() - reader.at {
        return Err(reader.error());
    }
    Ok(len)
}

impl Codec for String {
    fn write(&self, out: &mut Vec<u8>) {
        write_len(self.len(), out);
        out.extend_from_slice(self.as_bytes());
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        let len = read_len(reader)?;
        let bytes = reader.take(len)?;
        Self::from_utf8(bytes.to_vec()).map_err(|_| reader.error())
    }
}

impl<T: Codec> Codec for Vec<T> {
    fn write(&self, out: &mut Vec<u8>) {
        write_len(self.len(), out);
        for item in self {
            item.write(out);
        }
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        let len = read_len(reader)?;
        (0..len).map(|_| T::read(reader)).collect()
    }
}

impl<T: Codec> Codec for Box<T> {
    fn write(&self, out: &mut Vec<u8>) {
        (**self).write(out);
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        T::read(reader).map(Box::new)
    }
}

impl<T: Codec> Codec for Option<T> {
    fn write(&self, out: &mut Vec<u8>) {
        match self {
            None => out.push(0),
            Some(value) => {
                out.push(1);
                value.write(out);
            }
        }
    }
    fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
        match reader.byte()? {
            0 => Ok(None),
            1 => T::read(reader).map(Some),
            _ => Err(reader.error()),
        }
    }
}

/// Writes the fields of a struct in order and reads them back.
macro_rules! record {
    ($type:ident { $($field:ident),* }) => {
        impl Codec for $type {
            fn write(&self, out: &mut Vec<u8>) {
                $(self.$field.write(out);)*
            }
            fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
                Ok(Self { $($field: Codec::read(reader)?),* })
            }
        }
    };
}

record!(Program {
    classes,
    functions,
    entries,
    globals
});
record!(Class {
    name,
    parent,
    fields,
    methods
});
record!(Method { name, function });
record!(Function {
    name,
    receiver,
    params,
    locals,
    result,
    body
});

/// Writes a fieldless enum as one byte, its position in the list.
macro_rules! tags {
    ($type:ident { $($variant:ident),* }) => {
        impl Codec for $type {
            fn write(&self, out: &mut Vec<u8>) {
                const ALL: &[$type] = &[$($type::$variant),*];
                let tag = ALL.iter().position(|item| item == self).unwrap_or(0);
                out.push(u8::try_from(tag).unwrap_or(u8::MAX));
            }
            fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
                const ALL: &[$type] = &[$($type::$variant),*];
                let tag = reader.byte()?;
                ALL.get(usize::from(tag)).copied().ok_or_else(|| reader.error())
            }
        }
    };
}

tags!(Bail {
    Throw,
    Nullish,
    Index,
    Dispatch,
    Stack,
    Memory,
    Undefined
});
tags!(Unary {
    Neg,
    Not,
    BitNot,
    Truthy,
    Nullish
});
tags!(Binary {
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
    Eq,
    Ne
});
tags!(TypedKind {
    Int8,
    Uint8,
    Uint8Clamped,
    Int16,
    Uint16,
    Int32,
    Uint32,
    Float32,
    Float64
});
tags!(MathFn {
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
    Pow
});

/// Writes a variant as its tag byte and its fields in order, and reads it back.
macro_rules! variants {
    ($type:ident {
        $($tag:literal => $variant:ident $(($($field:ident),*))? $({$($named:ident),*})?),* $(,)?
    }) => {
        impl Codec for $type {
            fn write(&self, out: &mut Vec<u8>) {
                match self {
                    $($type::$variant $(($($field),*))? $({$($named),*})? => {
                        out.push($tag);
                        $($($field.write(out);)*)?
                        $($($named.write(out);)*)?
                    })*
                }
            }
            fn read(reader: &mut Reader<'_>) -> Result<Self, DecodeError> {
                Ok(match reader.byte()? {
                    $($tag => $type::$variant
                        $(($({
                            let _ = stringify!($field);
                            Codec::read(reader)?
                        }),*))?
                        $({$($named: Codec::read(reader)?),*})?,)*
                    _ => return Err(reader.error()),
                })
            }
        }
    };
}

variants!(Ty {
    0 => Void,
    1 => Num,
    2 => Bool,
    3 => Null,
    4 => Object(class),
    5 => Any,
    6 => Array(element),
    7 => Str,
    8 => Typed(kind),
});

variants!(Stmt {
    0 => Expr(expr),
    1 => If(test, then, otherwise),
    2 => Loop { cond, body, update, test_after },
    3 => Break(depth),
    4 => Continue(depth),
    5 => Return(value),
    6 => Bail(reason),
});

variants!(Expr {
    0 => Num(value),
    1 => Bool(value),
    2 => Null,
    3 => Undefined,
    4 => Local(local),
    5 => SetLocal(local, value),
    6 => Unary(op, operand),
    7 => Binary(op, left, right),
    8 => And(left, right),
    9 => Or(left, right),
    10 => Cond(ty, test, then, otherwise),
    11 => Field(object, class, index),
    12 => SetField(object, class, index, value),
    13 => Length(array),
    14 => Index(array, index),
    15 => SetIndex(array, index, value),
    16 => Push(array, value),
    17 => Call(function, args),
    18 => Dispatch { method, args, result },
    19 => New(class, constructor, args),
    20 => ArrayOf(element, items),
    21 => ArrayFill(element, length, value),
    22 => Math(function, args),
    23 => Seq(items),
    24 => Global(index),
    25 => Str(units),
    26 => SetGlobal(index, value),
    27 => Shift(array),
    28 => Text(parts),
    29 => Fail(reason, ty),
    30 => Block(stmts, value),
    31 => NewTyped(kind, length),
});

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_program_reads_back_the_same() {
        let program = Program {
            classes: vec![Class {
                name: "Body".to_owned(),
                parent: None,
                fields: vec![
                    Ty::Num,
                    Ty::Array(Box::new(Ty::Object(0))),
                    Ty::Typed(TypedKind::Uint8Clamped),
                ],
                methods: vec![Method {
                    name: "step".to_owned(),
                    function: 0,
                }],
            }],
            functions: vec![Function {
                name: "step".to_owned(),
                receiver: true,
                params: 1,
                locals: vec![Ty::Object(0), Ty::Num],
                result: Ty::Num,
                body: vec![
                    Stmt::Loop {
                        cond: Some(Expr::Binary(
                            Binary::Lt,
                            Box::new(Expr::Local(1)),
                            Box::new(Expr::Num(10.5)),
                        )),
                        update: vec![Stmt::Expr(Expr::SetGlobal(
                            1,
                            Box::new(Expr::Text(vec![
                                Expr::Str(vec![0x76, 0x2603]),
                                Expr::Local(1),
                            ])),
                        ))],
                        body: vec![Stmt::Break(0), Stmt::Bail(Bail::Throw)],
                        test_after: false,
                    },
                    Stmt::Expr(Expr::NewTyped(TypedKind::Float32, Box::new(Expr::Num(4.0)))),
                    Stmt::Return(Some(Expr::Math(
                        MathFn::Sqrt,
                        vec![Expr::Field(Box::new(Expr::Local(0)), 0, 0)],
                    ))),
                ],
            }],
            entries: vec![0],
            globals: vec![Ty::Num, Ty::Str],
        };
        let bytes = program.encode();
        assert_eq!(Program::decode(&bytes), Ok(program));
        assert!(Program::decode(&bytes[..bytes.len() - 1]).is_err());
        assert!(Program::decode(b"nope").is_err());
    }
}
