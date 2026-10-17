-module(bouy_ref_realm_tests).

-include_lib("eunit/include/eunit.hrl").

%% While one realm installs the intrinsics, another realm that reads the global
%% object must see every global binding. An install that first wrote an empty
%% global object let a realm copy the empty one.
install_never_shows_a_partial_global_object_test() ->
    ok = bouy_ref_realm:install(),
    Self = self(),
    Watcher = spawn(fun() -> watch(Self, 0) end),
    [begin
         persistent_term:erase({bouy_ref_realm, installed}),
         ok = bouy_ref_realm:install()
     end || _ <- lists:seq(1, 20)],
    Watcher ! stop,
    receive
        {partial, Seen} -> ?assertEqual(0, Seen)
    end.

watch(Parent, Seen) ->
    receive
        stop -> Parent ! {partial, Seen}
    after 0 ->
        Partial = case persistent_term:get({bouy_heap, 'globalThis'}, undefined) of
            undefined -> 0;
            {_, _, Props, _, _, _} when is_map_key(<<"Array">>, Props) -> 0;
            _ -> 1
        end,
        watch(Parent, Seen + Partial)
    end.

global_object_holds_the_globals_test() ->
    Self = self(),
    spawn(fun() ->
                  ok = bouy_ref_realm:install(),
                  G = {'$o', 'globalThis'},
                  Self ! {result, bouy_heap:get(G, <<"Array">>) =:= bouy_ref_realm:global(<<"Array">>),
                          bouy_heap:get_own(G, <<"undefined">>)}
          end),
    receive
        {result, Same, Undefined} ->
            ?assert(Same),
            ?assertEqual({data, undefined, 0}, Undefined)
    end.

%%% Realms that create/0 makes in the same process

%% Runs Fun in a new process with the intrinsics installed: its result, or
%% the error it raised.
in_process(Fun) ->
    Self = self(),
    spawn(fun() ->
                  ok = bouy_ref_realm:install(),
                  Self ! {result, try {ok, Fun()} catch Class:Reason -> {Class, Reason} end}
          end),
    receive
        {result, Result} -> Result
    end.

get(O, K) -> bouy_ref:get(O, K).

%% The class of a thrown error: the realm that its prototype belongs to.
error_realm(Fun) ->
    try Fun() of
        _ -> no_error
    catch
        error:{'$throw', E} -> bouy_heap:prototype_of(E)
    end.

a_new_realm_has_its_own_intrinsics_test() ->
    {ok, {Twin, Proto, ProtoOfProto, Same, Constructor}} = in_process(fun() ->
        Other = bouy_ref_realm:create(),
        Array = get(Other, <<"Array">>),
        ArrayProto = get(Array, <<"prototype">>),
        {Array =/= bouy_ref_realm:global(<<"Array">>), ArrayProto, bouy_heap:prototype_of(ArrayProto),
         get(Other, <<"Array">>) =:= Array, get(ArrayProto, <<"constructor">>) =:= Array}
    end),
    ?assert(Twin),
    ?assertEqual({'$o', {1, 'Array.prototype'}}, Proto),
    ?assertEqual({'$o', {1, 'Object.prototype'}}, ProtoOfProto),
    ?assert(Same),
    ?assert(Constructor).

a_write_to_another_realm_leaves_the_first_realm_alone_test() ->
    {ok, {Mine, Theirs}} = in_process(fun() ->
        Other = bouy_ref_realm:create(),
        bouy_heap:set(get(get(Other, <<"Array">>), <<"prototype">>), <<"last">>, 1),
        {get({'$o', 'Array.prototype'}, <<"last">>), get(get(get(Other, <<"Array">>), <<"prototype">>), <<"last">>)}
    end),
    ?assertEqual(undefined, Mine),
    ?assertEqual(1, Theirs).

a_builtin_throws_the_errors_of_its_realm_test() ->
    {ok, {Theirs, Mine, After}} = in_process(fun() ->
        Other = bouy_ref_realm:create(),
        NotCallable = fun(Realm) ->
            Map = get(get(get(Realm, <<"Array">>), <<"prototype">>), <<"map">>),
            error_realm(fun() -> bouy_ref:call(Map, bouy_heap:new_array([]), [1]) end)
        end,
        {NotCallable(Other), NotCallable({'$o', 'globalThis'}), bouy_heap:realm()}
    end),
    ?assertEqual({'$o', {1, 'TypeError.prototype'}}, Theirs),
    ?assertEqual({'$o', 'TypeError.prototype'}, Mine),
    ?assertEqual(0, After).

get_function_realm_follows_proxies_and_bound_functions_test() ->
    {ok, Realms} = in_process(fun() ->
        _ = bouy_ref_realm:create(),
        Other = bouy_ref_realm:create(),
        Make = bouy_ref_realm:realm_fun(2, fun(_, _) -> bouy_heap:function(fun(_, _) -> undefined end, <<"f">>, 0, #{kind => normal}) end),
        F = Make(undefined, []),
        Proxy = bouy_heap:proxy(F, bouy_heap:new_object(null)),
        Bind = get(bouy_heap:function_prototype(), <<"bind">>),
        Bound = bouy_ref:call(Bind, F, [undefined]),
        [bouy_ref_realm:function_realm(V) || V <- [F, Proxy, Bound, get(Other, <<"Object">>), bouy_ref_realm:global(<<"Object">>)]]
    end),
    ?assertEqual([2, 2, 2, 2, 0], Realms).

get_prototype_from_constructor_uses_the_realm_of_new_target_test() ->
    {ok, {Proto, Expected}} = in_process(fun() ->
        Other = bouy_ref_realm:create(),
        Make = bouy_ref_realm:realm_fun(1, fun(_, _) -> bouy_heap:function(fun(_, _) -> undefined end, <<"f">>, 0, #{kind => normal}) end),
        NewTarget = Make(undefined, []),
        bouy_heap:set(NewTarget, <<"prototype">>, null),
        Map = bouy_heap:construct(bouy_ref_realm:global(<<"Map">>), [], NewTarget),
        {bouy_heap:prototype_of(Map), get(get(Other, <<"Map">>), <<"prototype">>)}
    end),
    ?assertEqual(Expected, Proto).

symbols_are_shared_across_realms_test() ->
    {ok, {Iterator, Registered}} = in_process(fun() ->
        Other = bouy_ref_realm:create(),
        Mine = bouy_ref_realm:global(<<"Symbol">>),
        Theirs = get(Other, <<"Symbol">>),
        For = fun(S) -> bouy_ref:call(get(S, <<"for">>), S, [<<"k">>]) end,
        {get(Mine, <<"iterator">>) =:= get(Theirs, <<"iterator">>), For(Mine) =:= For(Theirs)}
    end),
    ?assert(Iterator),
    ?assert(Registered).
