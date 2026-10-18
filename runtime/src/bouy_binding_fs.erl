%% internalBinding('fs') (src/node_file.cc): the file system calls of
%% lib/fs on Erlang's file module.
%%
%% A call without a request runs now and throws Node's uvException; a call
%% with an FSReqCallback runs now and calls req.oncomplete in a later
%% macrotask (bouy_node_loop:defer/1), as libuv calls back from its thread
%% pool. A file descriptor is a number that maps to a raw Erlang file in the
%% realm; 0, 1, and 2 are the standard streams of the VM.
%%
%% shortcut: the binding covers the calls that lib/fs makes for the common
%% sync and callback APIs; the promise API (FileHandle), watchers, and
%% statfs throw ERR_BOUY_NOT_IMPLEMENTED until the fs module needs them.
-module(bouy_binding_fs).

-include_lib("kernel/include/file.hrl").
-include("bouy_ref.hrl").

-compile({no_auto_import, [link/1, unlink/1]}).

-export([binding/0, uv_error/3, uv_error/4]).

-define(FDS, '$bouy_node_fds').
-define(NEXT_FD, '$bouy_node_next_fd').
-define(STAT_FIELDS, 18).
%% The open flags of darwin, as the constants binding reports them.
-define(O_WRONLY, 1).
-define(O_RDWR, 2).
-define(O_APPEND, 8).
-define(O_CREAT, 512).
-define(O_TRUNC, 1024).
-define(O_EXCL, 2048).

-spec binding() -> term().
binding() ->
    Stats = bouy_node:typed_array(<<"Float64Array">>, 2 * ?STAT_FIELDS),
    BigStats = bouy_node:typed_array(<<"BigInt64Array">>, 2 * ?STAT_FIELDS),
    erlang:put({?MODULE, stats}, {Stats, BigStats}),
    Req = bouy_node:constructor(<<"FSReqCallback">>, 1, fun(This, Args) ->
        bouy_heap:set(This, <<"bigint">>, bouy_ref:truthy(bouy_node:arg(1, Args))),
        undefined
    end),
    Calls = [
        {<<"access">>, 3, fun access/1}, {<<"close">>, 2, fun close/1}, {<<"open">>, 4, fun open/1},
        {<<"read">>, 6, fun read/1}, {<<"readFileUtf8">>, 2, fun read_file_utf8/1},
        {<<"writeBuffer">>, 6, fun write_buffer/1}, {<<"writeString">>, 5, fun write_string/1},
        {<<"writeFileUtf8">>, 4, fun write_file_utf8/1}, {<<"stat">>, 3, fun stat/1}, {<<"lstat">>, 3, fun lstat/1},
        {<<"fstat">>, 3, fun fstat/1}, {<<"mkdir">>, 4, fun mkdir/1}, {<<"rmdir">>, 2, fun rmdir/1},
        {<<"unlink">>, 2, fun unlink/1}, {<<"rename">>, 3, fun rename/1}, {<<"readdir">>, 4, fun readdir/1},
        {<<"readlink">>, 3, fun readlink/1}, {<<"symlink">>, 4, fun symlink/1}, {<<"link">>, 3, fun link/1},
        {<<"realpath">>, 3, fun realpath/1}, {<<"copyFile">>, 4, fun copy_file/1}, {<<"chmod">>, 3, fun chmod/1},
        {<<"fchmod">>, 3, fun fchmod/1}, {<<"utimes">>, 4, fun utimes/1}, {<<"futimes">>, 4, fun futimes/1},
        {<<"lutimes">>, 4, fun utimes/1}, {<<"ftruncate">>, 3, fun ftruncate/1}, {<<"fsync">>, 2, fun fsync/1},
        {<<"fdatasync">>, 2, fun fsync/1}, {<<"mkdtemp">>, 3, fun mkdtemp/1}, {<<"chown">>, 4, fun noop/1},
        {<<"fchown">>, 4, fun noop/1}, {<<"lchown">>, 4, fun noop/1}],
    bouy_node:object(
        [{Name, bouy_node:fn(Name, Length, fun(_, Args) -> call(Name, Args, Length, Fun) end)} || {Name, Length, Fun} <- Calls]
        ++ [{<<"existsSync">>, bouy_node:fn(<<"existsSync">>, 1, fun(_, Args) -> exists(bouy_node:arg(1, Args)) end)},
            {<<"internalModuleStat">>, bouy_node:fn(<<"internalModuleStat">>, 1, fun(_, Args) -> module_stat(Args) end)},
            {<<"rmSync">>, bouy_node:fn(<<"rmSync">>, 4, fun(_, Args) -> rm_sync(Args) end)},
            {<<"getFormatOfExtensionlessFile">>, bouy_node:fn(<<"getFormatOfExtensionlessFile">>, 1, fun(_, _) -> 0 end)},
            {<<"FSReqCallback">>, Req},
            {<<"kFsStatsFieldsNumber">>, ?STAT_FIELDS},
            {<<"kUsePromises">>, bouy_node:symbol(<<"fs_use_promises_symbol">>)},
            {<<"statValues">>, Stats},
            {<<"bigintStatValues">>, BigStats},
            {<<"statFsValues">>, bouy_node:typed_array(<<"Float64Array">>, 7)},
            {<<"bigintStatFsValues">>, bouy_node:typed_array(<<"BigInt64Array">>, 7)},
            {<<"FileHandle">>, bouy_node:missing_constructor(<<"fs">>, <<"FileHandle">>, 1)},
            {<<"StatWatcher">>, bouy_node:missing_constructor(<<"fs">>, <<"StatWatcher">>, 1)}]
        ++ bouy_node:stubs(<<"fs">>, [<<"openFileHandle">>, <<"readBuffers">>, <<"writeBuffers">>, <<"statfs">>,
                                     <<"legacyMainResolve">>, <<"cpSyncCheckPaths">>, <<"cpSyncOverrideFile">>,
                                     <<"cpSyncCopyDir">>])).

