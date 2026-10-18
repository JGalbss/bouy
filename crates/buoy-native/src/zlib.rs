//! The deflate, inflate, gzip, gunzip, raw, and unzip streams of Node's `ZlibContext`
//! (`src/node_zlib.cc`), on zlib-rs through its zlib C API. The stream initializes zlib on
//! its first write, reset, or params, as Node does, and keeps Node's rules: an unzip
//! stream picks gzip or zlib from the first two bytes, a gunzip stream starts a new member
//! after the end of one, and inflate sets the dictionary when the data asks for it.

use std::ffi::CStr;

use libz_rs_sys as z;

use crate::Failure;

/// `node_zlib_mode`, for the modes of zlib.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Deflate,
    Inflate,
    Gzip,
    Gunzip,
    DeflateRaw,
    InflateRaw,
    Unzip,
}

impl Mode {
    /// The mode of a number of `node_zlib_mode`.
    pub fn from_node(mode: i32) -> Option<Self> {
        Some(match mode {
            1 => Self::Deflate,
            2 => Self::Inflate,
            3 => Self::Gzip,
            4 => Self::Gunzip,
            5 => Self::DeflateRaw,
            6 => Self::InflateRaw,
            7 => Self::Unzip,
            _ => return None,
        })
    }

    fn deflates(self) -> bool {
        matches!(self, Self::Deflate | Self::Gzip | Self::DeflateRaw)
    }
}

const GZIP_HEADER_ID1: u8 = 0x1f;
const GZIP_HEADER_ID2: u8 = 0x8b;

/// One zlib stream.
pub struct Context {
    /// `None` once closed, or after zlib refused the parameters.
    mode: Option<Mode>,
    /// zlib keeps a pointer to the stream in its state, so the stream never moves.
    stream: Box<z::z_stream>,
    initialized: bool,
    err: i32,
    flush: i32,
    level: i32,
    window_bits: i32,
    mem_level: i32,
    strategy: i32,
    dictionary: Vec<u8>,
    gzip_id_bytes_read: u8,
}

// SAFETY: the stream's pointers into input and output buffers live only during one call
// of `write`, which holds the `Mutex` of the resource, and zlib-rs keeps no thread-local
// state.
#[allow(unsafe_code)]
unsafe impl Send for Context {}

impl std::fmt::Debug for Context {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Context")
            .field("mode", &self.mode)
            .finish_non_exhaustive()
    }
}

impl Context {
    pub fn new(mode: Mode) -> Self {
        Self {
            mode: Some(mode),
            stream: Box::default(),
            initialized: false,
            err: z::Z_OK,
            flush: z::Z_NO_FLUSH,
            level: 0,
            window_bits: 0,
            mem_level: 0,
            strategy: 0,
            dictionary: Vec::new(),
            gzip_id_bytes_read: 0,
        }
    }

    /// `ZlibContext::Init`: records the parameters, which lib/zlib.js has checked.
    pub fn init(
        &mut self,
        level: i32,
        window_bits: i32,
        mem_level: i32,
        strategy: i32,
        dictionary: Vec<u8>,
    ) {
        let Some(mode) = self.mode else { return };
        self.level = level;
        self.mem_level = mem_level;
        self.strategy = strategy;
        self.flush = z::Z_NO_FLUSH;
        self.err = z::Z_OK;
        self.window_bits = match mode {
            Mode::Gzip | Mode::Gunzip => window_bits + 16,
            Mode::Unzip => window_bits + 32,
            Mode::DeflateRaw | Mode::InflateRaw => -window_bits,
            Mode::Deflate | Mode::Inflate => window_bits,
        };
        self.dictionary = dictionary;
    }

