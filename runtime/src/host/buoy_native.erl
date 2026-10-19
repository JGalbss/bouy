%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the codecs of
%% internalBinding('zlib'): each stream is a resource that owns one zlib,
%% brotli, or zstd context (src/node_zlib.cc of Node). A failure is
%% {Message, Errno, Code}, the arguments of a handle's onerror.
%%
%% It also holds the native built-ins of section 17.10 of the contract. Each
%% runs in time slices and returns a continuation when its slice ends, so its
%% caller loops until it is done. They are an accelerator: when the library is
%% missing, available/0 is false and each caller runs its Erlang
%% implementation, which has the same results.
-module(buoy_native).

-on_load(load/0).

-export([available/0, json_parse/5, regexp_compile/3, regexp_search/6, regexp_search_all/5]).
-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).

-export_type([stream/0, failure/0]).

-type stream() :: reference().
-type failure() :: {binary(), integer(), binary()}.

%% A runtime without the library, such as the build of rebar3, still loads
%% the module; its functions then fail with nif_not_loaded.
load() ->
    Loaded =
        case code:where_is_file("buoy_native.so") of
            non_existing -> false;
            Path -> erlang:load_nif(filename:rootname(Path), 0) =:= ok
        end,
    persistent_term:put(?MODULE, Loaded),
    ok.

%% Whether the library is loaded.
-spec available() -> boolean().
available() -> persistent_term:get(?MODULE, false).

%% JSON.parse without a reviver (crates/buoy-native/src/json.rs).
-spec json_parse(binary(), boolean(), {term(), term()}, pos_integer(), start | reference()) ->
          {done, term(), [pos_integer()], [tuple()], pos_integer()}
        | {more, reference(), [pos_integer()], [tuple()], pos_integer()}
        | error.
json_parse(_Text, _Wide, _Protos, _Next, _State) -> erlang:nif_error(nif_not_loaded).

%% The program of a regular expression from the tree of buoy_regexp_match:lower/2, its
%% count of groups, and whether it reads code points (crates/buoy-native/src/regexp.rs).
-spec regexp_compile(term(), non_neg_integer(), boolean()) -> {ok, reference()} | error.
regexp_compile(_Tree, _Groups, _Unicode) -> erlang:nif_error(nif_not_loaded).

%% buoy_regexp_match:search/4 with a program of regexp_compile/3, on the code units of a
%% string, two bytes each when Wide. State is start or the state of a more result.
-spec regexp_search(reference(), binary(), boolean(), non_neg_integer(), boolean(), start | reference()) ->
          {match, non_neg_integer(), non_neg_integer(), tuple()} | nomatch | {more, reference()} | overflow.
regexp_search(_Program, _Text, _Wide, _From, _Sticky, _State) -> erlang:nif_error(nif_not_loaded).

%% buoy_regexp_match:search_all/3 with a program of regexp_compile/3: each slice gives the
%% matches that it found.
-spec regexp_search_all(reference(), binary(), boolean(), boolean(), start | reference()) ->
          {done, [{match, non_neg_integer(), non_neg_integer(), tuple()}]}
        | {more, reference(), [{match, non_neg_integer(), non_neg_integer(), tuple()}]}
        | overflow.
regexp_search_all(_Program, _Text, _Wide, _Sticky, _State) -> erlang:nif_error(nif_not_loaded).

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
