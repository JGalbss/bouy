//! The Keccak sponge for the functions of `internalBinding('crypto')` that OTP's crypto
//! lacks: `TurboSHAKE` and `KangarooTwelve` (RFC 9861, `src/crypto/crypto_turboshake.cc`),
//! and `cSHAKE` and KMAC (NIST SP 800-185). Erlang builds their inputs; the permutation
//! runs here.

/// The round constants of Keccak-f[1600].
const ROUND_CONSTANTS: [u64; 24] = [
    0x0000_0000_0000_0001,
    0x0000_0000_0000_8082,
    0x8000_0000_0000_808a,
    0x8000_0000_8000_8000,
    0x0000_0000_0000_808b,
    0x0000_0000_8000_0001,
    0x8000_0000_8000_8081,
    0x8000_0000_0000_8009,
    0x0000_0000_0000_008a,
    0x0000_0000_0000_0088,
    0x0000_0000_8000_8009,
    0x0000_0000_8000_000a,
    0x0000_0000_8000_808b,
    0x8000_0000_0000_008b,
    0x8000_0000_0000_8089,
    0x8000_0000_0000_8003,
    0x8000_0000_0000_8002,
    0x8000_0000_0000_0080,
    0x0000_0000_0000_800a,
    0x8000_0000_8000_000a,
    0x8000_0000_8000_8081,
    0x8000_0000_0000_8080,
    0x0000_0000_8000_0001,
    0x8000_0000_8000_8008,
];

/// The rotation of rho for each step of the pi walk, which starts at lane 1.
const RHO: [u32; 24] = [
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
];
const PI: [usize; 24] = [
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
];

/// Keccak-p[1600, rounds]: the last `rounds` rounds of Keccak-f[1600].
fn permute(lanes: &mut [u64; 25], rounds: usize) {
    for constant in &ROUND_CONSTANTS[24 - rounds..] {
        let mut columns = [0; 5];
        for (x, column) in columns.iter_mut().enumerate() {
            *column = lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20];
        }
        for x in 0..5 {
            let d = columns[(x + 4) % 5] ^ columns[(x + 1) % 5].rotate_left(1);
            for y in (0..25).step_by(5) {
                lanes[y + x] ^= d;
            }
        }
        let mut carried = lanes[1];
        for (&to, &rotation) in PI.iter().zip(&RHO) {
            let next = lanes[to];
            lanes[to] = carried.rotate_left(rotation);
            carried = next;
        }
        for y in (0..25).step_by(5) {
            let row = [
                lanes[y],
                lanes[y + 1],
                lanes[y + 2],
                lanes[y + 3],
                lanes[y + 4],
            ];
            for x in 0..5 {
                lanes[y + x] = row[x] ^ (!row[(x + 1) % 5] & row[(x + 2) % 5]);
            }
        }
        lanes[0] ^= constant;
    }
}

fn absorb_block(lanes: &mut [u64; 25], block: &[u8]) {
    for (lane, word) in lanes.iter_mut().zip(block.as_chunks::<8>().0) {
        *lane ^= u64::from_le_bytes(*word);
    }
}

/// The sponge of `rounds` rounds and `rate` bytes (a multiple of 8, below 200): `input`
/// absorbed with the domain byte `delimiter` and pad10*1, then `length` bytes squeezed.
#[must_use]
pub fn sponge(rounds: usize, rate: usize, delimiter: u8, input: &[u8], length: usize) -> Vec<u8> {
    let mut lanes = [0; 25];
    let mut blocks = input.chunks_exact(rate);
    for block in &mut blocks {
        absorb_block(&mut lanes, block);
        permute(&mut lanes, rounds);
    }
    let rest = blocks.remainder();
    let mut last = vec![0; rate];
    last[..rest.len()].copy_from_slice(rest);
    last[rest.len()] ^= delimiter;
    last[rate - 1] ^= 0x80;
    absorb_block(&mut lanes, &last);
    permute(&mut lanes, rounds);
    let mut output = Vec::with_capacity(length + rate);
    loop {
        output.extend(lanes[..rate / 8].iter().flat_map(|lane| lane.to_le_bytes()));
        if output.len() >= length {
            output.truncate(length);
            return output;
        }
        permute(&mut lanes, rounds);
    }
}

#[cfg(test)]
mod tests {
    use std::fmt::Write;

    use super::sponge;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().fold(String::new(), |mut text, byte| {
            let _ = write!(text, "{byte:02x}");
            text
        })
    }

    #[test]
    fn hashes_the_empty_message_as_sha3_and_shake() {
        assert_eq!(
            hex(&sponge(24, 136, 0x06, b"", 32)),
            "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
        );
        assert_eq!(
            hex(&sponge(24, 168, 0x1f, b"", 32)),
            "7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26"
        );
    }

    /// RFC 9861, section 5: `TurboSHAKE128` of M = `ptn(17)` and of the empty message
    /// with 64 bytes out, where the second block of output needs a second squeeze.
    #[test]
    fn derives_the_turboshake128_vectors_of_rfc_9861() {
        let pattern: Vec<u8> = (0..17u8).collect();
        assert_eq!(
            hex(&sponge(12, 168, 0x1f, &pattern, 32)),
            "9c97d036a3bac819db70ede0ca554ec6e4c2a1a4ffbfd9ec269ca6a111161233"
        );
        let long = sponge(12, 168, 0x1f, b"", 10032);
        assert_eq!(
            hex(&long[10000..]),
            "a3b9b0385900ce761f22aed548e754da10a5242d62e8c658e3f3a923a7555607"
        );
    }
}