-spec missing(binary()) -> no_return().
missing(Name) ->
    bouy_node:throw_code('Error', <<"ERR_BOUY_NOT_IMPLEMENTED">>, <<"internalBinding('fs').", Name/binary, " is not implemented on Bouy">>).

%% The request argument is at position Length, the last but for stat, lstat,
%% and fstat, whose last says whether a missing file throws: a
%% request object runs the call as a callback, kUsePromises is not
%% implemented, and undefined runs it now.
call(<<"read">>, [0, Buffer, Offset, Length, _Position, Req | _], 6, _Fun) when ?IS_OBJECT(Req) ->
    read_stdin_async(Req, Buffer, trunc(bouy_ref:to_number(Offset)), trunc(bouy_ref:to_number(Length)));
call(Name, Args, Length, Fun) ->
    case bouy_node:arg(Length, Args) of
        undefined ->
            Fun(Args);
        Req when ?IS_OBJECT(Req) ->
            Outcome = try {ok, Fun(Args)}
                      catch error:{'$throw', Thrown} -> {error, Thrown}
                      end,
            bouy_node_loop:defer(fun() ->
                OnComplete = bouy_heap:get(Req, <<"oncomplete">>),
                case Outcome of
                    {ok, undefined} -> bouy_heap:call(OnComplete, Req, [null]);
                    {ok, Value} -> bouy_heap:call(OnComplete, Req, [null, Value]);
                    {error, E} -> bouy_heap:call(OnComplete, Req, [E])
                end
            end),
            undefined;
        _ ->
            missing(<<Name/binary, " with kUsePromises">>)
    end.

noop(_Args) -> undefined.

%%% Paths and errors

path(V) when ?IS_STRING(V) -> bouy_ref_string:to_utf8(V);
path(V) when ?IS_OBJECT(V) -> bouy_node_encoding:view_bytes(V);
path(V) -> bouy_ref_string:to_utf8(bouy_ref:to_string(V)).

-spec uv_error(atom(), binary(), binary()) -> no_return().
uv_error(Reason, Syscall, Path) -> uv_error(Reason, Syscall, Path, undefined).

