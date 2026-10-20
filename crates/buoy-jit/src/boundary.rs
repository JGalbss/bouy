//! The values that cross between the Erlang tier and a run, by copy.
//!
//! A run starts with the values of its arguments and globals. A global may hold an object
//! or an array of the engine, so the caller flattens the graph that the globals reach into
//! items, one for each object and array, which refer to each other by index. [`import`]
//! makes a copy of each item in the heap of the run and checks that every value has the
//! type of its place, as the code assumes; a value of another type fails the start, and
//! the Erlang tier runs the call.
//!
//! When the run returns, [`export`] reads the items back as the run leaves them, then the
//! objects and arrays of the heap that the written globals and the items reach, which the
//! run made. The caller writes the fields of each item back to its original and makes an
//! object of the engine for each new one, so the identity of every object is kept.

#![allow(unsafe_code)]

use std::collections::{HashMap, HashSet};

use buoy_jit_ir::{ClassId, Ty};

use crate::codegen::{ARRAY_TAG, Layout, array};
use crate::run::{Frame, Value};
use crate::text;

/// An object or an array outside the heap of a run.
#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    /// An instance of the class, with the values of its fields in the order of its layout.
    Object {
        class: ClassId,
        fields: Vec<Value>,
    },
    Array(Vec<Value>),
}

/// The copies of the items in the heap of a run.
#[derive(Debug, Default)]
pub struct Imported {
    /// The address of the copy of each item.
    addresses: Vec<u64>,
    /// The element type of each array, from the place that holds it.
    elements: Vec<Option<Ty>>,
}

/// The words of the arguments and the globals for the machine code, with the items that
/// they refer to copied into the heap of `frame`. `None` when a value or an item does not
/// have the type of its place, or the heap is full.
pub fn import<'v>(
    frame: &mut Frame,
    layout: &Layout,
    places: impl Iterator<Item = (&'v Ty, &'v Value)>,
    items: &[Item],
) -> Option<(Vec<u64>, Imported)> {
    let mut importer = Importer {
        frame,
        layout,
        items,
        imported: Imported::default(),
        checks: Vec::new(),
        checked: HashSet::new(),
        filled: vec![false; items.len()],
    };
    for item in items {
        let words = match item {
            Item::Object { class, fields } => {
                let layout_fields = layout.fields.get(*class as usize)?;
                if fields.len() != layout_fields.len() {
                    return None;
                }
                1 + fields.len()
            }
            Item::Array(elements) => 4 + elements.len().max(4),
        };
        let address = importer.frame.allocate_words(words)? as u64;
        importer.imported.addresses.push(address);
        importer.imported.elements.push(None);
    }
    let mut words = Vec::new();
    for (ty, value) in places {
        words.push(importer.word(value, ty)?);
    }
    importer.drain()?;
    // An item that no place reaches would write zeros back to its original.
    if importer.filled.contains(&false) {
        return None;
    }
    Some((words, importer.imported))
}

struct Importer<'f, 'l, 'i> {
    frame: &'f mut Frame,
    layout: &'l Layout,
    items: &'i [Item],
    imported: Imported,
    /// The items that a place refers to, with the type of the place, still to check.
    checks: Vec<(u32, Ty)>,
    checked: HashSet<(u32, Ty)>,
    /// Whether the copy of each item holds its values.
    filled: Vec<bool>,
}

impl Importer<'_, '_, '_> {
    /// The word of a value in a place of the type.
    fn word(&mut self, value: &Value, ty: &Ty) -> Option<u64> {
        Some(match (ty, value) {
            (Ty::Num, Value::Num(number)) => number.to_bits(),
            (Ty::Bool, Value::Bool(flag)) => u64::from(*flag),
            (place, Value::Null) if place.is_reference() => 0,
            (place, Value::Undefined) if place.is_reference() => 1,
            (Ty::Str, Value::Str(units)) => text::allocate_string(self.frame, units)?,
            (Ty::Object(_) | Ty::Any | Ty::Array(_), Value::Ref(index)) => {
                let address = *self.imported.addresses.get(*index as usize)?;
                self.checks.push((*index, ty.clone()));
                address
            }
            _ => return None,
        })
    }

    /// Checks each item against the places that refer to it, and fills its copy the first
    /// time.
    fn drain(&mut self) -> Option<()> {
        while let Some((index, ty)) = self.checks.pop() {
            if !self.checked.insert((index, ty.clone())) {
                continue;
            }
            let slot = index as usize;
            let address = self.imported.addresses[slot];
            match (&self.items[slot], &ty) {
                (Item::Object { class, fields }, Ty::Object(_) | Ty::Any) => {
                    if let Ty::Object(bound) = ty
                        && !self.layout.is_subclass(*class, bound)
                    {
                        return None;
                    }
                    if !self.filled[slot] {
                        self.filled[slot] = true;
                        self.fill_object(address, *class, fields)?;
                    }
                }
                // An array has one element type, so every place that holds it agrees.
                (Item::Array(elements), Ty::Array(element)) => {
                    match &self.imported.elements[slot] {
                        Some(known) if *known == **element => {}
                        Some(_) => return None,
                        None => {
                            self.imported.elements[slot] = Some((**element).clone());
                            self.filled[slot] = true;
                            self.fill_array(address, element, elements)?;
                        }
                    }
                }
                _ => return None,
            }
        }
        Some(())
    }

    fn fill_object(&mut self, address: u64, class: ClassId, fields: &[Value]) -> Option<()> {
        let types = self.layout.fields.get(class as usize)?.clone();
        let object = address as *mut u64;
        // SAFETY: `import` allocated a word for the class and one for each field.
        unsafe { object.write(u64::from(class)) };
        for (index, (value, ty)) in fields.iter().zip(&types).enumerate() {
            let word = self.word(value, ty)?;
            // SAFETY: as above.
            unsafe { object.add(1 + index).write(word) };
        }
        Some(())
    }

    fn fill_array(&mut self, address: u64, element: &Ty, elements: &[Value]) -> Option<()> {
        let header = address as *mut u64;
        let capacity = elements.len().max(4);
        // SAFETY: `import` allocated the four words of the header and `capacity` words of
        // elements after them.
        unsafe {
            let data = header.add(4);
            header.write(ARRAY_TAG as u64);
            header.add(1).write(elements.len() as u64);
            header.add(2).write(capacity as u64);
            header.add(3).write(data as u64);
            for (index, value) in elements.iter().enumerate() {
                let word = self.word(value, element)?;
                data.add(index).write(word);
            }
        }
        Some(())
    }
}

