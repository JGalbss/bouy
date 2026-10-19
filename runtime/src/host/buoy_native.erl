%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the codecs of
%% internalBinding('zlib'): each stream is a resource that owns one zlib,
%% brotli, or zstd context (src/node_zlib.cc of Node). A failure is
%% {Message, Errno, Code}, the arguments of a handle's onerror.
-module(buoy_native).

-on_load(load/0).

-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).
-export([sigint_handle/1, sigint_default/0, os_kill/2]).

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

%% Sends each SIGINT that the VM gets to Target as {notify, sigint}, which
%% OTP's os:set_signal/2 cannot catch. False when the pipe cannot open.
-spec sigint_handle(pid()) -> boolean().
sigint_handle(_Target) -> erlang:nif_error(nif_not_loaded).

%% Gives SIGINT back its disposition from before sigint_handle/1.
-spec sigint_default() -> boolean().
sigint_default() -> erlang:nif_error(nif_not_loaded).

%% kill(2) of the OS process Pid: 0, or the negative errno.
-spec os_kill(integer(), integer()) -> integer().
os_kill(_Pid, _Signal) -> erlang:nif_error(nif_not_loaded).