    /// `ZlibContext::InitZlib`: true on the call that initialized zlib.
    #[allow(unsafe_code)]
    fn init_zlib(&mut self) -> bool {
        if self.initialized {
            return false;
        }
        let Some(mode) = self.mode else { return false };
        let size = i32::try_from(size_of::<z::z_stream>()).unwrap_or(i32::MAX);
        let stream: *mut z::z_stream = &raw mut *self.stream;
        // SAFETY: `stream` is a valid, boxed z_stream that zlib owns from here until
        // `close`, and the version string is zlib-rs's own.
        self.err = unsafe {
            if mode.deflates() {
                z::deflateInit2_(
                    stream,
                    self.level,
                    z::Z_DEFLATED,
                    self.window_bits,
                    self.mem_level,
                    self.strategy,
                    z::zlibVersion(),
                    size,
                )
            } else {
                z::inflateInit2_(stream, self.window_bits, z::zlibVersion(), size)
            }
        };
        if self.err != z::Z_OK {
            self.dictionary.clear();
            self.mode = None;
            return true;
        }
        let _ = self.set_dictionary();
        self.initialized = true;
        true
    }

    /// `ZlibContext::DoThreadPoolWork` on `input` and `output`: the bytes it read and wrote.
    #[allow(unsafe_code)]
    pub fn write(&mut self, flush: i32, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        self.flush = flush;
        self.stream.next_in = input.as_ptr();
        self.stream.avail_in = len32(input);
        self.stream.next_out = output.as_mut_ptr();
        self.stream.avail_out = len32(output);
        self.work(input);
        let read = input.len() - self.stream.avail_in as usize;
        let written = output.len() - self.stream.avail_out as usize;
        self.stream.next_in = std::ptr::null();
        self.stream.next_out = std::ptr::null_mut();
        (read, written)
    }

    #[allow(unsafe_code)]
    fn work(&mut self, input: &[u8]) {
        if self.init_zlib() && self.err != z::Z_OK {
            return;
        }
        let Some(mut mode) = self.mode else { return };
        let stream: *mut z::z_stream = &raw mut *self.stream;
        if mode.deflates() {
            // SAFETY: zlib was initialized for deflate, and `write` set the buffers.
            self.err = unsafe { z::deflate(stream, self.flush) };
            return;
        }
        if mode == Mode::Unzip {
            mode = self.choose_unzip_mode(input);
            self.mode = Some(mode);
        }
        // SAFETY: zlib was initialized for inflate, and `write` set the buffers.
        self.err = unsafe { z::inflate(stream, self.flush) };
        if mode != Mode::InflateRaw && self.err == z::Z_NEED_DICT && !self.dictionary.is_empty() {
            // SAFETY: as above; the dictionary is owned by the context.
            self.err = unsafe {
                z::inflateSetDictionary(stream, self.dictionary.as_ptr(), len32(&self.dictionary))
            };
            if self.err == z::Z_OK {
                // SAFETY: as above.
                self.err = unsafe { z::inflate(stream, self.flush) };
            } else if self.err == z::Z_DATA_ERROR {
                // Both inflateSetDictionary and inflate return Z_DATA_ERROR: this one is a
                // bad dictionary.
                self.err = z::Z_NEED_DICT;
            }
        }
        // Bytes after the end of a gzip member start another member, unless they are
        // zeros, which pad archives.
        while self.stream.avail_in > 0
            && mode == Mode::Gunzip
            && self.err == z::Z_STREAM_END
            && input[input.len() - self.stream.avail_in as usize] != 0
        {
            let _ = self.reset();
            // SAFETY: as above.
            self.err = unsafe { z::inflate(stream, self.flush) };
        }
    }

    /// The unzip mode after the gzip magic bytes that this write and the earlier ones
    /// show: gunzip for both, inflate for any other byte, and unzip while unsure.
    fn choose_unzip_mode(&mut self, input: &[u8]) -> Mode {
        let next = &input[input.len() - self.stream.avail_in as usize..];
        let mut bytes = next.iter();
        if self.gzip_id_bytes_read == 0 {
            match bytes.next() {
                None => return Mode::Unzip,
                Some(&GZIP_HEADER_ID1) => self.gzip_id_bytes_read = 1,
                Some(_) => return Mode::Inflate,
            }
        }
        match bytes.next() {
            None => Mode::Unzip,
            Some(&GZIP_HEADER_ID2) => {
                self.gzip_id_bytes_read = 2;
                Mode::Gunzip
            }
            Some(_) => Mode::Inflate,
        }
    }