%% Node's uvException: "<CODE>: <message>, <syscall> '<path>' -> '<dest>'",
%% with errno, code, syscall, path, and dest.
-spec uv_error(atom(), binary(), binary() | undefined, binary() | undefined) -> no_return().
uv_error(Reason, Syscall, Path, Dest) ->
    Code = string:uppercase(atom_to_binary(Reason)),
    {Errno, Message} = case [{N, M} || {N, Name, M} <- bouy_binding_uv:errors(), Name =:= Code] of
        [Found | _] -> Found;
        [] -> {-1, atom_to_binary(Reason)}
    end,
    Text = iolist_to_binary([Code, <<": ">>, Message, <<", ">>, Syscall,
                             case Path of undefined -> <<>>; _ -> [<<" '">>, Path, <<"'">>] end,
                             case Dest of undefined -> <<>>; _ -> [<<" -> '">>, Dest, <<"'">>] end]),
    Js = bouy_ref_string:from_utf8(Text),
    E = bouy_heap:error_object('Error', Js, bouy_ref_string:concat(<<"Error: ">>, Js)),
    Props = [{<<"errno">>, Errno}, {<<"code">>, bouy_ref_string:from_utf8(Code)}, {<<"syscall">>, Syscall}]
            ++ [{<<"path">>, bouy_ref_string:from_utf8(Path)} || Path =/= undefined]
            ++ [{<<"dest">>, bouy_ref_string:from_utf8(Dest)} || Dest =/= undefined],
    [bouy_heap:define(E, K, #{value => V, writable => true, enumerable => true, configurable => true}) || {K, V} <- Props],
    erlang:error({'$throw', E}).

check({error, Reason}, Syscall, Path) -> uv_error(Reason, Syscall, Path);
check({ok, Value}, _Syscall, _Path) -> Value;
check(ok, _Syscall, _Path) -> ok.

%%% File descriptors

fds() ->
    case erlang:get(?FDS) of
        undefined -> #{};
        Fds -> Fds
    end.

file(Fd, Syscall) ->
    case fds() of
        #{Fd := File} -> File;
        _ -> uv_error(ebadf, Syscall, undefined)
    end.

fd(V) -> trunc(bouy_ref:to_number(V)).

open(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    Flags = trunc(bouy_ref:to_number(bouy_node:arg(2, Args))),
    Access = case Flags band 3 of
        0 -> [read];
        ?O_WRONLY -> [write];
        _ -> [read, write]
    end,
    Exists = filelib:is_file(Path),
    Flags band ?O_CREAT =:= 0 andalso not Exists andalso uv_error(enoent, <<"open">>, Path),
    Flags band ?O_CREAT =/= 0 andalso Flags band ?O_EXCL =/= 0 andalso Exists andalso uv_error(eexist, <<"open">>, Path),
    filelib:is_dir(Path) andalso Access =/= [read] andalso uv_error(eisdir, <<"open">>, Path),
    Modes = case Flags band ?O_APPEND of
        0 -> Access;
        _ -> [append | Access -- [write]]
    end,
    %% Erlang truncates a file opened for write only; read and write keeps it.
    Truncate = Flags band ?O_TRUNC =/= 0,
    Handle = case filelib:is_dir(Path) of
        true -> {dir, Path};
        false ->
            Opened = check(file:open(Path, [raw, binary | keep_or_truncate(Modes, Truncate)]), <<"open">>, Path),
            Truncate andalso lists:member(read, Modes) andalso file:truncate(Opened),
            Opened
    end,
    Fd = case erlang:get(?NEXT_FD) of
        undefined -> 3;
        N -> N
    end,
    erlang:put(?NEXT_FD, Fd + 1),
    erlang:put(?FDS, (fds())#{Fd => {Handle, Path}}),
    Fd.

keep_or_truncate(Modes, true) -> Modes;
keep_or_truncate([write], false) -> [read, write];
keep_or_truncate(Modes, false) -> Modes.

close(Args) ->
    Fd = fd(bouy_node:arg(1, Args)),
    case fds() of
        #{Fd := {Handle, _}} ->
            erlang:put(?FDS, maps:remove(Fd, fds())),
            case Handle of
                {dir, _} -> ok;
                _ -> file:close(Handle)
            end,
            undefined;
        _ when Fd >= 0, Fd =< 2 ->
            undefined;
        _ ->
            uv_error(ebadf, <<"close">>, undefined)
    end.

%% read(fd, buffer, offset, length, position): the bytes read into buffer.
read(Args) ->
    [Fd0, Buffer, Offset, Length, Position] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Fd = fd(Fd0),
    Count = trunc(bouy_ref:to_number(Length)),
    At = trunc(bouy_ref:to_number(Offset)),
    Data = case Fd of
        0 -> read_stdin(Count);
        _ ->
            {Handle, Path} = file(Fd, <<"read">>),
            is_tuple(Handle) andalso element(1, Handle) =:= dir andalso uv_error(eisdir, <<"read">>, Path),
            Result = case position(Position) of
                current -> file:read(Handle, Count);
                P -> file:pread(Handle, P, Count)
            end,
            case Result of
                {ok, Bytes} -> Bytes;
                eof -> <<>>;
                {error, Reason} -> uv_error(Reason, <<"read">>, undefined)
            end
    end,
    bouy_node_encoding:view_write(Buffer, At, Data),
    byte_size(Data).

read_stdin(Count) -> bouy_node_stdin:read(Count).

%% An asynchronous read of stdin waits for its bytes outside the realm, so the
%% loop runs on; the request and its buffer stay roots of the heap meanwhile.
read_stdin_async(Req, Buffer, At, Count) ->
    Ref = make_ref(),
    erlang:put({?MODULE, stdin_read, Ref}, {Req, Buffer}),
    bouy_node_stdin:read_async(Count, fun(Bytes) ->
        {Req1, Buffer1} = erlang:erase({?MODULE, stdin_read, Ref}),
        bouy_node_encoding:view_write(Buffer1, At, Bytes),
        bouy_heap:call(bouy_heap:get(Req1, <<"oncomplete">>), Req1, [null, byte_size(Bytes)])
    end),
    undefined.

position(undefined) -> current;
position(null) -> current;
position(V) ->
    case bouy_ref:to_number(V) of
        N when is_integer(N), N >= 0 -> N;
        N when is_float(N), N >= 0 -> trunc(N);
        {'$bigint', N} when N >= 0 -> N;
        _ -> current
    end.

%% writeBuffer(fd, buffer, offset, length, position)
write_buffer(Args) ->
    [Fd, Buffer, Offset, Length, Position] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Start = trunc(bouy_ref:to_number(Offset)),
    Bytes = bouy_node_encoding:view_bytes(Buffer, Start, Start + trunc(bouy_ref:to_number(Length))),
    write_bytes(fd(Fd), Bytes, Position).

%% writeString(fd, string, position, encoding)
write_string(Args) ->
    [Fd, String, Position, Encoding] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Enc = case bouy_node_encoding:parse(Encoding) of
        {ok, E} -> E;
        error -> utf8
    end,
    write_bytes(fd(Fd), bouy_node_encoding:encode(Enc, bouy_ref:to_string(String)), Position).

write_bytes(1, Bytes, _) -> put_bytes(standard_io, Bytes);
write_bytes(2, Bytes, _) -> put_bytes(bouy_ref:stderr(), Bytes);
write_bytes(Fd, Bytes, Position) ->
    {Handle, _} = file(Fd, <<"write">>),
    Result = case position(Position) of
        current -> file:write(Handle, Bytes);
        P -> file:pwrite(Handle, P, Bytes)
    end,
    check(Result, <<"write">>, undefined),
    byte_size(Bytes).

%% The device is in unicode mode: valid UTF-8 goes through as text, and
%% other bytes as latin1 characters in a latin1 window.
put_bytes(Device, Bytes) ->
    case unicode:characters_to_list(Bytes, utf8) of
        L when is_list(L) ->
            io:put_chars(Device, Bytes);
        _ ->
            ok = io:setopts(Device, [{encoding, latin1}]),
            io:put_chars(Device, Bytes),
            ok = io:setopts(Device, [{encoding, unicode}])
    end,
    byte_size(Bytes).

read_file_utf8(Args) ->
    Target = bouy_node:arg(1, Args),
    Bytes = case Target of
        Fd when is_integer(Fd) ->
            {Handle, _} = file(Fd, <<"read">>),
            read_all(Handle, []);
        _ ->
            Path = path(Target),
            filelib:is_dir(Path) andalso uv_error(eisdir, <<"read">>, undefined),
            check(file:read_file(Path), <<"open">>, Path)
    end,
    bouy_node_encoding:decode_utf8(Bytes).

read_all(Handle, Acc) ->
    case file:read(Handle, 65536) of
        {ok, Bytes} -> read_all(Handle, [Bytes | Acc]);
        _ -> iolist_to_binary(lists:reverse(Acc))
    end.

%% writeFileUtf8(path or fd, data, flag, mode)
write_file_utf8(Args) ->
    [Target, Data, Flags0] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Bytes = bouy_ref_string:to_utf8(bouy_ref:to_string(Data)),
    case Target of
        Fd when is_integer(Fd) ->
            write_bytes(Fd, Bytes, undefined),
            undefined;
        _ ->
            Path = path(Target),
            Flags = trunc(bouy_ref:to_number(Flags0)),
            Modes = case Flags band ?O_APPEND of
                0 -> [write];
                _ -> [append]
            end,
            check(file:write_file(Path, Bytes, Modes), <<"open">>, Path),
            undefined
    end.

%%% Stats

stat(Args) -> stat_call(Args, <<"stat">>, fun file:read_file_info/2).

lstat(Args) -> stat_call(Args, <<"lstat">>, fun file:read_link_info/2).

stat_call(Args, Syscall, Info) ->
    [Target, BigInt, _Req, ThrowIfNoEntry] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Path = path(Target),
    case Info(Path, [{time, posix}]) of
        {ok, FileInfo} ->
            stats(FileInfo, bouy_ref:truthy(BigInt));
        {error, enoent} when ThrowIfNoEntry =:= false ->
            undefined;
        {error, Reason} ->
            uv_error(Reason, Syscall, Path)
    end.

fstat(Args) ->
    Fd = fd(bouy_node:arg(1, Args)),
    BigInt = bouy_ref:truthy(bouy_node:arg(2, Args)),
    case Fd of
        F when F >= 0, F =< 2 ->
            stats(#file_info{type = other, mode = 8#10600, size = 0, links = 1, atime = 0, mtime = 0, ctime = 0,
                             inode = 0, uid = 0, gid = 0, major_device = 0, minor_device = 0}, BigInt);
        _ ->
            {_, Path} = file(Fd, <<"fstat">>),
            stats(check(file:read_file_info(Path, [{time, posix}]), <<"fstat">>, Path), BigInt)
    end.

%% Fills the stat array in Node's field order and returns it.
stats(#file_info{} = Info, BigInt) ->
    {Stats, BigStats} = erlang:get({?MODULE, stats}),
    Fields = [Info#file_info.major_device, Info#file_info.mode, Info#file_info.links, Info#file_info.uid,
              Info#file_info.gid, Info#file_info.minor_device, 4096, Info#file_info.inode, Info#file_info.size,
              (Info#file_info.size + 511) div 512, Info#file_info.atime, 0, Info#file_info.mtime, 0,
              Info#file_info.ctime, 0, Info#file_info.ctime, 0],
    Array = case BigInt of
        true -> BigStats;
        false -> Stats
    end,
    [bouy_heap:set(Array, I, field(V, BigInt)) || {I, V} <- lists:enumerate(0, Fields)],
    Array.

field(V, true) when is_integer(V) -> {'$bigint', V};
field(_, true) -> {'$bigint', 0};
field(V, false) when is_integer(V) -> V;
field(_, false) -> 0.

exists(Target) ->
    try filelib:is_file(path(Target))
    catch _:_ -> false
    end.

%% internalModuleStat(path): 0 for a file, 1 for a directory, a negative
%% errno otherwise.
module_stat(Args) ->
    Path = path(bouy_node:arg(case length(Args) of 2 -> 2; _ -> 1 end, Args)),
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> 1;
        {ok, _} -> 0;
        _ -> -2
    end.

%%% Directories and links

mkdir(Args) ->
    [Target, _Mode, Recursive] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Path = path(Target),
    case bouy_ref:truthy(Recursive) of
        true ->
            First = first_missing(Path),
            filelib:is_file(Path) andalso not filelib:is_dir(Path) andalso uv_error(eexist, <<"mkdir">>, Path),
            check(filelib:ensure_path(Path), <<"mkdir">>, Path),
            case First of
                none -> undefined;
                _ -> bouy_ref_string:from_utf8(First)
            end;
        false ->
            check(file:make_dir(Path), <<"mkdir">>, Path),
            undefined
    end.

first_missing(Path) ->
    case filelib:is_dir(Path) of
        true -> none;
        false ->
            Parent = filename:dirname(Path),
            case Parent =:= Path orelse filelib:is_dir(Parent) of
                true -> Path;
                false -> first_missing(Parent)
            end
    end.

rmdir(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    check(file:del_dir(Path), <<"rmdir">>, Path),
    undefined.

unlink(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    filelib:is_dir(Path) andalso not is_link(Path) andalso uv_error(eperm, <<"unlink">>, Path),
    check(file:delete(Path), <<"unlink">>, Path),
    undefined.

is_link(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> true;
        _ -> false
    end.

%% rmSync(path, maxRetries, recursive, retryDelay)
rm_sync(Args) ->
    [Target, _Retries, Recursive] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Path = path(Target),
    case file:read_link_info(Path) of
        %% A missing path is no error: lib/fs.js checks it first unless force is set.
        {error, enoent} ->
            undefined;
        {error, Reason} ->
            uv_error(Reason, <<"rm">>, Path);
        {ok, #file_info{type = directory}} ->
            bouy_ref:truthy(Recursive) orelse
                bouy_node:throw_code('Error', <<"ERR_FS_EISDIR">>,
                                     bouy_ref_string:from_utf8(<<"Path is a directory: rm returned EISDIR (is a directory) ", Path/binary>>)),
            check(file:del_dir_r(Path), <<"rm">>, Path),
            undefined;
        {ok, _} ->
            check(file:delete(Path), <<"rm">>, Path),
            undefined
    end.

rename(Args) ->
    [From, To] = [path(bouy_node:arg(I, Args)) || I <- [1, 2]],
    case file:rename(From, To) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"rename">>, From, To)
    end.

%% readdir(path, encoding, withFileTypes): the names, or [names, types].
readdir(Args) ->
    [Target, _Encoding, WithTypes] = [bouy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Path = path(Target),
    Names = lists:sort(check(file:list_dir_all(Path), <<"scandir">>, Path)),
    Js = [bouy_ref_string:from_utf8(unicode:characters_to_binary(N)) || N <- Names],
    case bouy_ref:truthy(WithTypes) of
        false ->
            bouy_heap:new_array(Js);
        true ->
            Types = [dirent_type(filename:join(Path, N)) || N <- Names],
            bouy_heap:new_array([bouy_heap:new_array(Js), bouy_heap:new_array(Types)])
    end.

%% The UV_DIRENT_* type of a directory entry.
dirent_type(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> 1;
        {ok, #file_info{type = directory}} -> 2;
        {ok, #file_info{type = symlink}} -> 3;
        {ok, #file_info{type = device}} -> 6;
        _ -> 0
    end.

readlink(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    Target = check(file:read_link_all(Path), <<"readlink">>, Path),
    bouy_ref_string:from_utf8(unicode:characters_to_binary(Target)).

symlink(Args) ->
    [Target, Path] = [path(bouy_node:arg(I, Args)) || I <- [1, 2]],
    case file:make_symlink(Target, Path) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"symlink">>, Target, Path)
    end.

link(Args) ->
    [From, To] = [path(bouy_node:arg(I, Args)) || I <- [1, 2]],
    case file:make_link(From, To) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"link">>, From, To)
    end.

realpath(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    bouy_ref_string:from_utf8(resolve(Path, 0)).

resolve(Path, Depth) when Depth > 40 -> uv_error(eloop, <<"realpath">>, Path);
resolve(Path, Depth) ->
    Absolute = filename:absname(Path),
    Parts = filename:split(Absolute),
    lists:foldl(fun(Part, Acc) ->
        Next = filename:join(Acc, Part),
        case file:read_link_all(Next) of
            {ok, Link} -> resolve(filename:join(Acc, Link), Depth + 1);
            {error, einval} -> Next;
            {error, Reason} -> uv_error(Reason, <<"realpath">>, Path)
        end
    end, hd(Parts), tl(Parts)).

copy_file(Args) ->
    [From, To] = [path(bouy_node:arg(I, Args)) || I <- [1, 2]],
    Mode = trunc(bouy_ref:to_number(bouy_node:arg(3, Args))),
    Mode band 1 =/= 0 andalso filelib:is_file(To) andalso uv_error(eexist, <<"copyfile">>, From, To),
    case file:copy(From, To) of
        {ok, _} -> undefined;
        {error, Reason} -> uv_error(Reason, <<"copyfile">>, From, To)
    end.

chmod(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    check(file:change_mode(Path, trunc(bouy_ref:to_number(bouy_node:arg(2, Args)))), <<"chmod">>, Path),
    undefined.

fchmod(Args) ->
    {_, Path} = file(fd(bouy_node:arg(1, Args)), <<"fchmod">>),
    check(file:change_mode(Path, trunc(bouy_ref:to_number(bouy_node:arg(2, Args)))), <<"fchmod">>, Path),
    undefined.

utimes(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    set_times(Path, bouy_node:arg(2, Args), bouy_node:arg(3, Args), <<"utime">>).

futimes(Args) ->
    {_, Path} = file(fd(bouy_node:arg(1, Args)), <<"futime">>),
    set_times(Path, bouy_node:arg(2, Args), bouy_node:arg(3, Args), <<"futime">>).

set_times(Path, Atime, Mtime, Syscall) ->
    Seconds = fun(V) -> trunc(bouy_ref:to_number(V)) end,
    check(file:write_file_info(Path, #file_info{atime = Seconds(Atime), mtime = Seconds(Mtime)}, [{time, posix}]), Syscall, Path),
    undefined.

ftruncate(Args) ->
    {Handle, Path} = file(fd(bouy_node:arg(1, Args)), <<"ftruncate">>),
    Length = trunc(bouy_ref:to_number(bouy_node:arg(2, Args))),
    check(file:position(Handle, Length), <<"ftruncate">>, Path),
    check(file:truncate(Handle), <<"ftruncate">>, Path),
    undefined.

fsync(Args) ->
    {Handle, _} = file(fd(bouy_node:arg(1, Args)), <<"fsync">>),
    _ = file:sync(Handle),
    undefined.

mkdtemp(Args) ->
    Prefix = path(bouy_node:arg(1, Args)),
    Suffix = << <<(lists:nth(rand:uniform(62), "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))>> || _ <- lists:seq(1, 6) >>,
    Path = <<Prefix/binary, Suffix/binary>>,
    check(file:make_dir(Path), <<"mkdtemp">>, <<Prefix/binary, "XXXXXX">>),
    bouy_ref_string:from_utf8(Path).

%% access(path, mode): an error unless the file exists and grants the mode.
access(Args) ->
    Path = path(bouy_node:arg(1, Args)),
    Mode = trunc(bouy_ref:to_number(bouy_node:arg(2, Args))),
    Info = check(file:read_file_info(Path), <<"access">>, Path),
    Granted = case Info#file_info.access of
        read_write -> 6;
        read -> 4;
        write -> 2;
        none -> 0
    end,
    Exec = case Info#file_info.mode band 8#111 of 0 -> 0; _ -> 1 end,
    case (Mode band 6) band (bnot Granted) =:= 0 andalso (Mode band 1 =:= 0 orelse Exec =:= 1) of
        true -> undefined;
        false -> uv_error(eacces, <<"access">>, Path)
    end.
