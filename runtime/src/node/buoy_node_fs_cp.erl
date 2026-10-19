%% The cpSync members of internalBinding('fs') (CpSyncCheckPaths,
%% CpSyncOverrideFile, and CpSyncCopyDir of src/node_file.cc), which run
%% std::filesystem in Node. Each step keeps the order of checks and the
%% errors of the C++ code, including its quirks, because lib/internal/fs/cp
%% and Node's tests depend on them.
-module(buoy_node_fs_cp).

-include_lib("kernel/include/file.hrl").

-export([check_paths/1, override_file/1, copy_dir/1]).

-define(ARG(N, Args), buoy_node:arg(N, Args)).

%% cpSyncCheckPaths(src, dest, dereference, recursive)
-spec check_paths(list()) -> undefined.
check_paths(Args) ->
    [Src, Dest] = [buoy_binding_fs:path(?ARG(I, Args)) || I <- [1, 2]],
    Dereference = ?ARG(3, Args) =:= true,
    Recursive = ?ARG(4, Args) =:= true,
    %% Node reads the source with symlink_status when dereference is set, and
    %% with status otherwise.
    {SrcFollow, DestFollow, Syscall} = case Dereference of
        true -> {nofollow, follow, <<"stat">>};
        false -> {follow, nofollow, <<"lstat">>}
    end,
    SrcInfo = case buoy_binding_fs:read_info(Src, SrcFollow) of
        {ok, I} -> I;
        {error, Reason} -> buoy_binding_fs:uv_error(Reason, Syscall, Src)
    end,
    SrcIsDir = SrcInfo#file_info.type =:= directory orelse (Dereference andalso SrcInfo#file_info.type =:= symlink),
    DestExists = case buoy_binding_fs:read_info(Dest, DestFollow) of
        {ok, DestInfo} ->
            equivalent(Src, Dest) andalso cp_error(<<"ERR_FS_CP_EINVAL">>, [<<"src and dest cannot be the same ">>, Dest]),
            DestIsDir = DestInfo#file_info.type =:= directory,
            SrcIsDir andalso not DestIsDir andalso
                cp_error(<<"ERR_FS_CP_DIR_TO_NON_DIR">>,
                         [<<"Cannot overwrite non-directory ">>, Dest, <<" with directory ">>, Src]),
            not SrcIsDir andalso DestIsDir andalso
                cp_error(<<"ERR_FS_CP_NON_DIR_TO_DIR">>,
                         [<<"Cannot overwrite directory ">>, Dest, <<" with non-directory ">>, Src]),
            true;
        {error, _} ->
            false
    end,
    SrcDir = case binary:last(Src) of
        $/ -> Src;
        _ -> <<Src/binary, "/">>
    end,
    SrcIsDir andalso binary:longest_common_prefix([Dest, SrcDir]) =:= byte_size(SrcDir) andalso
        cp_error(<<"ERR_FS_CP_EINVAL">>, [<<"Cannot copy ">>, SrcDir, <<" to a subdirectory of self ">>, Dest]),
    DestParent = parent(Dest),
    parent(Src) =/= DestParent andalso DestParent =/= <<>> andalso parent(DestParent) =/= DestParent
        andalso equivalent(Src, DestParent) andalso
        cp_error(<<"ERR_FS_CP_EINVAL">>, [<<"Cannot copy ">>, SrcDir, <<" to a subdirectory of self ">>, Dest]),
    SrcIsDir andalso not Recursive andalso
        buoy_node:throw_code('Error', <<"ERR_FS_EISDIR">>,
                             text([<<"Recursive option not enabled, cannot copy a directory: ">>, SrcDir])),
    case SrcInfo#file_info.mode band 8#170000 of
        8#140000 -> cp_error(<<"ERR_FS_CP_SOCKET">>, [<<"Cannot copy a socket file: ">>, Dest]);
        8#010000 -> cp_error(<<"ERR_FS_CP_FIFO_PIPE">>, [<<"Cannot copy a FIFO pipe: ">>, Dest]);
        _ -> ok
    end,
    (not DestExists orelse not is_dir(DestParent)) andalso DestParent =/= <<>> andalso
        mkdirs(DestParent),
    undefined.

%% cpSyncOverrideFile(src, dest, mode, preserveTimestamps)
-spec override_file(list()) -> undefined.
override_file(Args) ->
    [Src, Dest] = [buoy_binding_fs:path(?ARG(I, Args)) || I <- [1, 2]],
    Mode = buoy_binding_fs:int(?ARG(3, Args)),
    case prim_file:delete(Dest) of
        ok -> ok;
        {error, Reason} -> std_error(Reason, <<"unlink">>, Dest)
    end,
    case copy_file(Src, Dest) of
        ok -> ok;
        {error, R} when Mode =:= 0 -> std_error(R, <<"cp">>, Dest);
        {error, R} -> buoy_binding_fs:uv_error(R, <<"cp">>, Src, Dest)
    end,
    ?ARG(4, Args) =:= true andalso copy_times(Src, Dest),
    undefined.