    /// `ZlibContext::GetErrorInfo` after a write.
    pub fn failure(&self) -> Option<Failure> {
        match self.err {
            z::Z_OK | z::Z_BUF_ERROR if self.stream.avail_out != 0 && self.flush == z::Z_FINISH => {
                Some(self.error_for_message("unexpected end of file"))
            }
            z::Z_OK | z::Z_BUF_ERROR | z::Z_STREAM_END => None,
            z::Z_NEED_DICT if self.dictionary.is_empty() => {
                Some(self.error_for_message("Missing dictionary"))
            }
            z::Z_NEED_DICT => Some(self.error_for_message("Bad dictionary")),
            _ => Some(self.error_for_message("Zlib error")),
        }
    }

    /// `ZlibContext::ResetStream`.
    #[allow(unsafe_code)]
    pub fn reset(&mut self) -> Result<(), Failure> {
        if self.init_zlib() && self.err != z::Z_OK {
            return Err(self.error_for_message("Failed to init stream before reset"));
        }
        self.err = z::Z_OK;
        let stream: *mut z::z_stream = &raw mut *self.stream;
        // SAFETY: zlib was initialized in the mode that each call expects.
        match self.mode {
            Some(Mode::Deflate | Mode::DeflateRaw | Mode::Gzip) => {
                self.err = unsafe { z::deflateReset(stream) };
            }
            Some(Mode::Inflate | Mode::InflateRaw | Mode::Gunzip) => {
                self.err = unsafe { z::inflateReset(stream) };
            }
            Some(Mode::Unzip) | None => {}
        }
        if self.err != z::Z_OK {
            return Err(self.error_for_message("Failed to reset stream"));
        }
        self.set_dictionary()
    }

    /// `ZlibContext::SetParams`.
    #[allow(unsafe_code)]
    pub fn params(&mut self, level: i32, strategy: i32) -> Result<(), Failure> {
        if self.init_zlib() && self.err != z::Z_OK {
            return Err(self.error_for_message("Failed to init stream before set parameters"));
        }
        self.err = z::Z_OK;
        if let Some(Mode::Deflate | Mode::DeflateRaw) = self.mode {
            // deflateParams compresses the pending input first: it has none, and no room.
            let mut room = [0u8; 0];
            self.stream.next_in = std::ptr::null();
            self.stream.avail_in = 0;
            self.stream.next_out = room.as_mut_ptr();
            self.stream.avail_out = 0;
            // SAFETY: zlib was initialized for deflate, with empty buffers.
            self.err = unsafe { z::deflateParams(&raw mut *self.stream, level, strategy) };
            self.stream.next_out = std::ptr::null_mut();
        }
        if self.err != z::Z_OK && self.err != z::Z_BUF_ERROR {
            return Err(self.error_for_message("Failed to set parameters"));
        }
        Ok(())
    }

    /// `ZlibContext::SetDictionary`.
    #[allow(unsafe_code)]
    fn set_dictionary(&mut self) -> Result<(), Failure> {
        if self.dictionary.is_empty() {
            return Ok(());
        }
        self.err = z::Z_OK;
        let stream: *mut z::z_stream = &raw mut *self.stream;
        let (bytes, length) = (self.dictionary.as_ptr(), len32(&self.dictionary));
        // SAFETY: zlib was initialized in the mode that each call expects, and the
        // dictionary is owned by the context. The other inflate modes set it when
        // inflate asks for it.
        match self.mode {
            Some(Mode::Deflate | Mode::DeflateRaw) => {
                self.err = unsafe { z::deflateSetDictionary(stream, bytes, length) };
            }
            Some(Mode::InflateRaw) => {
                self.err = unsafe { z::inflateSetDictionary(stream, bytes, length) };
            }
            _ => {}
        }
        if self.err != z::Z_OK {
            return Err(self.error_for_message("Failed to set dictionary"));
        }
        Ok(())
    }

