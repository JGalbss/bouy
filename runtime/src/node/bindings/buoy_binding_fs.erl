%% internalBinding('fs') (src/node_file.cc): the file system calls of lib/fs
%% on prim_file, the raw file layer of ERTS. prim_file runs each call in the
%% calling process on a dirty I/O scheduler, so a slow disk blocks only the
%% realm that asked, and no call goes through the file server.
%%
%% Each call takes Node's request argument last. undefined runs it now and
%% throws Node's UVException. An FSReqCallback runs it now and calls
%% req.oncomplete in a later macrotask, as libuv calls back from its thread
%% pool. kUsePromises returns a promise that settles in a later macrotask.
%% A file descriptor is the OS descriptor of a raw file that the realm owns;
%% 0, 1, and 2 are the standard streams of the VM.
%%
%% prim_file has no sub-second times, no statfs, and no call that changes a
%% symlink itself, so stat, statfs, access, and the calls that change modes,
%% owners, and times run the NIFs of buoy_native, which make the system
%% calls that libuv makes.
-module(buoy_binding_fs).

-include_lib("kernel/include/file.hrl").
-include("buoy_ref.hrl").

-compile({no_auto_import, [link/1, unlink/1]}).

-export([binding/0, uv_error/3, uv_error/4, uv_error/5, uv_errno/1, errno_exception/4, strerror/1, request/2, path/1,
         encoded/2, read_info/2, read_stats/2, read_dir/1, result/1, reason/1, stat_array/3, stat_pair/3, int/1,
         inherited_file/1]).
-export_type([stats/0]).

%% Node's stat fields, as buoy_native:fs_stat/2 gives them.
-type stats() :: [integer()].

-define(FDS, '$buoy_node_fds').
-define(STATE, {?MODULE, state}).
-define(FD_SLOT, {'#', ?MODULE, <<"fd">>}).
-define(STAT_FIELDS, 18).
%% The open flags of this OS, as the constants binding reports them.
-define(O_WRONLY, 1).
-define(O_RDWR, 2).
-define(O_APPEND, flag(<<"O_APPEND">>)).
-define(O_SYNC, flag(<<"O_SYNC">>)).
-define(O_NOFOLLOW, flag(<<"O_NOFOLLOW">>)).
-define(O_CREAT, flag(<<"O_CREAT">>)).
-define(O_TRUNC, flag(<<"O_TRUNC">>)).
-define(O_EXCL, flag(<<"O_EXCL">>)).
-define(O_DIRECTORY, flag(<<"O_DIRECTORY">>)).
-define(O_DSYNC, flag(<<"O_DSYNC">>)).
-define(O_SYMLINK, flag(<<"O_SYMLINK">>)).
-define(COPYFILE_EXCL, 1).
-define(COPYFILE_FICLONE_FORCE, 4).

-spec binding() -> term().
binding() ->
    %% The NIF library ignores SIGXFSZ as it loads, as Node's PlatformInit
    %% does, so it loads before the first write.
    _ = code:ensure_loaded(buoy_native),
    Promises = buoy_node:symbol(<<"fs_use_promises_symbol">>),
    Stats = buoy_node:typed_array(<<"Float64Array">>, 2 * ?STAT_FIELDS),
    BigStats = buoy_node:typed_array(<<"BigInt64Array">>, 2 * ?STAT_FIELDS),
    StatFs = buoy_node:typed_array(<<"Float64Array">>, 7),
    BigStatFs = buoy_node:typed_array(<<"BigInt64Array">>, 7),
    Constants = buoy_heap:get(buoy_node:binding(<<"constants">>), <<"fs">>),
    Flags = maps:from_list([{Name, N} || Name <- [<<"O_APPEND">>, <<"O_SYNC">>, <<"O_NOFOLLOW">>, <<"O_CREAT">>,
                                                   <<"O_TRUNC">>, <<"O_EXCL">>, <<"O_DIRECTORY">>, <<"O_DSYNC">>,
                                                   <<"O_SYMLINK">>],
                                         N <- [buoy_heap:get(Constants, Name)], is_integer(N)]),
    erlang:put(?STATE, #{promises => Promises, stats => Stats, bigint_stats => BigStats, statfs => StatFs,
                         bigint_statfs => BigStatFs, flags => Flags}),
    Req = buoy_node:constructor(<<"FSReqCallback">>, 1, fun(This, Args) ->
        buoy_heap:set(This, <<"bigint">>, buoy_ref:truthy(buoy_node:arg(1, Args))),
        buoy_binding_async_wrap:wrap(This, <<"FSREQCALLBACK">>),
        undefined
    end),
    %% {Name, the position of the request argument, the call}
    Async = [
        {<<"access">>, 3, fun access/1}, {<<"close">>, 2, fun close/1}, {<<"open">>, 4, fun open/1},
        {<<"openFileHandle">>, 4, fun open_file_handle/1}, {<<"read">>, 6, fun read/1},
        {<<"readBuffers">>, 4, fun read_buffers/1}, {<<"fdatasync">>, 2, fun fdatasync/1},
        {<<"fsync">>, 2, fun fsync/1}, {<<"rename">>, 3, fun rename/1}, {<<"ftruncate">>, 3, fun ftruncate/1},
        {<<"rmdir">>, 2, fun rmdir/1}, {<<"mkdir">>, 4, fun mkdir/1}, {<<"readdir">>, 4, fun readdir/1},
        {<<"stat">>, 3, fun stat/1}, {<<"lstat">>, 3, fun lstat/1}, {<<"fstat">>, 3, fun fstat/1},
        {<<"statfs">>, 3, fun statfs/1}, {<<"link">>, 3, fun link/1}, {<<"symlink">>, 4, fun symlink/1},
        {<<"readlink">>, 3, fun readlink/1}, {<<"unlink">>, 2, fun unlink/1},
        {<<"writeBuffer">>, 6, fun write_buffer/1}, {<<"writeBuffers">>, 4, fun write_buffers/1},
        {<<"writeString">>, 5, fun write_string/1}, {<<"realpath">>, 3, fun realpath/1},
        {<<"copyFile">>, 4, fun copy_file/1}, {<<"chmod">>, 3, fun chmod/1}, {<<"fchmod">>, 3, fun fchmod/1},
        {<<"chown">>, 4, fun chown/1}, {<<"fchown">>, 4, fun fchown/1}, {<<"lchown">>, 4, fun lchown/1},
        {<<"utimes">>, 4, fun utimes/1}, {<<"futimes">>, 4, fun futimes/1}, {<<"lutimes">>, 4, fun lutimes/1},
        {<<"mkdtemp">>, 3, fun mkdtemp/1}],
    Sync = [
        {<<"existsSync">>, fun exists/1}, {<<"internalModuleStat">>, fun module_stat/1},
        {<<"rmSync">>, fun rm_sync/1}, {<<"readFileUtf8">>, fun read_file_utf8/1},
        {<<"writeFileUtf8">>, fun write_file_utf8/1}, {<<"getFormatOfExtensionlessFile">>, fun extensionless_format/1},
        {<<"cpSyncCheckPaths">>, fun buoy_node_fs_cp:check_paths/1},
        {<<"cpSyncOverrideFile">>, fun buoy_node_fs_cp:override_file/1},
        {<<"cpSyncCopyDir">>, fun buoy_node_fs_cp:copy_dir/1},
        {<<"legacyMainResolve">>, fun legacy_main_resolve/1}],
    buoy_node:object(
        [{Name, buoy_node:fn(Name, 0, fun(_, Args) -> call(Name, Args, At, Fun) end)} || {Name, At, Fun} <- Async]
        ++ [{Name, buoy_node:fn(Name, 0, fun(_, Args) -> value(Fun(Args), global) end)} || {Name, Fun} <- Sync]
        ++ [{<<"FSReqCallback">>, Req},
            {<<"FileHandle">>, file_handle_class()},
            {<<"StatWatcher">>, buoy_node_stat_watcher:class()},
            {<<"kFsStatsFieldsNumber">>, ?STAT_FIELDS},
            {<<"kUsePromises">>, Promises},
            {<<"statValues">>, Stats},
            {<<"bigintStatValues">>, BigStats},
            {<<"statFsValues">>, StatFs},
            {<<"bigintStatFsValues">>, BigStatFs}]).

