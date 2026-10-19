%% The NIF library of crates/buoy-native, which the CLI writes next to the
%% runtime's .beam files as buoy_native.so. It holds the fs calls that
%% prim_file lacks, which fail with a negative errno as a libuv request
%% does, and the codecs of
%% internalBinding('zlib'): each stream is a resource that owns one zlib,
%% brotli, or zstd context (src/node_zlib.cc of Node). A failure is
%% {Message, Errno, Code}, the arguments of a handle's onerror.
-module(buoy_native).

-on_load(load/0).

-export([zlib_open/6, brotli_open/2, zstd_open/3]).
-export([stream_set_parameter/3, stream_write/4, stream_params/3, stream_reset/1, stream_close/1]).
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
