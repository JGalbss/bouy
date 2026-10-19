%% internalBinding('credentials') (src/node_credentials.cc): the user and the
%% group of the OS process, and the environment reads that ignore setuid.
-module(buoy_binding_credentials).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Id = fun(Flag) -> fun(_, _) -> id(Flag) end end,
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"safeGetenv">>, F(<<"safeGetenv">>, 1, fun(_, A) ->
            Name = unicode:characters_to_list(buoy_ref_string:to_utf8(buoy_ref:to_string(buoy_node:arg(1, A)))),
            case os:getenv(Name) of
                false -> undefined;
                Value -> buoy_node:string(Value)
            end
        end)},
        {<<"getTempDir">>, F(<<"getTempDir">>, 0, fun(_, _) ->
            case os:getenv("TMPDIR") of
                false -> <<"/tmp">>;
                Dir -> buoy_node:string(string:trim(Dir, trailing, "/"))
            end
        end)},
        {<<"implementsPosixCredentials">>, true},
        {<<"getuid">>, F(<<"getuid">>, 0, Id("-u"))},
        {<<"geteuid">>, F(<<"geteuid">>, 0, Id("-u"))},
        {<<"getgid">>, F(<<"getgid">>, 0, Id("-g"))},
        {<<"getegid">>, F(<<"getegid">>, 0, Id("-g"))},
        {<<"getgroups">>, F(<<"getgroups">>, 0, fun(_, _) ->
            buoy_heap:new_array([list_to_integer(G) || G <- string:lexemes(os:cmd("id -G"), " \n")])
        end)}
    ] ++ [{Name, F(Name, 1, fun(_, A) -> set_id(Kind, Name, buoy_node:arg(1, A)) end)}
          || {Name, Kind} <- [{<<"setuid">>, user}, {<<"seteuid">>, user}, {<<"setgid">>, group}, {<<"setegid">>, group}]]
      ++ [{<<"setgroups">>, F(<<"setgroups">>, 1, fun(_, A) -> set_groups(buoy_heap:array_items(buoy_node:arg(1, A))) end)},
          {<<"initgroups">>, F(<<"initgroups">>, 2, fun(_, A) -> init_groups(buoy_node:arg(1, A), buoy_node:arg(2, A)) end)}]).

%% setgroups(groups): the 1-based index of a name that is no group, as
%% node_credentials.cc returns it for ERR_UNKNOWN_CREDENTIAL, else the
%% syscall, which succeeds for root only.
set_groups(Groups) ->
    Unknown = [I || {I, G} <- lists:enumerate(Groups), not is_integer(G), find(group, G) =:= error],
    case Unknown of
        [First | _] -> First;
        [] -> root_only(<<"setgroups">>)
    end.

%% initgroups(user, extraGroup): 2 for an unknown group, which InitGroups
%% checks first, 1 for an unknown user.
init_groups(User, Group) ->
    case {is_integer(Group) orelse find(group, Group) =/= error, is_integer(User) orelse find(user, User) =/= error} of
        {false, _} -> 2;
        {_, false} -> 1;
        _ -> root_only(<<"initgroups">>)
    end.

root_only(Syscall) ->
    case id("-u") of
        0 -> 0;
        _ -> errno_error(<<"EPERM">>, <<"Operation not permitted">>, Syscall)
    end.

%% setuid and the others: the VM cannot change the ids of its OS process, so a
%% known id fails as the call fails for a user who is not root.
set_id(Kind, Syscall, Id) ->
    Number = case Id of
        N when is_integer(N) -> N;
        _ -> lookup(Kind, buoy_ref_string:to_utf8(buoy_ref:to_string(Id)))
    end,
    Current = case Kind of user -> id("-u"); group -> id("-g") end,
    case Number =:= Current of
        true -> undefined;
        false -> errno_error(<<"EPERM">>, <<"Operation not permitted">>, Syscall)
    end.

lookup(Kind, Name) ->
    case find(Kind, Name) of
        {ok, Number} -> Number;
        error ->
            What = case Kind of user -> <<"User">>; group -> <<"Group">> end,
            buoy_node:throw_code('Error', <<"ERR_UNKNOWN_CREDENTIAL">>,
                                 buoy_ref_string:from_utf8(<<What/binary, " identifier does not exist: ", Name/binary>>))
    end.

%% The id of a user or group name.
find(Kind, Value) when not is_binary(Value) -> find(Kind, buoy_ref_string:to_utf8(buoy_ref:to_string(Value)));
find(Kind, Name) ->
    Command = case Kind of
        user -> "id -u " ++ shell_word(Name) ++ " 2>/dev/null";
        group -> "(getent group " ++ shell_word(Name) ++ " | cut -d: -f3) 2>/dev/null || dscl . -read /Groups/"
                 ++ shell_word(Name) ++ " PrimaryGroupID 2>/dev/null | awk '{print $2}'"
    end,
    try {ok, list_to_integer(string:trim(os:cmd(Command)))}
    catch _:_ -> error
    end.

shell_word(Name) -> "'" ++ [C || C <- unicode:characters_to_list(Name), C =/= $'] ++ "'".

%% Node's ErrnoException: "<CODE>, <message>" with errno, code, and syscall.
-spec errno_error(binary(), binary(), binary()) -> no_return().
errno_error(Code, Text, Syscall) ->
    Message = <<Code/binary, ", ", Text/binary>>,
    E = buoy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
    [buoy_heap:define(E, K, #{value => V, writable => true, enumerable => true, configurable => true})
     || {K, V} <- [{<<"errno">>, -1}, {<<"code">>, Code}, {<<"syscall">>, Syscall}]],
    erlang:error({'$throw', E}).

%% The id of the OS process for the flag of id(1), read once per VM.
id(Flag) ->
    Key = {?MODULE, Flag},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Value = try list_to_integer(string:trim(os:cmd("id " ++ Flag)))
                    catch _:_ -> 0
                    end,
            persistent_term:put(Key, Value),
            Value;
        Value ->
            Value
    end.