    /// `ZlibContext::Close`.
    #[allow(unsafe_code)]
    pub fn close(&mut self) {
        if let (true, Some(mode)) = (self.initialized, self.mode) {
            let stream: *mut z::z_stream = &raw mut *self.stream;
            // SAFETY: zlib was initialized in this mode, and ends here.
            let _ = unsafe {
                if mode.deflates() {
                    z::deflateEnd(stream)
                } else {
                    z::inflateEnd(stream)
                }
            };
        }
        self.initialized = false;
        self.mode = None;
        self.dictionary.clear();
    }

    /// `ZlibContext::ErrorForMessage`: zlib's message, when it has one.
    #[allow(unsafe_code)]
    fn error_for_message(&self, message: &str) -> Failure {
        let message = if self.stream.msg.is_null() {
            message.to_owned()
        } else {
            // SAFETY: zlib-rs sets `msg` to one of its static, NUL-terminated messages.
            unsafe { CStr::from_ptr(self.stream.msg) }
                .to_string_lossy()
                .into_owned()
        };
        Failure {
            message,
            code: error_name(self.err).to_owned(),
            errno: self.err,
        }
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        self.close();
    }
}

/// `ZlibStrerror`.
fn error_name(err: i32) -> &'static str {
    match err {
        z::Z_OK => "Z_OK",
        z::Z_STREAM_END => "Z_STREAM_END",
        z::Z_NEED_DICT => "Z_NEED_DICT",
        z::Z_ERRNO => "Z_ERRNO",
        z::Z_STREAM_ERROR => "Z_STREAM_ERROR",
        z::Z_DATA_ERROR => "Z_DATA_ERROR",
        z::Z_MEM_ERROR => "Z_MEM_ERROR",
        z::Z_BUF_ERROR => "Z_BUF_ERROR",
        z::Z_VERSION_ERROR => "Z_VERSION_ERROR",
        _ => "Z_UNKNOWN_ERROR",
    }
}

/// The length of a buffer that the binding bounds to Node's `uint32_t` lengths.
fn len32(bytes: &[u8]) -> u32 {
    u32::try_from(bytes.len()).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(mode: Mode, flush: i32, input: &[u8]) -> (Vec<u8>, Option<Failure>) {
        let mut context = Context::new(mode);
        context.init(
            -1,
            if mode == Mode::Unzip { 0 } else { 15 },
            8,
            0,
            Vec::new(),
        );
        let mut output = vec![0; 4096];
        let (_, written) = context.write(flush, input, &mut output);
        output.truncate(written);
        (output, context.failure())
    }

    #[test]
    fn gunzip_reads_each_member_and_unzip_detects_gzip() {
        let (member, _) = run(Mode::Gzip, z::Z_FINISH, b"abc");
        let both = [member.as_slice(), member.as_slice()].concat();
        assert_eq!(run(Mode::Gunzip, z::Z_FINISH, &both).0, b"abcabc");
        assert_eq!(run(Mode::Unzip, z::Z_FINISH, &both).0, b"abcabc");
    }

    #[test]
    fn bad_input_fails_with_the_message_of_zlib() {
        let failure = run(Mode::Inflate, z::Z_FINISH, b"not zlib")
            .1
            .expect("an error");
        assert_eq!(
            (
                failure.message.as_str(),
                failure.code.as_str(),
                failure.errno
            ),
            ("incorrect header check", "Z_DATA_ERROR", z::Z_DATA_ERROR)
        );
        let (deflated, _) = run(Mode::Deflate, z::Z_FINISH, b"abc");
        let failure = run(Mode::Inflate, z::Z_FINISH, &deflated[..4])
            .1
            .expect("an error");
        assert_eq!(failure.message, "unexpected end of file");
    }
}