%%% Requests

%% An asynchronous read of stdin waits for its bytes outside the realm, so
%% the loop runs on.
call(<<"read">>, [0, Buffer, Offset, Length, _Position, Req | _], _, _) when ?IS_OBJECT(Req) ->
    read_stdin_async(Req, Buffer, int(Offset), int(Length));
call(Name, Args, At, Fun) ->
    validate(Name, Args),
    request(buoy_node:arg(At, Args), fun() -> Fun(Args) end).

%% The checks that the C++ side makes before it dispatches a call, so they
%% throw at once even for a callback or a promise.
validate(<<"access">>, Args) -> file_mode(buoy_node:arg(2, Args));
validate(<<"copyFile">>, Args) -> file_mode(buoy_node:arg(3, Args));
validate(Name, Args) ->
    Fd = [<<"close">>, <<"fstat">>, <<"ftruncate">>, <<"fdatasync">>, <<"fsync">>, <<"writeBuffer">>,
          <<"writeBuffers">>, <<"writeString">>, <<"read">>, <<"readBuffers">>, <<"fchmod">>, <<"fchown">>,
          <<"futimes">>],
    lists:member(Name, Fd) andalso validated_fd(buoy_node:arg(1, Args)),
    ok.

%% GetValidatedFd: an int32 descriptor, or ERR_INVALID_ARG_TYPE and
%% ERR_OUT_OF_RANGE as src/util.cc throws them.
-spec validated_fd(term()) -> non_neg_integer().
validated_fd(Fd) when is_integer(Fd), Fd >= 0, Fd =< 16#7FFFFFFF -> Fd;
validated_fd(Fd) when is_float(Fd), Fd >= 0, Fd =< 16#7FFFFFFF, Fd == trunc(Fd) -> trunc(Fd);
validated_fd(Fd) when ?IS_NUMBER(Fd) ->
    Rule = case is_number(Fd) andalso (Fd < 0 orelse Fd > 16#7FFFFFFF) of
        true -> <<"It must be >= 0 && <= 2147483647">>;
        false -> <<"It must be an integer">>
    end,
    buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>,
                         text([<<"The value of \"fd\" is out of range. ">>, Rule, <<". Received ">>, buoy_ref:to_string(Fd)]));
validated_fd(Fd) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                         text([<<"The \"fd\" argument must be of type number. Received ">>, received(Fd)])).

%% GetValidFileMode for access and copyFile: null, undefined, or 0 to 7.
file_mode(Mode) when Mode =:= undefined; Mode =:= null -> ok;
file_mode(Mode) when Mode =:= 'NaN'; Mode =:= 'Infinity'; Mode =:= '-Infinity' ->
    buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"mode is out of range">>);
file_mode(Mode) when is_number(Mode) ->
    Int = buoy_ref:bit_or(Mode, 0),
    Int >= 0 andalso Int =< 7 orelse
        buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, <<"mode is out of range: >= 0 && <= 7">>),
    ok;
file_mode(_) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, <<"mode must be int32 or null/undefined">>).

text(Parts) -> buoy_ref_string:from_utf8(iolist_to_binary([part(P) || P <- Parts])).

part(P) when is_binary(P) -> P;
part(P) -> buoy_ref_string:to_utf8(P).

%% DetermineSpecificErrorType of src/util.cc: how an error names a value.
-spec received(term()) -> binary().
received(V) when ?IS_STRING(V) ->
    Bytes = buoy_ref_string:to_utf8(V),
    Short = case byte_size(Bytes) > 28 of
        true -> <<(binary:part(Bytes, 0, 25))/binary, "...">>;
        false -> Bytes
    end,
    case binary:match(Short, <<"'">>) of
        nomatch -> <<"type string ('", Short/binary, "')">>;
        _ -> <<"type string (", (buoy_ref_string:to_utf8(buoy_ref_json:stringify(V, undefined, undefined)))/binary, ")">>
    end;
received(V) when ?IS_OBJECT(V) ->
    case buoy_heap:is_callable(V) of
        true -> <<"function">>;
        false -> <<"an instance of ", (constructor_name(V))/binary>>
    end;
received({'$sym', _, _} = V) -> buoy_ref_string:to_utf8(buoy_ref:describe(V));
received('NaN') -> <<"type number (NaN)">>;
received(V) when V =:= 'Infinity'; V =:= '-Infinity' -> <<"type number (Infinity)">>;
received(V) when is_number(V) -> <<"type number (", (buoy_ref_string:to_utf8(buoy_ref:to_string(V)))/binary, ")">>;
received({'$bigint', N}) -> <<"type bigint (", (integer_to_binary(N))/binary, ")">>;
received(true) -> <<"type boolean (true)">>;
received(false) -> <<"type boolean (false)">>;
received(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

constructor_name(V) ->
    Name = try buoy_heap:get(buoy_heap:get(V, <<"constructor">>), <<"name">>)
           catch _:_ -> undefined
           end,
    case Name of
        N when ?IS_STRING(N), N =/= <<>> -> buoy_ref_string:to_utf8(N);
        _ -> <<"Object">>
    end.

%% Runs Call for the request argument Req of a binding function: now for
%% undefined, with req.oncomplete for an FSReqCallback, and with a promise
%% for kUsePromises.
-spec request(term(), fun(() -> term())) -> term().
request(undefined, Call) ->
    value(Call(), global);
request(Req, Call) ->
    Outcome = try {ok, Call()}
              catch error:{'$throw', Thrown} -> {error, Thrown}
              end,
    case Req =:= maps:get(promises, erlang:get(?STATE)) of
        true ->
            Promise = buoy_jobs:new_promise(),
            buoy_node_loop:defer(fun() -> settle(Promise, Outcome) end),
            Promise;
        false ->
            buoy_node_loop:defer(fun() -> complete(Req, Outcome) end),
            undefined
    end.

complete(Req, {ok, Result}) ->
    case value(Result, global) of
        undefined -> callback(Req, [null]);
        Value -> callback(Req, [null, Value])
    end;
complete(Req, {error, E}) ->
    callback(Req, [E]).

%% FSReqCallback::Resolve and Reject: req.oncomplete through MakeCallback,
%% and then the request ends.
callback(Req, Args) ->
    _ = buoy_binding_async_wrap:make_callback(Req, buoy_heap:get(Req, <<"oncomplete">>), Args),
    buoy_binding_async_wrap:emit_destroy(Req).

settle(Promise, {ok, Result}) -> buoy_jobs:resolve_promise(Promise, value(Result, fresh));
settle(Promise, {error, E}) -> buoy_jobs:reject_promise(Promise, E).

%% The JavaScript value of a result. Stats fill the binding's shared array,
%% as FillGlobalStatsArray does, at the moment JavaScript reads them; a
%% promise gets an array of its own, as FSReqPromise has.
value({stats, Info, BigInt}, Where) -> stat_array(Info, BigInt, Where);
value({statfs, Values, BigInt}, Where) ->
    Array = case {Where, BigInt} of
        {global, true} -> maps:get(bigint_statfs, erlang:get(?STATE));
        {global, false} -> maps:get(statfs, erlang:get(?STATE));
        {fresh, true} -> buoy_node:typed_array(<<"BigInt64Array">>, 7);
        {fresh, false} -> buoy_node:typed_array(<<"Float64Array">>, 7)
    end,
    [buoy_heap:set(Array, I, field(V, BigInt)) || {I, V} <- lists:enumerate(0, Values)],
    Array;
value(Value, _) -> Value.

%%% Paths, names, and errors

-spec path(term()) -> binary().
path(V) when ?IS_STRING(V) -> buoy_ref_string:to_utf8(V);
path(V) when ?IS_OBJECT(V) -> buoy_node_encoding:view_bytes(V);
path(V) -> buoy_ref_string:to_utf8(buoy_ref:to_string(V)).

%% A file name in the encoding that the call asks for (StringBytes::Encode).
-spec encoded(binary(), term()) -> term().
encoded(Bytes, Encoding) ->
    case buoy_node_encoding:parse(Encoding) of
        {ok, buffer} -> buoy_node_encoding:new_buffer(Bytes);
        {ok, Enc} -> buoy_node_encoding:decode(Enc, Bytes);
        error -> buoy_node_encoding:decode_utf8(Bytes)
    end.

%% A name from prim_file: a list of characters, or the bytes of a name that
%% is not valid in the encoding of file names.
name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).

