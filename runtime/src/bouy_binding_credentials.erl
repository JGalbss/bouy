%% internalBinding('credentials') (src/node_credentials.cc): the user and the
%% group of the OS process, and the environment reads that ignore setuid.
-module(bouy_binding_credentials).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Id = fun(Flag) -> fun(_, _) -> id(Flag) end end,
    F = fun bouy_node:fn/3,
    bouy_node:object([
        {<<"safeGetenv">>, F(<<"safeGetenv">>, 1, fun(_, A) ->
            Name = unicode:characters_to_list(bouy_ref_string:to_utf8(bouy_ref:to_string(bouy_node:arg(1, A)))),
            case os:getenv(Name) of
                false -> undefined;
                Value -> bouy_node:string(Value)
            end
        end)},
        {<<"getTempDir">>, F(<<"getTempDir">>, 0, fun(_, _) ->
            case os:getenv("TMPDIR") of
                false -> <<"/tmp">>;
                Dir -> bouy_node:string(string:trim(Dir, trailing, "/"))
            end
        end)},
        {<<"implementsPosixCredentials">>, true},
        {<<"getuid">>, F(<<"getuid">>, 0, Id("-u"))},
        {<<"geteuid">>, F(<<"geteuid">>, 0, Id("-u"))},
        {<<"getgid">>, F(<<"getgid">>, 0, Id("-g"))},
        {<<"getegid">>, F(<<"getegid">>, 0, Id("-g"))},
        {<<"getgroups">>, F(<<"getgroups">>, 0, fun(_, _) ->
            bouy_heap:new_array([list_to_integer(G) || G <- string:lexemes(os:cmd("id -G"), " \n")])
        end)}
    ] ++ [{Name, F(Name, 1, fun(_, A) -> set_id(Kind, Name, bouy_node:arg(1, A)) end)}
          || {Name, Kind} <- [{<<"setuid">>, user}, {<<"seteuid">>, user}, {<<"setgid">>, group}, {<<"setegid">>, group}]]
      ++ [{Name, F(Name, 2, fun(_, _) -> set_groups(Name) end)} || Name <- [<<"initgroups">>, <<"setgroups">>]]).

%% initgroups and setgroups succeed for root only.
set_groups(Syscall) ->
    case id("-u") of
        0 -> undefined;
        _ -> errno_error(<<"EPERM">>, <<"Operation not permitted">>, Syscall)
    end.

%% setuid and the others: the VM cannot change the ids of its OS process, so a
%% known id fails as the call fails for a user who is not root.
set_id(Kind, Syscall, Id) ->
    Number = case Id of
        N when is_integer(N) -> N;
        _ -> lookup(Kind, bouy_ref_string:to_utf8(bouy_ref:to_string(Id)))
    end,
    Current = case Kind of user -> id("-u"); group -> id("-g") end,
    case Number =:= Current of
        true -> undefined;
        false -> errno_error(<<"EPERM">>, <<"Operation not permitted">>, Syscall)
    end.

lookup(Kind, Name) ->
    Command = case Kind of
        user -> "id -u " ++ shell_word(Name) ++ " 2>/dev/null";
        group -> "(getent group " ++ shell_word(Name) ++ " | cut -d: -f3) 2>/dev/null || dscl . -read /Groups/"
                 ++ shell_word(Name) ++ " PrimaryGroupID 2>/dev/null | awk '{print $2}'"
    end,
    try list_to_integer(string:trim(os:cmd(Command)))
    catch _:_ ->
        What = case Kind of user -> <<"User">>; group -> <<"Group">> end,
        bouy_node:throw_code('Error', <<"ERR_UNKNOWN_CREDENTIAL">>,
                             bouy_ref_string:from_utf8(<<What/binary, " identifier does not exist: ", Name/binary>>))
    end.

shell_word(Name) -> "'" ++ [C || C <- unicode:characters_to_list(Name), C =/= $'] ++ "'".

%% Node's ErrnoException: "<CODE>, <message>" with errno, code, and syscall.
-spec errno_error(binary(), binary(), binary()) -> no_return().
errno_error(Code, Text, Syscall) ->
    Message = <<Code/binary, ", ", Text/binary>>,
    E = bouy_heap:error_object('Error', Message, <<"Error: ", Message/binary>>),
    [bouy_heap:define(E, K, #{value => V, writable => true, enumerable => true, configurable => true})
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