%% cpSyncCopyDir(src, dest, force, dereference, errorOnExist,
%% verbatimSymlinks, preserveTimestamps)
-spec copy_dir(list()) -> undefined.
copy_dir(Args) ->
    [Src, Dest] = [buoy_binding_fs:path(?ARG(I, Args)) || I <- [1, 2]],
    [Force, Dereference, ErrorOnExist, Verbatim, Times] = [?ARG(I, Args) =:= true || I <- lists:seq(3, 7)],
    create_directories(Dest),
    Options = #{force => Force, dereference => Dereference, error_on_exist => ErrorOnExist, verbatim => Verbatim,
                times => Times},
    copy_contents(Src, Dest, Options),
    undefined.

copy_contents(Src, Dest, Options) ->
    Names = case prim_file:list_dir_all(Src) of
        {ok, N} -> N;
        {error, Reason} -> std_error(Reason, <<"cp">>, Src)
    end,
    [copy_entry(filename:join(Src, name(Name)), filename:join(Dest, name(Name)), Src, Dest, Options) || Name <- Names],
    ok.

copy_entry(Entry, Target, Src, Dest, Options) ->
    case prim_file:read_link_info(Entry) of
        {ok, #file_info{type = symlink}} -> copy_symlink(Entry, Target, Src, Dest, Options);
        _ ->
            case prim_file:read_file_info(Entry) of
                {ok, #file_info{type = directory}} ->
                    _ = prim_file:make_dir(Target),
                    copy_contents(Entry, Target, Options);
                {ok, #file_info{type = regular}} ->
                    copy_regular(Entry, Target, Dest, Options);
                _ ->
                    ok
            end
    end.

copy_regular(Entry, Target, Dest, #{force := Force, error_on_exist := ErrorOnExist, times := Times}) ->
    Exists = element(1, prim_file:read_file_info(Target)) =:= ok,
    case {Exists, Force, ErrorOnExist} of
        {true, false, false} ->
            ok;
        {true, false, true} ->
            cp_error(<<"ERR_FS_CP_EEXIST">>,
                     [<<"[ERR_FS_CP_EEXIST]: Target already exists: cp returned EEXIST (">>, Target, <<" already exists)">>]);
        _ ->
            case copy_file(Entry, Target) of
                ok -> ok;
                {error, Reason} -> std_error(Reason, <<"cp">>, Dest)
            end,
            Times andalso copy_times(Entry, Target)
    end.

copy_symlink(Entry, Target, _Src, Dest, #{verbatim := true}) ->
    {ok, Link} = prim_file:read_link_all(Entry),
    case prim_file:make_symlink(Link, Target) of
        ok -> ok;
        {error, Reason} -> std_error(Reason, <<"cp">>, Dest)
    end;
copy_symlink(Entry, Target, Src, Dest, #{dereference := Dereference, force := Force, error_on_exist := ErrorOnExist}) ->
    Link = case prim_file:read_link_all(Entry) of
        {ok, L} -> name(L);
        {error, R} -> std_error(R, <<"cp">>, Dest)
    end,
    case prim_file:read_file_info(Target) of
        {ok, TargetInfo} ->
            case prim_file:read_link_all(Target) of
                {ok, Current0} ->
                    Current = name(Current0),
                    not Dereference andalso is_dir(Link) andalso inside(Link, Current) andalso
                        cp_error(<<"ERR_FS_CP_EINVAL">>, [<<"Cannot copy ">>, Link, <<" to a subdirectory of self ">>, Current]),
                    TargetInfo#file_info.type =:= directory andalso inside(Current, Link) andalso
                        cp_error(<<"ERR_FS_CP_SYMLINK_TO_SUBDIRECTORY">>, [<<"cannot overwrite ">>, Current, <<" with ">>, Link]),
                    case prim_file:delete(Target) of
                        ok -> ok;
                        {error, R2} -> std_error(R2, <<"cp">>, Dest)
                    end;
                _ when TargetInfo#file_info.type =:= regular, not Dereference orelse (not Force andalso ErrorOnExist) ->
                    std_error(eexist, <<"cp">>, Target);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    case prim_file:make_symlink(weakly_canonical(filename:join(absolute(Src), Link)), Target) of
        ok -> ok;
        {error, R3} -> std_error(R3, <<"cp">>, Dest)
    end.

%% Copies the bytes and the mode of a file, as std::filesystem::copy_file.
copy_file(Src, Dest) ->
    case file:open(Src, [raw, binary, read]) of
        {ok, From} ->
            try
                {ok, #file_info{mode = Mode}} = prim_file:read_handle_info(From),
                case file:open(Dest, [raw, binary, write]) of
                    {ok, To} ->
                        Copied = file:copy(From, To),
                        file:close(To),
                        case Copied of
                            {ok, _} -> buoy_binding_fs:result(buoy_native:fs_chmod(Dest, Mode band 8#7777, true));
                            Error -> Error
                        end;
                    Error ->
                        Error
                end
            after
                file:close(From)
            end;
        Error ->
            Error
    end.

%% CopyUtimes: the atime and mtime of src on dest, as seconds.
copy_times(Src, Dest) ->
    case buoy_binding_fs:read_stats(Src, follow) of
        {ok, [_, _, _, _, _, _, _, _, _, _, As, Ans, Ms, Mns | _]} ->
            case buoy_native:fs_utimes(Dest, As + Ans / 1.0e9, Ms + Mns / 1.0e9, true) of
                0 -> true;
                Code -> buoy_binding_fs:uv_error(buoy_binding_fs:reason(Code), <<"utime">>, Dest)
            end;
        {error, Reason} ->
            buoy_binding_fs:uv_error(Reason, <<"stat">>, Src)
    end.

%% std::filesystem::create_directories.
create_directories(Path) ->
    case mkdirs(Path) of
        ok -> ok;
        {error, Reason} -> std_error(Reason, <<"cp">>, Path)
    end.

mkdirs(Path) ->
    case prim_file:make_dir(Path) of
        {error, enoent} ->
            Parent = filename:dirname(Path),
            case Parent =/= Path andalso mkdirs(Parent) of
                ok -> mkdirs(Path);
                false -> {error, enoent};
                Error -> Error
            end;
        {error, eexist} ->
            case is_dir(Path) of
                true -> ok;
                false -> {error, eexist}
            end;
        Result ->
            Result
    end.

is_dir(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end.

%% Whether two paths name one file, as std::filesystem::equivalent.
equivalent(A, B) ->
    case {prim_file:read_file_info(A), prim_file:read_file_info(B)} of
        {{ok, IA}, {ok, IB}} ->
            {IA#file_info.major_device, IA#file_info.inode} =:= {IB#file_info.major_device, IB#file_info.inode};
        _ ->
            false
    end.

%% std::filesystem::path::parent_path on POSIX: <<>> for a name alone.
parent(Path) ->
    case string:split(Path, <<"/">>, trailing) of
        [_] -> <<>>;
        [<<>>, _] -> <<"/">>;
        [Head, _] -> Head
    end.

absolute(Path) ->
    {ok, Cwd} = prim_file:get_cwd(),
    filename:join(name(Cwd), Path).

%% isInsideDir: the parts of the absolute src lead the parts of dest.
inside(Src, Dest) ->
    S = filename:split(absolute(Src)),
    D = filename:split(absolute(Dest)),
    length(S) =< length(D) andalso lists:prefix(S, D).

%% std::filesystem::weakly_canonical: the real path of the longest prefix
%% that exists, and the rest without "." and "..".
weakly_canonical(Path) ->
    [Root | Parts] = filename:split(Path),
    canonical(Parts, Root).

canonical([], Acc) -> Acc;
canonical([<<".">> | Rest], Acc) -> canonical(Rest, Acc);
canonical([<<"..">> | Rest], Acc) -> canonical(Rest, filename:dirname(Acc));
canonical([Part | Rest], Acc) ->
    Next = filename:join(Acc, Part),
    case prim_file:read_link_all(Next) of
        {ok, Link} ->
            [First | More] = filename:split(name(Link)),
            Resolved = case filename:pathtype(First) of
                absolute -> canonical(More, First);
                _ -> canonical([First | More], Acc)
            end,
            canonical(Rest, Resolved);
        _ ->
            canonical(Rest, Next)
    end.

name(Name) when is_binary(Name) -> Name;
name(Name) -> unicode:characters_to_binary(Name).

text(Parts) -> buoy_ref_string:from_utf8(iolist_to_binary(Parts)).

-spec cp_error(binary(), iodata()) -> no_return().
cp_error(Code, Message) -> buoy_node:throw_code('Error', Code, text(Message)).

%% Environment::ThrowStdErrException: an ErrnoException with the message of
%% std::error_code.
-spec std_error(atom(), binary(), binary()) -> no_return().
std_error(Reason, Syscall, Path) ->
    buoy_binding_fs:errno_exception(Reason, Syscall, buoy_binding_fs:strerror(Reason), Path).
