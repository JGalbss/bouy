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
    ] ++ bouy_node:stubs(<<"credentials">>, [<<"initgroups">>, <<"setegid">>, <<"seteuid">>, <<"setgid">>,
                                             <<"setuid">>, <<"setgroups">>])).

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
