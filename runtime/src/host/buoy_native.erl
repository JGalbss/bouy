%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the CLDR data of Intl
%% (ICU4X, for buoy_ref_intl), and the codecs of internalBinding('zlib'):
%% each stream is a resource that owns one zlib, brotli, or zstd context
%% (src/node_zlib.cc of Node). A failure is {Message, Errno, Code}, the
%% arguments of a handle's onerror.
-module(buoy_native).

-on_load(load/0).

-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).
-export([intl_canonicalize/1, intl_maximize/1, intl_minimize/1, intl_is_right_to_left/1]).
-export([intl_collator_new/3, intl_collator_compare/3, intl_collation_types/1, intl_change_case/3]).
-export([intl_calendar_date/2]).
-export([intl_compact_exponent/3]).

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

%%% Intl

%% The canonical form of a Unicode locale identifier, with the aliases of its
%% language, script, region, and variants replaced, or nil for a tag that is
%% not structurally valid.
-spec intl_canonicalize(binary()) -> binary() | nil.
intl_canonicalize(_Tag) -> erlang:nif_error(nif_not_loaded).

%% The tag with its likely subtags added.
-spec intl_maximize(binary()) -> binary() | nil.
intl_maximize(_Tag) -> erlang:nif_error(nif_not_loaded).

%% The tag without the subtags that intl_maximize/1 adds back.
-spec intl_minimize(binary()) -> binary() | nil.
intl_minimize(_Tag) -> erlang:nif_error(nif_not_loaded).

%% Whether the locale writes right to left, or nil when its script has no
%% direction.
-spec intl_is_right_to_left(binary()) -> boolean() | nil.
intl_is_right_to_left(_Tag) -> erlang:nif_error(nif_not_loaded).

%% An Intl.Collator of ICU4X for a locale tag whose -u- keywords co, kf, and kn
%% choose the collation, with a sensitivity of ECMA-402, or nil.
-spec intl_collator_new(binary(), base | accent | 'case' | variant, boolean()) -> reference() | nil.
intl_collator_new(_Tag, _Sensitivity, _IgnorePunctuation) -> erlang:nif_error(nif_not_loaded).

%% CompareStrings of two big-endian UTF-16 binaries: -1, 0, or 1.
-spec intl_collator_compare(reference(), binary(), binary()) -> -1 | 0 | 1.
intl_collator_compare(_Collator, _Left, _Right) -> erlang:nif_error(nif_not_loaded).

%% The collation types that ICU4X has for a locale or its fallbacks.
-spec intl_collation_types(binary()) -> [binary()].
intl_collation_types(_Tag) -> erlang:nif_error(nif_not_loaded).

%% toLocaleLowerCase (false) or toLocaleUpperCase (true) of a big-endian
%% UTF-16 binary in the case tailoring of a language.
-spec intl_change_case(binary(), binary(), boolean()) -> binary().
intl_change_case(_Language, _Text, _Upper) -> erlang:nif_error(nif_not_loaded).

%% The date in a calendar of CLDR of a day after 1970-01-01: {Year,
%% OrdinalMonth, MonthNumber, Leap, Day}, with the related ISO year of a
%% cyclic calendar, or nil for an unknown calendar.
-spec intl_calendar_date(binary(), integer()) ->
          {integer(), pos_integer(), pos_integer(), boolean(), pos_integer()} | nil.
intl_calendar_date(_Calendar, _EpochDays) -> erlang:nif_error(nif_not_loaded).

%% ComputeExponentForMagnitude in compact notation: the power of ten by
%% which the locale scales a number of the magnitude, short or long.
-spec intl_compact_exponent(binary(), boolean(), integer()) -> non_neg_integer().
intl_compact_exponent(_Tag, _Long, _Magnitude) -> erlang:nif_error(nif_not_loaded).
