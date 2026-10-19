//! `ROMix` of scrypt (RFC 7914, section 5) for the `ScryptJob` of
//! `internalBinding('crypto')` (`src/crypto/crypto_scrypt.cc`). OTP's crypto has no
//! scrypt; Erlang runs the two `PBKDF2-HMAC-SHA256` steps on it and each `ROMix` runs here.

/// Salsa20/8 core of RFC 7914, section 3, in place.
fn salsa20_8(block: &mut [u32; 16]) {
    let mut x = *block;
    let mut step = |a: usize, b: usize, c: usize, shift: u32| {
        x[a] ^= x[b].wrapping_add(x[c]).rotate_left(shift);
    };
    for _ in 0..4 {
        step(4, 0, 12, 7);
        step(8, 4, 0, 9);
        step(12, 8, 4, 13);
        step(0, 12, 8, 18);
        step(9, 5, 1, 7);
        step(13, 9, 5, 9);
        step(1, 13, 9, 13);
        step(5, 1, 13, 18);
        step(14, 10, 6, 7);
        step(2, 14, 10, 9);
        step(6, 2, 14, 13);
        step(10, 6, 2, 18);
        step(3, 15, 11, 7);
        step(7, 3, 15, 9);
        step(11, 7, 3, 13);
        step(15, 11, 7, 18);
        step(1, 0, 3, 7);
        step(2, 1, 0, 9);
        step(3, 2, 1, 13);
        step(0, 3, 2, 18);
        step(6, 5, 4, 7);
        step(7, 6, 5, 9);
        step(4, 7, 6, 13);
        step(5, 4, 7, 18);
        step(11, 10, 9, 7);
        step(8, 11, 10, 9);
        step(9, 8, 11, 13);
        step(10, 9, 8, 18);
        step(12, 15, 14, 7);
        step(13, 12, 15, 9);
        step(14, 13, 12, 13);
        step(15, 14, 13, 18);
    }
    for (word, mixed) in block.iter_mut().zip(x) {
        *word = word.wrapping_add(mixed);
    }
}

/// `BlockMix` of section 4 over the 16-word blocks of `input`: the even outputs, then
/// the odd ones.
fn block_mix(input: &[u32], output: &mut [u32]) {
    let half = input.len() / 2;
    let mut mixed = [0; 16];
    mixed.copy_from_slice(&input[input.len() - 16..]);
    for (index, block) in input.as_chunks::<16>().0.iter().enumerate() {
        for (word, other) in mixed.iter_mut().zip(block) {
            *word ^= other;
        }
        salsa20_8(&mut mixed);
        let at = index / 2 * 16 + index % 2 * half;
        output[at..at + 16].copy_from_slice(&mixed);
    }
}

/// `ROMix` of `block`, `128 * r` bytes, with the cost `cost`, a power of 2. It holds
/// `cost` copies of the block, which the caller checks that the VM has room for.
#[must_use]
pub fn romix(block: &[u8], cost: usize) -> Vec<u8> {
    let mut state: Vec<u32> = block
        .as_chunks::<4>()
        .0
        .iter()
        .map(|bytes| u32::from_le_bytes(*bytes))
        .collect();
    let words = state.len();
    let mut next = vec![0; words];
    let mut table = vec![0; words * cost];
    for copy in table.chunks_exact_mut(words) {
        copy.copy_from_slice(&state);
        block_mix(&state, &mut next);
        std::mem::swap(&mut state, &mut next);
    }
    for _ in 0..cost {
        // Integerify: the first word of the last 64-byte block, modulo the cost.
        let index = state[words - 16] as usize & (cost - 1);
        for (word, other) in state
            .iter_mut()
            .zip(&table[index * words..(index + 1) * words])
        {
            *word ^= other;
        }
        block_mix(&state, &mut next);
        std::mem::swap(&mut state, &mut next);
    }
    state.iter().flat_map(|word| word.to_le_bytes()).collect()
}

#[cfg(test)]
mod tests {
    use super::romix;

    fn bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|at| u8::from_str_radix(&hex[at..at + 2], 16).unwrap_or_default())
            .collect()
    }

    /// RFC 7914, section 10: `scryptROMix` with r = 1 and N = 16.
    #[test]
    fn mixes_the_block_of_rfc_7914() {
        let input = bytes(concat!(
            "f7ce0b653d2d72a4108cf5abe912ffdd777616dbbb27a70e8204f3ae2d0f6fad",
            "89f68f4811d1e87bcc3bd7400a9ffd29094f0184639574f39ae5a1315217bcd7",
            "894991447213bb226c25b54da86370fbcd984380374666bb8ffcb5bf40c254b0",
            "67d27c51ce4ad5fed829c90b505a571b7f4d1cad6a523cda770e67bceaaf7e89",
        ));
        let output = bytes(concat!(
            "79ccc193629debca047f0b70604bf6b62ce3dd4a9626e355fafc6198e6ea2b46",
            "d58413673b99b029d665c357601fb426a0b2f4bba200ee9f0a43d19b571a9c71",
            "ef1142e65d5a266fddca832ce59faa7cac0b9cf1be2bffca300d01ee387619c4",
            "ae12fd4438f203a0e4e1c47ec314861f4e9087cb33396a6873e8f9d2539a4b8e",
        ));
        assert_eq!(romix(&input, 16), output);
    }
}
