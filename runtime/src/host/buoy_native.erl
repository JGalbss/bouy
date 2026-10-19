%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the CLDR data of Intl
%% (ICU4X, for buoy_ref_intl), the fs calls that prim_file lacks, which fail
%% with a negative errno as a libuv request does, and the codecs of
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
-export([intl_canonicalize/1, intl_maximize/1, intl_minimize/1, intl_is_right_to_left/1]).
-export([intl_collator_new/3, intl_collator_compare/3, intl_collation_types/1, intl_change_case/3]).
-export([intl_calendar_date/2]).
-export([intl_compact_exponent/3, intl_cldr/0, intl_segment/3]).
-export([fs_stat/2, fs_fstat/1, fs_readdir/1, fs_utimes/4, fs_futimes/3, fs_chmod/3, fs_fchmod/2, fs_chown/4, fs_fchown/3,
         fs_access/2, fs_statfs/1, fs_watch/1, fs_unwatch/1]).

-export_type([stream/0, failure/0]).

-type stream() :: reference().
-type failure() :: {binary(), integer(), binary()}.
%% 0, or the negative errno of the OS.
-type status() :: integer().
%% A time in seconds, 'NaN' to keep the time, or an infinity for now.
-type time() :: number() | 'NaN' | 'Infinity' | '-Infinity'.

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

%% The date in a calendar of CLDR of a day after 1970-01-01: {Year, Cyclic,
%% OrdinalMonth, MonthNumber, Leap, Day}, with the related ISO year and the
%% year of the 60-year cycle of a cyclic calendar, else the extended year and
%% 0, or nil for an unknown calendar.
-spec intl_calendar_date(binary(), integer()) ->
          {integer(), 0..60, pos_integer(), pos_integer(), boolean(), pos_integer()} | nil.
intl_calendar_date(_Calendar, _EpochDays) -> erlang:nif_error(nif_not_loaded).

%% ComputeExponentForMagnitude in compact notation: the power of ten by
%% which the locale scales a number of the magnitude, short or long.
-spec intl_compact_exponent(binary(), boolean(), integer()) -> non_neg_integer().
intl_compact_exponent(_Tag, _Long, _Magnitude) -> erlang:nif_error(nif_not_loaded).

%% The locale data of scripts/intl-icu.escript, in the external term
%% format (buoy_intl_cldr).
-spec intl_cldr() -> binary().
intl_cldr() -> erlang:nif_error(nif_not_loaded).

%% The boundaries of a big-endian UTF-16 binary in a locale, by grapheme,
%% word, or sentence, as {Index, IsWordLike} from 0 to its length.
-spec intl_segment(grapheme | word | sentence, binary(), binary()) -> [{non_neg_integer(), boolean()}].
intl_segment(_Granularity, _Tag, _Text) -> erlang:nif_error(nif_not_loaded).
%% Node's stat fields (src/node_file.h): dev, mode, nlink, uid, gid, rdev,
%% blksize, ino, size, blocks, and the seconds and nanoseconds of atime,
%% mtime, ctime, and birthtime. Follow is false for lstat.
-spec fs_stat(binary(), boolean()) -> {ok, [integer()]} | {error, status()}.
fs_stat(_Path, _Follow) -> erlang:nif_error(nif_not_loaded).

-spec fs_fstat(integer()) -> {ok, [integer()]} | {error, status()}.
fs_fstat(_Fd) -> erlang:nif_error(nif_not_loaded).

%% The names of a directory's entries, in its order, with their UV_DIRENT_*
%% types (src/uv.h).
-spec fs_readdir(binary()) -> {ok, [{binary(), 0..7}]} | {error, status()}.
fs_readdir(_Path) -> erlang:nif_error(nif_not_loaded).

%% Follow is false for lutimes.
-spec fs_utimes(binary(), time(), time(), boolean()) -> status().
fs_utimes(_Path, _Atime, _Mtime, _Follow) -> erlang:nif_error(nif_not_loaded).

-spec fs_futimes(integer(), time(), time()) -> status().
fs_futimes(_Fd, _Atime, _Mtime) -> erlang:nif_error(nif_not_loaded).

%% Follow is false for lchmod.
-spec fs_chmod(binary(), non_neg_integer(), boolean()) -> status().
fs_chmod(_Path, _Mode, _Follow) -> erlang:nif_error(nif_not_loaded).

-spec fs_fchmod(integer(), non_neg_integer()) -> status().
fs_fchmod(_Fd, _Mode) -> erlang:nif_error(nif_not_loaded).

%% -1 keeps the owner or the group. Follow is false for lchown.
-spec fs_chown(binary(), integer(), integer(), boolean()) -> status().
fs_chown(_Path, _Uid, _Gid, _Follow) -> erlang:nif_error(nif_not_loaded).

-spec fs_fchown(integer(), integer(), integer()) -> status().
fs_fchown(_Fd, _Uid, _Gid) -> erlang:nif_error(nif_not_loaded).

%% access(2) with the bits of R_OK, W_OK, and X_OK.
-spec fs_access(binary(), non_neg_integer()) -> status().
fs_access(_Path, _Mode) -> erlang:nif_error(nif_not_loaded).

%% type, bsize, blocks, bfree, bavail, files, and ffree.
-spec fs_statfs(binary()) -> {ok, [integer()]} | {error, status()}.
fs_statfs(_Path) -> erlang:nif_error(nif_not_loaded).

%% Linux: an inotify watch of the path for the calling process, which then
%% receives {'$buoy_fs_event', Mask, Name | nil} for each event of it.
-spec fs_watch(binary()) -> {ok, integer()} | {error, status()}.
fs_watch(_Path) -> erlang:nif_error(nif_not_loaded).

%% Linux: ends the watch of the calling process.
-spec fs_unwatch(integer()) -> boolean().
fs_unwatch(_Wd) -> erlang:nif_error(nif_not_loaded).
