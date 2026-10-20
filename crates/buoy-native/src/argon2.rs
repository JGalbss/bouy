//! Argon2 of RFC 9106, version 0x13, for the `Argon2Job` of `internalBinding('crypto')`
//! (`src/crypto/crypto_argon2.cc`). Bun derives `crypto.argon2` with the same crate
//! (`src/runtime/node/node_crypto_binding.rs`).

use ::argon2::{Config, ThreadMode, Variant, Version};

/// The inputs of one derivation, as Node's `Argon2Config` holds them.
#[derive(Debug)]
pub struct Params<'a> {
    /// Node's type: 0 for Argon2d, 1 for Argon2i, and 2 for Argon2id.
    pub variant: u32,
    pub message: &'a [u8],
    pub nonce: &'a [u8],
    pub secret: &'a [u8],
    pub associated_data: &'a [u8],
    pub lanes: u32,
    pub tag_length: u32,
    /// KiB.
    pub memory: u32,
    pub passes: u32,
}

/// The tag, or `None` for parameters that Argon2 rejects.
#[must_use]
pub fn derive(params: &Params) -> Option<Vec<u8>> {
    let variant = match params.variant {
        0 => Variant::Argon2d,
        1 => Variant::Argon2i,
        2 => Variant::Argon2id,
        _ => return None,
    };
    let config = Config {
        ad: params.associated_data,
        hash_length: params.tag_length,
        lanes: params.lanes,
        mem_cost: params.memory,
        secret: params.secret,
        // The lanes fix the tag, not the threads.
        thread_mode: ThreadMode::Sequential,
        time_cost: params.passes,
        variant,
        version: Version::Version13,
    };
    ::argon2::hash_raw(params.message, params.nonce, &config).ok()
}

#[cfg(test)]
mod tests {
    use std::fmt::Write;

    use super::{Params, derive};

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().fold(String::new(), |mut text, byte| {
            let _ = write!(text, "{byte:02x}");
            text
        })
    }

    /// RFC 9106, sections 5.1 to 5.3.
    #[test]
    fn derives_the_tags_of_rfc_9106() {
        let tags = [
            "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb",
            "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8",
            "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659",
        ];
        for (variant, tag) in (0..).zip(tags) {
            let params = Params {
                variant,
                message: &[1; 32],
                nonce: &[2; 16],
                secret: &[3; 8],
                associated_data: &[4; 12],
                lanes: 4,
                tag_length: 32,
                memory: 32,
                passes: 3,
            };
            assert_eq!(derive(&params).map(|out| hex(&out)).as_deref(), Some(tag));
        }
    }

    #[test]
    fn rejects_a_short_nonce_and_an_unknown_type() {
        let params = |variant, nonce: &'static [u8]| Params {
            variant,
            message: b"",
            nonce,
            secret: b"",
            associated_data: b"",
            lanes: 1,
            tag_length: 32,
            memory: 8,
            passes: 1,
        };
        assert_eq!(derive(&params(2, b"short")), None);
        assert_eq!(derive(&params(3, b"saltsalt")), None);
        assert!(derive(&params(2, b"saltsalt")).is_some());
    }
}