-spec int(term()) -> integer().
int({'$bigint', N}) -> N;
int(V) ->
    case buoy_ref:to_number(V) of
        N when is_integer(N) -> N;
        F when is_float(F) -> trunc(F);
        _ -> 0
    end.

-spec uv_error(atom(), binary(), binary()) -> no_return().
uv_error(Reason, Syscall, Path) -> uv_error(Reason, Syscall, Path, undefined).

%% Node's UVException: "<CODE>: <message>, <syscall> '<path>' -> '<dest>'",
%% with errno, code, syscall, path, and dest.
-spec uv_error(atom(), binary(), binary() | undefined, binary() | undefined) -> no_return().
uv_error(Reason, Syscall, Path, Dest) ->
    uv_error(Reason, Syscall, Path, Dest, fun(Message) -> Message end).

%% A UVException whose message Detail makes from the message of libuv.
-spec uv_error(atom(), binary(), binary() | undefined, binary() | undefined, fun((binary()) -> iodata())) ->
    no_return().
uv_error(Reason, Syscall, Path, Dest, Detail) ->
    {Errno, Code, Message} = errno(Reason),
    Text = iolist_to_binary([Code, <<": ">>, Detail(Message), <<", ">>, Syscall,
                             case Path of undefined -> <<>>; _ -> [<<" '">>, Path, <<"'">>] end,
                             case Dest of undefined -> <<>>; _ -> [<<" -> '">>, Dest, <<"'">>] end]),
    Js = buoy_ref_string:from_utf8(Text),
    E = buoy_heap:error_object('Error', Js, buoy_ref_string:concat(<<"Error: ">>, Js)),
    Props = [{<<"errno">>, Errno}, {<<"code">>, buoy_ref_string:from_utf8(Code)}, {<<"syscall">>, Syscall}]
            ++ [{<<"path">>, buoy_ref_string:from_utf8(Path)} || Path =/= undefined]
            ++ [{<<"dest">>, buoy_ref_string:from_utf8(Dest)} || Dest =/= undefined],
    %% Object::Set, as UVException uses: a setter on Object.prototype runs.
    [buoy_heap:set(E, K, V) || {K, V} <- Props],
    erlang:error({'$throw', E}).

%% The libuv errno, code, and message of a reason of prim_file. A reason
%% that libuv has no name for is UNKNOWN, as uv_translate_sys_error gives.
errno(Reason) ->
    Code = string:uppercase(atom_to_binary(Reason)),
    case [{N, M} || {N, Name, M} <- buoy_binding_uv:errors(), Name =:= Code] of
        [{N, M} | _] -> {N, Code, M};
        [] -> {-4094, <<"UNKNOWN">>, <<"unknown error">>}
    end.

%% The negative libuv errno of a reason of prim_file.
-spec uv_errno(atom()) -> integer().
uv_errno(Reason) -> element(1, errno(Reason)).

check({error, Reason}, Syscall, Path) -> uv_error(Reason, Syscall, Path);
check({ok, Value}, _Syscall, _Path) -> Value;
check(ok, _Syscall, _Path) -> ok.

%%% File descriptors

fds() ->
    case erlang:get(?FDS) of
        undefined -> #{};
        Fds -> Fds
    end.

%% The open file of Fd: its prim_file descriptor, path, and access mode.
file(Fd, Syscall) ->
    case fds() of
        #{Fd := File} -> File;
        _ -> uv_error(ebadf, Syscall, undefined)
    end.

fd(V) -> int(V).

%% The file of a descriptor of the realm that a child process takes as a
%% stdio descriptor (UV_INHERIT_FD). The VM keeps its descriptors from its
%% children, so the child opens the path again.
-spec inherited_file(term()) -> {file, string()} | ignore.
inherited_file(Fd) ->
    case fds() of
        #{Fd := {_, Path, Access}} when Access =/= link ->
            case unicode:characters_to_list(Path) of
                Name when is_list(Name) -> {file, Name};
                _ -> ignore
            end;
        _ ->
            ignore
    end.

%% The OS descriptor of a raw file.
os_fd(File) ->
    <<N:32/native-signed>> = prim_file:get_handle(File),
    N.