/// The values of the written globals, and the items as the run leaves them, then the
/// objects and arrays that it made and that they reach.
///
/// # Safety
///
/// Each word of `written` must hold a value of its type in the heap of a run that
/// returned, and so must the fields and the elements of the copies in `imported`.
pub unsafe fn export<'t>(
    layout: &Layout,
    written: impl Iterator<Item = (u64, &'t Ty)>,
    imported: &Imported,
) -> (Vec<Value>, Vec<Item>) {
    let mut exporter = Exporter {
        layout,
        indexes: HashMap::new(),
        pending: Vec::new(),
        count: 0,
    };
    for (address, element) in imported.addresses.iter().zip(&imported.elements) {
        let kind = element.clone().map_or(Kind::Object, Kind::Array);
        exporter.visit(*address, kind);
    }
    // SAFETY: as the caller promises.
    let written = written
        .map(|(word, ty)| unsafe { exporter.value(word, ty) })
        .collect();
    let mut items = Vec::with_capacity(exporter.count);
    let mut next = 0;
    while next < exporter.pending.len() {
        let (address, kind) = exporter.pending[next].clone();
        // SAFETY: as the caller promises.
        items.push(unsafe { exporter.item(address, &kind) });
        next += 1;
    }
    (written, items)
}

#[derive(Debug, Clone)]
enum Kind {
    Object,
    Array(Ty),
}

struct Exporter<'l> {
    layout: &'l Layout,
    indexes: HashMap<u64, u32>,
    /// The objects and arrays to read, in the order of their indexes.
    pending: Vec<(u64, Kind)>,
    count: usize,
}

impl Exporter<'_> {
    fn visit(&mut self, address: u64, kind: Kind) -> u32 {
        if let Some(index) = self.indexes.get(&address) {
            return *index;
        }
        let index = u32::try_from(self.count).unwrap_or(u32::MAX);
        self.count += 1;
        self.indexes.insert(address, index);
        self.pending.push((address, kind));
        index
    }

    /// The value of a word of the type.
    unsafe fn value(&mut self, word: u64, ty: &Ty) -> Value {
        match ty {
            Ty::Num => Value::Num(f64::from_bits(word)),
            Ty::Bool => Value::Bool(word & 0xff != 0),
            Ty::Void => Value::Undefined,
            _ if word == 0 => Value::Null,
            _ if word == 1 => Value::Undefined,
            // SAFETY: a word of a string type is the address of a string.
            Ty::Str => Value::Str(unsafe { text::units(word) }),
            Ty::Array(element) => Value::Ref(self.visit(word, Kind::Array((**element).clone()))),
            Ty::Object(_) | Ty::Any | Ty::Null => Value::Ref(self.visit(word, Kind::Object)),
        }
    }

    unsafe fn item(&mut self, address: u64, kind: &Kind) -> Item {
        let header = address as *const u64;
        match kind {
            Kind::Object => {
                // SAFETY: an object starts with its class id, a class of the layout.
                let class = unsafe { header.read() };
                let class = ClassId::try_from(class).unwrap_or(0);
                let types = self.layout.fields[class as usize].clone();
                let fields = types
                    .iter()
                    .enumerate()
                    // SAFETY: the object has one word for each field of its class.
                    .map(|(index, ty)| unsafe { self.value(header.add(1 + index).read(), ty) })
                    .collect();
                Item::Object { class, fields }
            }
            Kind::Array(element) => {
                // SAFETY: an array has the header of `codegen::array`.
                let (length, data) = unsafe {
                    (
                        header.byte_add(array::LENGTH as usize).read(),
                        header.byte_add(array::DATA as usize).read() as *const u64,
                    )
                };
                let length = usize::try_from(length).unwrap_or(0);
                let elements = (0..length)
                    // SAFETY: the array has `length` elements at `data`.
                    .map(|index| unsafe { self.value(data.add(index).read(), element) })
                    .collect();
                Item::Array(elements)
            }
        }
    }
}
