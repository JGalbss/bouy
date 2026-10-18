%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the codecs of
%% internalBinding('zlib'): each stream is a resource that owns one zlib,
%% brotli, or zstd context (src/node_zlib.cc of Node). A failure is
%% {Message, Errno, Code}, the arguments of a handle's onerror.
%%
%% It also holds WebAssembly on Wasmtime for buoy_ref_wasm: a compiled
%% module, and a store for each process, which runs a command in slices of
%% about a millisecond (crates/buoy-native/src/wasm.rs).
-module(buoy_native).

-on_load(load/0).

-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).

-export([wasm_store/1, wasm_compile/1, wasm_validate/1, wasm_imports/1, wasm_exports/1, wasm_command/2, wasm_poll/1]).

-export_type([stream/0, failure/0, wasm_module/0, wasm_store/0]).

-type stream() :: reference().
-type failure() :: {binary(), integer(), binary()}.
-type wasm_module() :: reference().
-type wasm_store() :: reference().

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

%% A new WebAssembly store for the calling process, with the limit in bytes
%% on the linear memory of every store of the VM.
-spec wasm_store(pos_integer()) -> wasm_store().
wasm_store(_Limit) -> erlang:nif_error(nif_not_loaded).

-spec wasm_compile(binary()) -> {ok, wasm_module()} | {error, binary()}.
wasm_compile(_Bytes) -> erlang:nif_error(nif_not_loaded).

-spec wasm_validate(binary()) -> boolean().
wasm_validate(_Bytes) -> erlang:nif_error(nif_not_loaded).

%% [{Module, Name, Type}], where Type is the extern type of wasm.rs with the
%% handle none.
-spec wasm_imports(wasm_module()) -> [{binary(), binary(), tuple()}].
wasm_imports(_Module) -> erlang:nif_error(nif_not_loaded).

-spec wasm_exports(wasm_module()) -> [{binary(), tuple()}].
wasm_exports(_Module) -> erlang:nif_error(nif_not_loaded).

%% Sends a command to the store and runs it for one slice: {done, Reply,
%% Grown}, {call, Id, Args, ResultTypes, Grown} for a call of an import, or
%% yield when the slice ended first.
-spec wasm_command(wasm_store(), tuple()) -> term().
wasm_command(_Store, _Command) -> erlang:nif_error(nif_not_loaded).

%% Runs the command in flight for one more slice.
-spec wasm_poll(wasm_store()) -> term().
wasm_poll(_Store) -> erlang:nif_error(nif_not_loaded).