%% open(path, flags, mode): the descriptor, as uv_fs_open gives it.
open(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    {File, Access} = open_path(Path, int(buoy_node:arg(2, Args)), int(buoy_node:arg(3, Args))),
    Fd = os_fd(File),
    erlang:put(?FDS, (fds())#{Fd => {File, Path, Access}}),
    Fd.

%% Opens Path with Node's flags. prim_file adds O_CREAT to each open for
%% writing and O_TRUNC to an open for writing only, so an open without them
%% checks first or opens for reading too; Access keeps the mode that the
%% program asked for. Each check is a call on a dirty I/O scheduler, so an
%% open makes only the checks that its flags and mode need.
open_path(Path, Flags, Mode) ->
    Access = case Flags band 3 of
        0 -> read;
        ?O_WRONLY -> write;
        _ -> read_write
    end,
    Create = Flags band ?O_CREAT =/= 0,
    IsLink = Flags band (?O_NOFOLLOW bor ?O_SYMLINK) =/= 0 andalso is_symlink(Path),
    Flags band ?O_NOFOLLOW =/= 0 andalso IsLink andalso uv_error(eloop, <<"open">>, Path),
    not Create andalso Access =/= read andalso not IsLink andalso not is_present(Path) andalso
        uv_error(check_missing(Path), <<"open">>, Path),
    case Flags band ?O_SYMLINK =/= 0 andalso IsLink of
        true -> {link_handle(), link};
        false -> {open_file(Path, Flags, Access, new_mode(Path, Create, Mode)), Access}
    end.

is_symlink(Path) ->
    case prim_file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} -> true;
        _ -> false
    end.

%% The mode that an open which creates Path must set: keep when the file
%% exists or prim_file creates it with that mode.
new_mode(Path, true, Mode) ->
    case created_mode(Mode, 8#666) of
        keep -> keep;
        Wanted ->
            case is_present(Path) of
                true -> keep;
                false -> Wanted
            end
    end;
new_mode(_, false, _) ->
    keep.

%% An open flag of the constants binding, which binding/0 reads once, or 0
%% for a flag that this OS lacks, such as O_SYMLINK on Linux.
flag(Name) -> maps:get(Name, maps:get(flags, erlang:get(?STATE)), 0).

%% O_SYMLINK opens a symlink itself, which prim_file cannot: the descriptor
%% of /dev/null holds the number, and the calls on it act on the path.
link_handle() ->
    {ok, File} = file:open(<<"/dev/null">>, [raw, binary, read]),
    File.

open_file(Path, Flags, Access, NewMode) ->
    Create = Flags band ?O_CREAT =/= 0,
    Truncate = Flags band ?O_TRUNC =/= 0,
    Base = case {Access, Flags band ?O_APPEND =/= 0} of
        {read, _} -> [read];
        {write, true} -> [append];
        {write, false} when Truncate -> [write];
        {_, true} -> [read, append];
        {_, false} -> [read, write]
    end,
    Modes = Base ++ [M || {true, M} <- [{Create andalso Flags band ?O_EXCL =/= 0, exclusive},
                                        {Flags band (?O_SYNC bor ?O_DSYNC) =/= 0, sync},
                                        {Flags band ?O_DIRECTORY =/= 0, directory}]],
    File = case file:open(Path, [raw, binary | Modes]) of
        {ok, F} -> F;
        {error, eisdir} when Access =:= read -> check(file:open(Path, [raw, binary, read, directory]), <<"open">>, Path);
        {error, Reason} -> uv_error(Reason, <<"open">>, Path)
    end,
    Truncate andalso Access =/= read andalso Base =/= [write] andalso file:truncate(File),
    NewMode =:= keep orelse buoy_native:fs_chmod(Path, NewMode, true),
    File.

%% The reason that opening a missing path without O_CREAT fails.
check_missing(Path) ->
    case prim_file:read_file_info(filename:dirname(Path)) of
        {ok, #file_info{type = directory}} -> enoent;
        {ok, _} -> enotdir;
        {error, Reason} -> Reason
    end.

%% Gives a file or directory that a call created the mode that the program
%% asked for, after the umask of the realm.
created(Path, Mode, Default) ->
    case created_mode(Mode, Default) of
        keep -> true;
        Wanted -> buoy_native:fs_chmod(Path, Wanted, true), true
    end.

%% The mode of a new file or directory after the umask of the realm, or keep
%% when prim_file gives it that mode under the umask of the OS process.
created_mode(Mode, Default) ->
    Mask = case erlang:get('$buoy_node_umask') of
        undefined -> 8#022;
        M -> M
    end,
    case Mode band (bnot Mask) band 8#7777 of
        Wanted when Wanted =:= Default band (bnot 8#022) -> keep;
        Wanted -> Wanted
    end.

is_present(Path) -> element(1, prim_file:read_file_info(Path)) =:= ok.

close(Args) ->
    Fd = fd(buoy_node:arg(1, Args)),
    case fds() of
        #{Fd := {File, _, _}} ->
            erlang:put(?FDS, maps:remove(Fd, fds())),
            check(file:close(File), <<"close">>, undefined),
            undefined;
        _ when Fd >= 0, Fd =< 2 ->
            undefined;
        _ ->
            uv_error(ebadf, <<"close">>, undefined)
    end.

%% A FileHandle wraps a descriptor of the realm. Its close() returns a
%% promise; closeSync() and releaseFD() act now.
file_handle_class() ->
    Class = buoy_node:constructor(<<"FileHandle">>, 0, fun(This, Args) ->
        buoy_heap:private_put(This, ?FD_SLOT, int(buoy_node:arg(1, Args))),
        undefined
    end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    erlang:put({?MODULE, file_handle_proto}, Proto),
    Methods = [{<<"close">>, fun(This, _) -> handle_close(This) end},
               {<<"closeSync">>, fun(This, _) -> handle_close_sync(This) end},
               {<<"releaseFD">>, fun(This, _) -> handle_fd(This, -1) end},
               {<<"getAsyncId">>, fun(_, _) -> -1 end}],
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true, enumerable => false,
                                     configurable => true}) || {Name, Fun} <- Methods],
    buoy_heap:define(Proto, <<"fd">>, #{get => buoy_node:fn(<<"get fd">>, 0, fun(This, _) -> handle_fd(This, keep) end),
                                       set => undefined, enumerable => false, configurable => true}),
    Class.

open_file_handle(Args) ->
    Fd = open(Args),
    Handle = buoy_node:object(erlang:get({?MODULE, file_handle_proto}), []),
    buoy_heap:private_put(Handle, ?FD_SLOT, Fd),
    Handle.

%% The descriptor of a FileHandle, -1 once closed; Next replaces it.
handle_fd(This, Next) ->
    Fd = case buoy_heap:private_find(This, ?FD_SLOT) of
        {ok, F} -> F;
        error -> -1
    end,
    Next =:= keep orelse buoy_heap:private_put(This, ?FD_SLOT, Next),
    Fd.

handle_close(This) ->
    Fd = handle_fd(This, -1),
    request(maps:get(promises, erlang:get(?STATE)), fun() -> close([Fd]) end).

handle_close_sync(This) ->
    case handle_fd(This, -1) of
        -1 -> undefined;
        Fd -> close([Fd])
    end.

%%% Reading and writing

%% read(fd, buffer, offset, length, position): the bytes read into buffer.
read(Args) ->
    [Fd, Buffer, Offset, Length, Position] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Data = read_bytes(fd(Fd), int(Length), Position),
    buoy_node_encoding:view_write(Buffer, int(Offset), Data),
    byte_size(Data).

read_bytes(0, Count, _) -> buoy_node_stdin:read(Count);
read_bytes(Fd, Count, Position) ->
    {File, _, Access} = file(Fd, <<"read">>),
    Access =:= write andalso uv_error(ebadf, <<"read">>, undefined),
    Result = case position(Position) of
        current -> file:read(File, Count);
        At -> file:pread(File, At, Count)
    end,
    case Result of
        {ok, Bytes} -> Bytes;
        eof -> <<>>;
        {error, Reason} -> uv_error(Reason, <<"read">>, undefined)
    end.

%% The request and its buffer stay roots of the heap while the read waits.
read_stdin_async(Req, Buffer, At, Count) ->
    Ref = make_ref(),
    erlang:put({?MODULE, stdin_read, Ref}, {Req, Buffer}),
    buoy_node_stdin:read_async(Count, fun(Bytes) ->
        {Req1, Buffer1} = erlang:erase({?MODULE, stdin_read, Ref}),
        buoy_node_encoding:view_write(Buffer1, At, Bytes),
        callback(Req1, [null, byte_size(Bytes)])
    end),
    undefined.

%% readBuffers(fd, buffers, position): readv, the bytes read.
read_buffers(Args) ->
    [Fd, Buffers, Position] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Views = buoy_heap:array_items(Buffers),
    Data = read_bytes(fd(Fd), lists:sum([buoy_node_encoding:view_length(V) || V <- Views]), Position),
    scatter(Views, Data),
    byte_size(Data).

scatter([], _) -> ok;
scatter(_, <<>>) -> ok;
scatter([View | Rest], Data) ->
    Size = min(buoy_node_encoding:view_length(View), byte_size(Data)),
    <<Chunk:Size/binary, Tail/binary>> = Data,
    buoy_node_encoding:view_write(View, 0, Chunk),
    scatter(Rest, Tail).

%% A position of -1, null, or another non-integer reads at the current
%% offset (GetOffset).
position({'$bigint', N}) when N >= 0 -> N;
position(N) when is_integer(N), N >= 0 -> N;
position(N) when is_float(N), N >= 0, N == trunc(N) -> trunc(N);
position(_) -> current.

%% writeBuffer(fd, buffer, offset, length, position)
write_buffer(Args) ->
    [Fd, Buffer, Offset, Length, Position] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Start = int(Offset),
    write_bytes(fd(Fd), buoy_node_encoding:view_bytes(Buffer, Start, Start + int(Length)), Position).

%% writeBuffers(fd, buffers, position): writev.
write_buffers(Args) ->
    [Fd, Buffers, Position] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Bytes = iolist_to_binary([buoy_node_encoding:view_bytes(V) || V <- buoy_heap:array_items(Buffers)]),
    write_bytes(fd(Fd), Bytes, Position).

%% writeString(fd, string, position, encoding)
write_string(Args) ->
    [Fd, String, Position, Encoding] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Enc = case buoy_node_encoding:parse(Encoding) of
        {ok, E} -> E;
        error -> utf8
    end,
    write_bytes(fd(Fd), buoy_node_encoding:encode(Enc, buoy_ref:to_string(String)), Position).

write_bytes(1, Bytes, _) -> put_bytes(standard_io, Bytes);
write_bytes(2, Bytes, _) -> put_bytes(buoy_ref:stderr(), Bytes);
write_bytes(Fd, Bytes, Position) ->
    {File, _, Access} = file(Fd, <<"write">>),
    Access =:= read andalso uv_error(ebadf, <<"write">>, undefined),
    Result = case position(Position) of
        current -> file:write(File, Bytes);
        At -> file:pwrite(File, At, Bytes)
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

%% readFileUtf8(path or fd, flags): the text of the file.
read_file_utf8(Args) ->
    Target = buoy_node:arg(1, Args),
    Bytes = case Target of
        Fd when is_integer(Fd) ->
            read_all(Fd, []);
        _ ->
            read_path(path(Target), int(buoy_node:arg(2, Args)))
    end,
    buoy_node_encoding:decode_utf8(Bytes).

%% The bytes of the file at Path. A read-only open reads the file in one
%% call on a dirty I/O scheduler, as ReadFileUtf8 opens, reads, and closes
%% in C++; other flags open the file as open does.
read_path(Path, 0) ->
    case prim_file:read_file(Path) of
        {ok, Bytes} -> Bytes;
        {error, eisdir} -> uv_error(eisdir, <<"read">>, undefined);
        {error, Reason} -> uv_error(Reason, <<"open">>, Path)
    end;
read_path(Path, Flags) ->
    {File, _} = open_path(Path, Flags, 8#666),
    try read_rest(File, [])
    after file:close(File)
    end.

read_all(0, Acc) ->
    case buoy_node_stdin:read(65536) of
        <<>> -> iolist_to_binary(lists:reverse(Acc));
        Bytes -> read_all(0, [Bytes | Acc])
    end;
read_all(Fd, _) ->
    {File, _, Access} = file(Fd, <<"read">>),
    Access =:= write andalso uv_error(ebadf, <<"read">>, undefined),
    read_rest(File, []).

read_rest(File, Acc) ->
    case file:read(File, 65536) of
        {ok, Bytes} -> read_rest(File, [Bytes | Acc]);
        eof -> iolist_to_binary(lists:reverse(Acc));
        {error, Reason} -> uv_error(Reason, <<"read">>, undefined)
    end.

%% writeFileUtf8(path or fd, data, flag, mode)
write_file_utf8(Args) ->
    [Target, Data, Flags, Mode] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Bytes = buoy_ref_string:to_utf8(buoy_ref:to_string(Data)),
    case Target of
        Fd when is_integer(Fd) ->
            write_bytes(Fd, Bytes, undefined);
        _ ->
            Path = path(Target),
            {File, _} = open_path(Path, int(Flags), int(Mode)),
            try check(file:write(File, Bytes), <<"write">>, undefined)
            after file:close(File)
            end
    end,
    undefined.

%% legacyMainResolve(packagePath, main, base): the index of the first file
%% of the legacy CommonJS main lookup of the ESM loader: main and main with
%% each extension (0 to 6), then index.js, index.json, and index.node of the
%% package (7 to 9). Nothing found throws ERR_MODULE_NOT_FOUND, after the
%% checks of base, as LegacyMainResolve of src/node_file.cc does.
legacy_main_resolve(Args) ->
    [Package, Main, Base] = [buoy_node:arg(I, Args) || I <- [1, 2, 3]],
    Fallback = resolve_path(path(Package), <<"./index">>),
    Candidates = case ?IS_STRING(Main) of
        true ->
            Initial = resolve_path(path(Package), buoy_ref_string:to_utf8(Main)),
            [<<Initial/binary, Ext/binary>> || Ext <- [<<>>, <<".js">>, <<".json">>, <<".node">>, <<"/index.js">>,
                                                       <<"/index.json">>, <<"/index.node">>]];
        false ->
            lists:duplicate(7, none)
    end ++ [<<Fallback/binary, Ext/binary>> || Ext <- [<<".js">>, <<".json">>, <<".node">>]],
    case [I || {I, File} <- lists:enumerate(0, Candidates), File =/= none, is_file(File)] of
        [Index | _] ->
            Index;
        [] ->
            Missing = case ?IS_STRING(Main) of
                true -> resolve_path(path(Package), buoy_ref_string:to_utf8(Main));
                false -> <<Fallback/binary, ".js">>
            end,
            buoy_node:throw_code('Error', <<"ERR_MODULE_NOT_FOUND">>,
                                 text([<<"Cannot find package '">>, Missing, <<"' imported from ">>, base_path(Base)]))
    end.

%% A path that exists and is no directory, as FilePathIsFile reads it.
is_file(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> false;
        {ok, _} -> true;
        {error, _} -> false
    end.

%% The file path of the base URL of legacyMainResolve.
base_path(Base) when ?IS_STRING(Base) ->
    case buoy_node_url:parse(unicode:characters_to_list(buoy_ref_string:to_utf8(Base)), null) of
        {ok, #{scheme := "file", path := Segments}} when is_list(Segments) ->
            uri_string:percent_decode(iolist_to_binary(["/" ++ Segment || Segment <- Segments]));
        {ok, _} ->
            buoy_node:throw_code('TypeError', <<"ERR_INVALID_URL_SCHEME">>, <<"The URL must be of scheme file:">>);
        failure ->
            buoy_node:throw_code('TypeError', <<"ERR_INVALID_URL">>, <<"Invalid URL">>)
    end;
base_path(_) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>,
                         <<"The \"base\" argument must be of type string or an instance of URL.">>).

%% path.resolve(Base, Path): an absolute path with no "." or ".." segment.
resolve_path(Base, Path) ->
    [Root | Parts] = filename:split(filename:join(absolute(Base), Path)),
    Kept = lists:foldl(fun(<<".">>, Acc) -> Acc;
                          (<<"..">>, []) -> [];
                          (<<"..">>, [_ | Acc]) -> Acc;
                          (Part, Acc) -> [Part | Acc]
                       end, [], Parts),
    filename:join([Root | lists:reverse(Kept)]).

%% getFormatOfExtensionlessFile(path): 1 for WebAssembly, by its magic
%% bytes, and 0 for JavaScript.
extensionless_format(Args) ->
    case file:open(path(buoy_node:arg(1, Args)), [raw, binary, read]) of
        {ok, File} ->
            Head = file:read(File, 4),
            file:close(File),
            case Head of
                {ok, <<0, "asm">>} -> 1;
                _ -> 0
            end;
        _ ->
            0
    end.

ftruncate(Args) ->
    {File, _, Access} = file(fd(buoy_node:arg(1, Args)), <<"ftruncate">>),
    Access =:= read andalso uv_error(einval, <<"ftruncate">>, undefined),
    {ok, Current} = file:position(File, cur),
    check(file:position(File, max(0, int(buoy_node:arg(2, Args)))), <<"ftruncate">>, undefined),
    Result = file:truncate(File),
    file:position(File, Current),
    check(Result, <<"ftruncate">>, undefined),
    undefined.

fsync(Args) ->
    {File, _, _} = file(fd(buoy_node:arg(1, Args)), <<"fsync">>),
    check(file:sync(File), <<"fsync">>, undefined),
    undefined.

fdatasync(Args) ->
    {File, _, _} = file(fd(buoy_node:arg(1, Args)), <<"fdatasync">>),
    check(file:datasync(File), <<"fdatasync">>, undefined),
    undefined.

%%% Stats

%% The file_info of Path, following symlinks or not.
-spec read_info(binary(), follow | nofollow) -> {ok, #file_info{}} | {error, atom()}.
read_info(Path, follow) -> prim_file:read_file_info(Path, [{time, posix}]);
read_info(Path, nofollow) -> prim_file:read_link_info(Path, [{time, posix}]).

%% The stat fields of Path, following symlinks or not.
-spec read_stats(binary(), follow | nofollow) -> {ok, stats()} | {error, atom()}.
read_stats(Path, Follow) -> result(buoy_native:fs_stat(Path, Follow =:= follow)).

%% A result of buoy_native with the reason of prim_file for its errno.
-spec result({ok, term()} | {error, integer()} | integer()) -> ok | {ok, term()} | {error, atom()}.
result({ok, Value}) -> {ok, Value};
result({error, Code}) -> {error, reason(Code)};
result(0) -> ok;
result(Code) -> {error, reason(Code)}.

-spec reason(integer()) -> atom().
reason(Code) -> binary_to_atom(string:lowercase(buoy_binding_uv:name(Code))).

%% stat(path, bigint, req, throwIfNoEntry): a missing path gives undefined
%% when throwIfNoEntry is false.
stat(Args) -> stat_call(Args, <<"stat">>, follow, [enoent, enotdir]).

lstat(Args) -> stat_call(Args, <<"lstat">>, nofollow, [enoent]).

stat_call(Args, Syscall, Follow, Missing) ->
    [Target, BigInt, _Req, ThrowIfNoEntry] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Path = path(Target),
    case read_stats(Path, Follow) of
        {ok, Stats} ->
            {stats, Stats, buoy_ref:truthy(BigInt)};
        {error, Reason} ->
            case ThrowIfNoEntry =:= false andalso lists:member(Reason, Missing) of
                true -> undefined;
                false -> uv_error(Reason, Syscall, Path)
            end
    end.

fstat(Args) ->
    Fd = fd(buoy_node:arg(1, Args)),
    BigInt = buoy_ref:truthy(buoy_node:arg(2, Args)),
    Stats = case fds() of
        #{Fd := {_, Path, link}} -> read_stats(Path, nofollow);
        #{Fd := {File, _, _}} -> result(buoy_native:fs_fstat(os_fd(File)));
        _ when Fd >= 0, Fd =< 2 -> result(buoy_native:fs_fstat(Fd));
        _ -> {error, ebadf}
    end,
    {stats, check(Stats, <<"fstat">>, undefined), BigInt}.

%% statfs(path, bigint): type, bsize, blocks, bfree, bavail, files, and
%% ffree of the file system that holds path.
statfs(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    {statfs, check(result(buoy_native:fs_statfs(Path)), <<"statfs">>, Path), buoy_ref:truthy(buoy_node:arg(2, Args))}.

absolute(Path) ->
    case {filename:pathtype(Path), prim_file:get_cwd()} of
        {absolute, _} -> Path;
        {_, {ok, Cwd}} -> filename:join(name(Cwd), Path);
        _ -> Path
    end.

%% Fills a stat array in Node's field order: the shared array of the
%% binding, or a fresh one.
-spec stat_array(stats(), boolean(), global | fresh) -> term().
stat_array(Stats, BigInt, Where) ->
    Array = case {Where, BigInt} of
        {global, true} -> maps:get(bigint_stats, erlang:get(?STATE));
        {global, false} -> maps:get(stats, erlang:get(?STATE));
        {fresh, true} -> buoy_node:typed_array(<<"BigInt64Array">>, 2 * ?STAT_FIELDS);
        {fresh, false} -> buoy_node:typed_array(<<"Float64Array">>, 2 * ?STAT_FIELDS)
    end,
    fill_stats(Array, 0, Stats, BigInt),
    Array.

%% The shared stat array with Curr in its first half and Prev in its
%% second, as a StatWatcher reports them.
-spec stat_pair(stats(), stats(), boolean()) -> term().
stat_pair(Curr, Prev, BigInt) ->
    Array = stat_array(Curr, BigInt, global),
    fill_stats(Array, ?STAT_FIELDS, Prev, BigInt),
    Array.

%% An empty list stands for the zeros of a failed stat.
fill_stats(Array, Offset, Stats, BigInt) ->
    Fields = case Stats of
        [] -> lists:duplicate(?STAT_FIELDS, 0);
        _ -> Stats
    end,
    [buoy_heap:set(Array, Offset + I, field(V, BigInt)) || {I, V} <- lists:enumerate(0, Fields)],
    ok.

field(V, true) when is_integer(V) -> {'$bigint', V};
field(_, true) -> {'$bigint', 0};
field(V, false) when is_integer(V) -> V;
field(_, false) -> 0.

exists(Args) ->
    try read_info(path(buoy_node:arg(1, Args)), follow) of
        {ok, _} -> true;
        _ -> false
    catch _:_ -> false
    end.

%% internalModuleStat(path): 0 for a file, 1 for a directory, a negative
%% errno otherwise.
module_stat(Args) ->
    Path = path(buoy_node:arg(length(Args), Args)),
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> 1;
        {ok, _} -> 0;
        {error, Reason} -> element(1, errno(Reason))
    end.

%%% Directories and links

%% mkdir(path, mode, recursive): the first directory created when recursive.
mkdir(Args) ->
    [Target, Mode, Recursive] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Path = path(Target),
    case buoy_ref:truthy(Recursive) of
        true ->
            case mkdirp(Path, int(Mode)) of
                {ok, none} -> undefined;
                {ok, First} -> buoy_ref_string:from_utf8(First);
                {error, Reason} -> uv_error(Reason, <<"mkdir">>, Path)
            end;
        false ->
            check(prim_file:make_dir(Path), <<"mkdir">>, Path),
            created(Path, int(Mode), 8#777),
            undefined
    end.

%% MKDirpSync: the first directory that it created, or none.
mkdirp(Path, Mode) ->
    case prim_file:make_dir(Path) of
        ok ->
            created(Path, Mode, 8#777),
            {ok, Path};
        {error, enoent} ->
            Parent = filename:dirname(Path),
            case Parent =:= Path of
                true -> {error, eexist};
                false ->
                    case mkdirp(Parent, Mode) of
                        {ok, First} ->
                            case prim_file:make_dir(Path) of
                                ok -> created(Path, Mode, 8#777), {ok, first(First, Path)};
                                {error, eexist} -> existing(Path, First);
                                {error, Reason} -> {error, Reason}
                            end;
                        Error -> Error
                    end
            end;
        {error, Reason} when Reason =:= eacces; Reason =:= enospc; Reason =:= enotdir; Reason =:= eperm ->
            {error, Reason};
        {error, Reason} ->
            case prim_file:read_file_info(Path) of
                {ok, #file_info{type = directory}} -> {ok, none};
                {ok, _} when Reason =:= eexist -> {error, eexist};
                {ok, _} -> {error, Reason};
                {error, Other} -> {error, Other}
            end
    end.

first(none, Path) -> Path;
first(First, _) -> First.

existing(Path, First) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> {ok, First};
        _ -> {error, eexist}
    end.

rmdir(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    %% prim_file reports ENOTEMPTY as EEXIST.
    case prim_file:del_dir(Path) of
        ok -> undefined;
        {error, eexist} -> uv_error(enotempty, <<"rmdir">>, Path);
        {error, Reason} -> uv_error(Reason, <<"rmdir">>, Path)
    end.

unlink(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    check(prim_file:delete(Path), <<"unlink">>, Path),
    undefined.

%% rmSync(path, maxRetries, recursive, retryDelay), as std::filesystem's
%% remove_all, with Node's ErrnoException for each failure.
rm_sync(Args) ->
    [Target, Retries, Recursive, Delay] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 4)],
    Path = path(Target),
    case prim_file:read_link_info(Path) of
        {error, enoent} ->
            undefined;
        {ok, #file_info{type = directory}} when not (Recursive =:= true) ->
            buoy_node:throw_code('Error', <<"ERR_FS_EISDIR">>,
                                 buoy_ref_string:from_utf8(<<"Path is a directory: ", Path/binary>>));
        _ ->
            rm_retry(Path, Recursive =:= true, int(Retries), int(Delay), 1)
    end.

rm_retry(Path, Recursive, Retries, Delay, Attempt) ->
    case remove(Path, Recursive) of
        ok -> undefined;
        {error, enoent} -> undefined;
        {error, Reason} when Retries > 0, Reason =:= ebusy orelse Reason =:= emfile orelse Reason =:= enfile
                                          orelse Reason =:= enotempty orelse Reason =:= eperm ->
            Delay > 0 andalso timer:sleep(Attempt * Delay div 1000 * 1000),
            rm_retry(Path, Recursive, Retries - 1, Delay, Attempt + 1);
        {error, Reason} ->
            rm_error(Reason, Path)
    end.

-spec rm_error(atom(), binary()) -> no_return().
rm_error(Reason, Path) when Reason =:= eperm; Reason =:= enotempty; Reason =:= enotdir; Reason =:= eacces ->
    errno_exception(Reason, <<"rm">>, <<(strerror(Reason))/binary, ": ", Path/binary>>, Path);
rm_error(Reason, Path) ->
    errno_exception(unknown, <<"rm">>, <<"Unknown error: ", (strerror(Reason))/binary>>, Path).

%% The text of strerror(3) on darwin, which std::error_code::message gives.
-spec strerror(atom()) -> binary().
strerror(eperm) -> <<"Operation not permitted">>;
strerror(enoent) -> <<"No such file or directory">>;
strerror(eacces) -> <<"Permission denied">>;
strerror(eexist) -> <<"File exists">>;
strerror(enotdir) -> <<"Not a directory">>;
strerror(eisdir) -> <<"Is a directory">>;
strerror(einval) -> <<"Invalid argument">>;
strerror(enotempty) -> <<"Directory not empty">>;
strerror(eloop) -> <<"Too many levels of symbolic links">>;
strerror(enametoolong) -> <<"File name too long">>;
strerror(enospc) -> <<"No space left on device">>;
strerror(ebusy) -> <<"Resource busy">>;
strerror(exdev) -> <<"Cross-device link">>;
strerror(emfile) -> <<"Too many open files">>;
strerror(erofs) -> <<"Read-only file system">>;
strerror(Reason) -> element(3, errno(Reason)).

%% Node's ErrnoException: "<CODE>, <message> '<path>'", with a positive errno.
-spec errno_exception(atom(), binary(), binary(), binary()) -> no_return().
errno_exception(Reason, Syscall, Message, Path) ->
    {UvErrno, Code, _} = errno(Reason),
    Text = iolist_to_binary([Code, <<", ">>, Message, <<" '">>, Path, <<"'">>]),
    Js = buoy_ref_string:from_utf8(Text),
    E = buoy_heap:error_object('Error', Js, buoy_ref_string:concat(<<"Error: ">>, Js)),
    Props = [{<<"errno">>, -UvErrno}, {<<"code">>, buoy_ref_string:from_utf8(Code)},
             {<<"path">>, buoy_ref_string:from_utf8(Path)}, {<<"syscall">>, Syscall}],
    [buoy_heap:define(E, K, #{value => V, writable => true, enumerable => true, configurable => true}) || {K, V} <- Props],
    erlang:error({'$throw', E}).

%% Removes Path, and what a directory holds when Recursive.
remove(Path, Recursive) ->
    case prim_file:read_link_info(Path) of
        {ok, #file_info{type = directory}} when Recursive ->
            case prim_file:list_dir_all(Path) of
                {ok, Names} ->
                    case remove_all([filename:join(Path, name(N)) || N <- Names]) of
                        ok -> del_dir(Path);
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        {ok, #file_info{type = directory}} ->
            del_dir(Path);
        {ok, _} ->
            prim_file:delete(Path);
        Error ->
            Error
    end.

%% Removes each entry of a directory. libc++'s remove_all, which Node uses
%% on darwin, reads the next entry after a failure and so clears its error:
%% it removes what it can, and the directory reports ENOTEMPTY. libstdc++,
%% which Node uses on Linux, stops at the first error.
remove_all([]) -> ok;
remove_all([Path | Rest]) ->
    case {remove(Path, true), os:type()} of
        {ok, _} -> remove_all(Rest);
        {{error, enoent}, _} -> remove_all(Rest);
        {_, {unix, darwin}} -> remove_all(Rest);
        {Error, _} -> Error
    end.

del_dir(Path) ->
    case prim_file:del_dir(Path) of
        {error, eexist} -> {error, enotempty};
        Result -> Result
    end.

rename(Args) ->
    [From, To] = [path(buoy_node:arg(I, Args)) || I <- [1, 2]],
    case prim_file:rename(From, To) of
        ok -> undefined;
        {error, eexist} -> uv_error(enotempty, <<"rename">>, From, To);
        {error, Reason} -> uv_error(Reason, <<"rename">>, From, To)
    end.

%% readdir(path, encoding, withFileTypes): the names in byte order, as
%% uv_fs_scandir sorts them, or [names, types].
readdir(Args) ->
    [Target, Encoding, WithTypes] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 3)],
    Path = path(Target),
    {Names, Types} = lists:unzip(lists:sort(check(read_dir(Path), <<"scandir">>, Path))),
    Js = [encoded(N, Encoding) || N <- Names],
    case buoy_ref:truthy(WithTypes) of
        false -> buoy_heap:new_array(Js);
        true -> buoy_heap:new_array([buoy_heap:new_array(Js), buoy_heap:new_array(Types)])
    end.

%% The entries of a directory with their UV_DIRENT_* types, in its order.
-spec read_dir(binary()) -> {ok, [{binary(), 0..7}]} | {error, atom()}.
read_dir(Path) -> result(buoy_native:fs_readdir(Path)).

readlink(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    Target = check(prim_file:read_link_all(Path), <<"readlink">>, Path),
    encoded(name(Target), buoy_node:arg(2, Args)).

symlink(Args) ->
    [Target, Path] = [path(buoy_node:arg(I, Args)) || I <- [1, 2]],
    case prim_file:make_symlink(Target, Path) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"symlink">>, Target, Path)
    end.

link(Args) ->
    [From, To] = [path(buoy_node:arg(I, Args)) || I <- [1, 2]],
    case prim_file:make_link(From, To) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"link">>, From, To)
    end.

%% realpath(path, encoding): realpath(3), each symlink resolved before a
%% following "..".
realpath(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    {ok, Cwd} = prim_file:get_cwd(),
    Absolute = filename:join(name(Cwd), Path),
    [Root | Parts] = filename:split(Absolute),
    encoded(resolve(Parts, Root, Path, 0), buoy_node:arg(2, Args)).

resolve(_, _, Path, Links) when Links > 40 -> uv_error(eloop, <<"realpath">>, Path);
resolve([], Resolved, _, _) -> Resolved;
resolve([<<".">> | Rest], Resolved, Path, Links) -> resolve(Rest, Resolved, Path, Links);
resolve([<<"..">> | Rest], Resolved, Path, Links) -> resolve(Rest, filename:dirname(Resolved), Path, Links);
resolve([Part | Rest], Resolved, Path, Links) ->
    Next = filename:join(Resolved, Part),
    case prim_file:read_link_all(Next) of
        {ok, Link} ->
            [First | More] = filename:split(name(Link)),
            Base = case filename:pathtype(First) of
                absolute -> resolve(More, First, Path, Links + 1);
                _ -> resolve([First | More], Resolved, Path, Links + 1)
            end,
            resolve(Rest, Base, Path, Links + 1);
        {error, einval} ->
            resolve(Rest, Next, Path, Links);
        {error, Reason} ->
            uv_error(Reason, <<"realpath">>, Path)
    end.

%% copyFile(src, dest, mode): the bytes and the mode of src, as
%% uv_fs_copyfile copies them.
copy_file(Args) ->
    [From, To] = [path(buoy_node:arg(I, Args)) || I <- [1, 2]],
    Mode = int(buoy_node:arg(3, Args)),
    Mode band ?COPYFILE_FICLONE_FORCE =/= 0 andalso uv_error(enosys, <<"copyfile">>, From, To),
    case copy(From, To, Mode band ?COPYFILE_EXCL =/= 0) of
        ok -> undefined;
        {error, Reason} -> uv_error(Reason, <<"copyfile">>, From, To)
    end.

-spec copy(binary(), binary(), boolean()) -> ok | {error, atom()}.
copy(From, To, Exclusive) ->
    case file:open(From, [raw, binary, read]) of
        {ok, Source} ->
            Result = try copy_to(Source, To, Exclusive)
                     after file:close(Source)
                     end,
            Result;
        Error ->
            Error
    end.

copy_to(Source, To, Exclusive) ->
    {ok, #file_info{mode = Mode}} = prim_file:read_handle_info(Source),
    case file:open(To, [raw, binary, write | [exclusive || Exclusive]]) of
        {ok, Dest} ->
            Copied = file:copy(Source, Dest),
            file:close(Dest),
            case Copied of
                {ok, _} -> result(buoy_native:fs_chmod(To, Mode band 8#7777, true));
                Error -> Error
            end;
        Error ->
            Error
    end.

chmod(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    check(result(buoy_native:fs_chmod(Path, int(buoy_node:arg(2, Args)), true)), <<"chmod">>, Path),
    undefined.

%% A descriptor of O_SYMLINK acts on the symlink, as lchmod(3) does.
fchmod(Args) ->
    Mode = int(buoy_node:arg(2, Args)),
    Result = case file(fd(buoy_node:arg(1, Args)), <<"fchmod">>) of
        {_, Path, link} -> buoy_native:fs_chmod(Path, Mode, false);
        {File, _, _} -> buoy_native:fs_fchmod(os_fd(File), Mode)
    end,
    check(result(Result), <<"fchmod">>, undefined),
    undefined.

chown(Args) -> set_owner(Args, <<"chown">>, true).

lchown(Args) -> set_owner(Args, <<"lchown">>, false).

set_owner(Args, Syscall, Follow) ->
    Path = path(buoy_node:arg(1, Args)),
    [Uid, Gid] = [int(buoy_node:arg(I, Args)) || I <- [2, 3]],
    check(result(buoy_native:fs_chown(Path, Uid, Gid, Follow)), Syscall, Path),
    undefined.

fchown(Args) ->
    [Uid, Gid] = [int(buoy_node:arg(I, Args)) || I <- [2, 3]],
    Result = case file(fd(buoy_node:arg(1, Args)), <<"fchown">>) of
        {_, Path, link} -> buoy_native:fs_chown(Path, Uid, Gid, false);
        {File, _, _} -> buoy_native:fs_fchown(os_fd(File), Uid, Gid)
    end,
    check(result(Result), <<"fchown">>, undefined),
    undefined.

%% The times are seconds, which libuv keeps to the microsecond.
utimes(Args) -> set_times(Args, <<"utime">>, true).

lutimes(Args) -> set_times(Args, <<"lutime">>, false).

set_times(Args, Syscall, Follow) ->
    Path = path(buoy_node:arg(1, Args)),
    [Atime, Mtime] = [buoy_ref:to_number(buoy_node:arg(I, Args)) || I <- [2, 3]],
    check(result(buoy_native:fs_utimes(Path, Atime, Mtime, Follow)), Syscall, Path),
    undefined.

futimes(Args) ->
    [Atime, Mtime] = [buoy_ref:to_number(buoy_node:arg(I, Args)) || I <- [2, 3]],
    Result = case file(fd(buoy_node:arg(1, Args)), <<"futime">>) of
        {_, Path, link} -> buoy_native:fs_utimes(Path, Atime, Mtime, false);
        {File, _, _} -> buoy_native:fs_futimes(os_fd(File), Atime, Mtime)
    end,
    check(result(Result), <<"futime">>, undefined),
    undefined.

%% mkdtemp(prefix, encoding): a new directory whose name is the prefix and
%% six random characters, as uv_fs_mkdtemp makes it.
mkdtemp(Args) ->
    Prefix = path(buoy_node:arg(1, Args)),
    encoded(mkdtemp(Prefix, 100), buoy_node:arg(2, Args)).

mkdtemp(Prefix, Tries) ->
    Chars = <<"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789">>,
    Suffix = << <<(binary:at(Chars, rand:uniform(62) - 1))>> || _ <- lists:seq(1, 6) >>,
    Path = <<Prefix/binary, Suffix/binary>>,
    case prim_file:make_dir(Path) of
        ok -> created(Path, 8#700, 8#777), Path;
        {error, eexist} when Tries > 0 -> mkdtemp(Prefix, Tries - 1);
        {error, Reason} -> uv_error(Reason, <<"mkdtemp">>, <<Prefix/binary, "XXXXXX">>)
    end.

%% access(path, mode): access(2).
access(Args) ->
    Path = path(buoy_node:arg(1, Args)),
    check(result(buoy_native:fs_access(Path, int(buoy_node:arg(2, Args)))), <<"access">>, Path),
    undefined.
