%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the codecs of
%% internalBinding('zlib'): each stream is a resource that owns one zlib,
%% brotli, or zstd context (src/node_zlib.cc of Node). A failure is
%% {Message, Errno, Code}, the arguments of a handle's onerror. It also
%% runs Argon2, the Keccak sponge, and the ROMix of scrypt for
%% internalBinding('crypto'), which OTP's crypto lacks.
-module(buoy_native).

-on_load(load/0).

-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).
-export([argon2/9, keccak/5, scrypt_romix/2]).

-export_type([stream/0, failure/0]).

-type stream() :: reference().
-type failure() :: {binary(), integer(), binary()}.

%% A runtime without the library, such as the build of rebar3, still loads
%% the module; its functions then fail with nif_not_loaded.
load() ->
    case code:where_is_file("buoy_native.so") of
        non_existing -> ok;
        Path -> _ = erlang:load_nif(filename:rootname(Path), 0), ok
    end.

%% A zlib stream in the node_zlib_mode Mode (1 to 7).
-spec zlib_open(1..7, integer(), integer(), integer(), integer(), binary()) -> stream().
zlib_open(_Mode, _Level, _WindowBits, _MemLevel, _Strategy, _Dictionary) ->
    erlang:nif_error(nif_not_loaded).

%% A brotli encoder or decoder, with a raw dictionary or <<>>.
-spec brotli_open(boolean(), binary()) -> stream().
brotli_open(_Encode, _Dictionary) -> erlang:nif_error(nif_not_loaded).

%% A zstd compressor with a pledged source size, or -1, or a decompressor.
-spec zstd_open(boolean(), integer(), binary()) -> {ok, stream()} | {error, failure()}.
zstd_open(_Compress, _PledgedSrcSize, _Dictionary) -> erlang:nif_error(nif_not_loaded).

-spec stream_set_parameter(stream(), non_neg_integer(), non_neg_integer()) -> nil | failure().
stream_set_parameter(_Stream, _Key, _Value) -> erlang:nif_error(nif_not_loaded).

%% One write of the input with the flush value Flush into OutLen bytes of
%% room: the bytes written, the input and the room left, and the failure.
-spec stream_write(stream(), non_neg_integer(), binary(), non_neg_integer()) ->
    {binary(), non_neg_integer(), non_neg_integer(), nil | failure()}.
stream_write(_Stream, _Flush, _Input, _OutLen) -> erlang:nif_error(nif_not_loaded).

-spec stream_params(stream(), integer(), integer()) -> nil | failure().
stream_params(_Stream, _Level, _Strategy) -> erlang:nif_error(nif_not_loaded).

-spec stream_reset(stream()) -> nil | failure().
stream_reset(_Stream) -> erlang:nif_error(nif_not_loaded).

-spec stream_close(stream()) -> true.
stream_close(_Stream) -> erlang:nif_error(nif_not_loaded).

%% Argon2 of type 0 (d), 1 (i), or 2 (id), version 0x13, of the message,
%% nonce, secret, and associated data, with Lanes lanes, a tag of TagLen
%% bytes, Memory KiB, and Passes passes: the tag, or error for parameters
%% that Argon2 rejects. It allocates Memory KiB, and a failed allocation
%% aborts the VM, so the caller checks that the memory fits first.
-spec argon2(0..2, binary(), binary(), binary(), binary(), pos_integer(), pos_integer(), pos_integer(),
             pos_integer()) -> binary() | error.
argon2(_Type, _Message, _Nonce, _Secret, _AssociatedData, _Lanes, _TagLen, _Memory, _Passes) ->
    erlang:nif_error(nif_not_loaded).

%% The Keccak sponge of Rounds rounds and Rate bytes: Input absorbed with
%% the domain byte Delimiter and pad10*1, then Length bytes squeezed.
-spec keccak(1..24, pos_integer(), byte(), binary(), non_neg_integer()) -> binary().
keccak(_Rounds, _Rate, _Delimiter, _Input, _Length) -> erlang:nif_error(nif_not_loaded).

%% ROMix of scrypt (RFC 7914) on one block of 128 * r bytes with the cost
%% N, a power of 2. It allocates N blocks, and a failed allocation aborts
%% the VM, so the caller checks that they fit first.
-spec scrypt_romix(binary(), pos_integer()) -> binary().
scrypt_romix(_Block, _Cost) -> erlang:nif_error(nif_not_loaded).
