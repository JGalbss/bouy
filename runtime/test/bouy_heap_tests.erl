-module(bouy_heap_tests).

-include_lib("eunit/include/eunit.hrl").

-define(P, {'$o', 'Object.prototype'}).

%% Each test runs in a fresh process, which is a fresh realm.
realm(Test) ->
    Self = self(),
    Pid = spawn(fun() ->
                        Result = try {ok, Test()} catch C:R:S -> {C, R, S} end,
                        Self ! {self(), Result}
                end),
    receive
        {Pid, {ok, Value}} -> Value;
        {Pid, Failure} -> erlang:error(Failure)
    end.

identity_test() ->
    realm(fun() ->
                  A = bouy_heap:new_object(?P),
                  B = A,
                  bouy_heap:set(B, <<"x">>, 1),
                  ?assertEqual(1, bouy_heap:get(A, <<"x">>)),
                  C = bouy_heap:new_object(?P),
                  ?assertNotEqual(A, C)
          end).

insertion_order_test() ->
    realm(fun() ->
                  O = bouy_heap:new_object(?P),
                  [bouy_heap:set(O, bouy_heap:to_key(K), 1) || K <- [<<"b">>, <<"a">>, <<"2">>, <<"c">>, 1, <<"10">>]],
                  ?assertEqual([1, 2, 10, <<"b">>, <<"a">>, <<"c">>], bouy_heap:own_keys(O)),
                  bouy_heap:delete(O, <<"b">>),
                  bouy_heap:set(O, <<"b">>, 2),
                  ?assertEqual([1, 2, 10, <<"a">>, <<"c">>, <<"b">>], bouy_heap:own_keys(O))
          end).

prototype_chain_test() ->
    realm(fun() ->
                  Base = bouy_heap:object(null, [{<<"greet">>, <<"hi">>}]),
                  Mid = bouy_heap:new_object(Base),
                  Leaf = bouy_heap:new_object(Mid),
                  ?assertEqual(<<"hi">>, bouy_heap:get(Leaf, <<"greet">>)),
                  ?assert(bouy_heap:has(Leaf, <<"greet">>)),
                  ?assertNot(bouy_heap:has_own(Leaf, <<"greet">>)),
                  bouy_heap:set(Leaf, <<"greet">>, <<"own">>),
                  ?assertEqual(<<"own">>, bouy_heap:get(Leaf, <<"greet">>)),
                  ?assertEqual(<<"hi">>, bouy_heap:get(Mid, <<"greet">>)),
                  ?assertEqual(undefined, bouy_heap:get(Leaf, <<"missing">>))
          end).

accessor_test() ->
    realm(fun() ->
                  Proto = bouy_heap:new_object(null),
                  Getter = bouy_heap:function(fun(This, []) -> bouy_heap:get(This, <<"_x">>) * 2 end),
                  Setter = bouy_heap:function(fun(This, [V]) -> bouy_heap:set(This, <<"_x">>, V) end),
                  bouy_heap:define(Proto, <<"x">>, #{get => Getter, set => Setter, enumerable => false, configurable => true}),
                  O = bouy_heap:new_object(Proto),
                  bouy_heap:set(O, <<"x">>, 21),
                  ?assertEqual(42, bouy_heap:get(O, <<"x">>)),
                  ?assertEqual(21, bouy_heap:get(O, <<"_x">>)),
                  ?assertNot(bouy_heap:has_own(O, <<"x">>)),
                  ReadOnly = bouy_heap:new_object(null),
                  bouy_heap:define(ReadOnly, <<"y">>, #{get => Getter}),
                  ?assertError({'$throw', _}, bouy_heap:set(bouy_heap:new_object(ReadOnly), <<"y">>, 1))
          end).

array_test() ->
    realm(fun() ->
                  A = bouy_heap:new_array([1, 2, 3]),
                  ?assertEqual(3, bouy_heap:get(A, <<"length">>)),
                  bouy_heap:set(A, 5, 6),
                  ?assertEqual(6, bouy_heap:get(A, <<"length">>)),
                  ?assertNot(bouy_heap:has_own(A, 4)),
                  ?assertEqual([1, 2, 3, undefined, undefined, 6], bouy_heap:array_items(A)),
                  bouy_heap:set(A, <<"length">>, 2),
                  ?assertEqual([1, 2], bouy_heap:array_items(A)),
                  ?assertEqual(undefined, bouy_heap:get(A, 5)),
                  ?assertEqual(0, bouy_heap:to_key(<<"0">>)),
                  ?assertEqual(<<"01">>, bouy_heap:to_key(<<"01">>)),
                  ?assertEqual(<<"4294967295">>, bouy_heap:to_key(<<"4294967295">>))
          end).

function_object_test() ->
    realm(fun() ->
                  F = bouy_heap:function(fun(_This, [X]) -> X + 1 end),
                  G = F,
                  bouy_heap:set(F, <<"calls">>, 0),
                  ?assertEqual(0, bouy_heap:get(G, <<"calls">>)),
                  ?assertEqual(2, bouy_heap:call(F, undefined, [1])),
                  Named = bouy_heap:function(fun(_, _) -> ok end, <<"named">>, 0, #{}),
                  ?assertEqual(<<"named">>, bouy_heap:get(Named, <<"name">>)),
                  ?assertEqual([], bouy_heap:enumerable_keys(Named)),
                  ?assertError({'$throw', _}, bouy_heap:call(1, undefined, []))
          end).

cell_test() ->
    realm(fun() ->
                  C = bouy_heap:cell(0),
                  Inc = fun() -> bouy_heap:cell_set(C, bouy_heap:cell_get(C) + 1) end,
                  Inc(), Inc(),
                  ?assertEqual(2, bouy_heap:cell_get(C))
          end).

symbol_test() ->
    realm(fun() ->
                  A = bouy_heap:symbol(<<"a">>),
                  ?assertNotEqual(A, bouy_heap:symbol(<<"a">>)),
                  ?assertEqual(bouy_heap:symbol_for(<<"k">>), bouy_heap:symbol_for(<<"k">>)),
                  O = bouy_heap:new_object(?P),
                  bouy_heap:set(O, A, 1),
                  bouy_heap:set(O, <<"s">>, 2),
                  ?assertEqual([<<"s">>, A], bouy_heap:own_keys(O)),
                  ?assertEqual([<<"s">>], bouy_heap:enumerable_keys(O)),
                  ?assertEqual(1, bouy_heap:get(O, A))
          end).

frozen_test() ->
    realm(fun() ->
                  O = bouy_heap:object(?P, [{<<"a">>, 1}]),
                  bouy_heap:freeze(O),
                  ?assertError({'$throw', _}, bouy_heap:set(O, <<"a">>, 2)),
                  ?assertError({'$throw', _}, bouy_heap:set(O, <<"b">>, 2)),
                  ?assertEqual(1, bouy_heap:get(O, <<"a">>))
          end).

gc_frees_unreachable_test() ->
    realm(fun() ->
                  Kept = bouy_heap:object(?P, [{<<"child">>, bouy_heap:new_object(?P)}]),
                  [bouy_heap:new_object(?P) || _ <- lists:seq(1, 100)],
                  #{live := Live, freed := Freed} = bouy_heap:gc([Kept]),
                  ?assertEqual(2, Live),
                  ?assertEqual(100, Freed),
                  Child = bouy_heap:get(Kept, <<"child">>),
                  ?assertEqual([], bouy_heap:own_keys(Child))
          end).

array_holes_test() ->
    realm(fun() ->
                  A = bouy_heap:new_array([undefined, 1]),
                  ?assert(bouy_heap:has_own(A, 0)),
                  bouy_heap:delete(A, 1),
                  ?assertNot(bouy_heap:has_own(A, 1)),
                  ?assertEqual([0], bouy_heap:own_keys(A)),
                  ?assertEqual(2, bouy_heap:array_push(A, [])),
                  ?assertEqual(4, bouy_heap:array_push(A, [x, y])),
                  ?assertEqual([undefined, undefined, x, y], bouy_heap:array_items(A))
          end).

gc_cycles_test() ->
    realm(fun() ->
                  A = bouy_heap:new_object(?P),
                  B = bouy_heap:object(?P, [{<<"a">>, A}]),
                  bouy_heap:set(A, <<"b">>, B),
                  ?assertMatch(#{live := 0, freed := 2}, bouy_heap:gc([])),
                  C = bouy_heap:new_object(?P),
                  bouy_heap:set(C, <<"self">>, C),
                  ?assertMatch(#{live := 1, freed := 0}, bouy_heap:gc([C]))
          end).

gc_traces_fun_env_test() ->
    realm(fun() ->
                  Counter = bouy_heap:cell(0),
                  Box = bouy_heap:object(?P, [{<<"n">>, 7}]),
                  Closure = bouy_heap:function(fun(_, _) -> {bouy_heap:cell_get(Counter), bouy_heap:get(Box, <<"n">>)} end),
                  Holder = bouy_heap:object(?P, [{<<"f">>, Closure}]),
                  [bouy_heap:cell(I) || I <- lists:seq(1, 10)],
                  #{live := Live} = bouy_heap:gc([Holder]),
                  %% The holder, the closure has no record, the cell, and the box.
                  ?assertEqual(4, Live),
                  ?assertEqual({0, 7}, bouy_heap:call(bouy_heap:get(Holder, <<"f">>), undefined, []))
          end).

gc_roots_in_pdict_test() ->
    realm(fun() ->
                  O = bouy_heap:new_object(?P),
                  erlang:put({module_binding, x}, O),
                  ?assertMatch(#{live := 1}, bouy_heap:gc([])),
                  erlang:erase({module_binding, x}),
                  ?assertMatch(#{live := 0, freed := 1}, bouy_heap:gc([]))
          end).

clone_preserves_shape_test() ->
    realm(fun() ->
                  Shared = bouy_heap:object(?P, [{<<"v">>, 1}]),
                  Root = bouy_heap:object(?P, [{<<"a">>, Shared}, {<<"b">>, Shared}, {<<"list">>, bouy_heap:new_array([1, <<"two">>])}]),
                  bouy_heap:set(Root, <<"self">>, Root),
                  Term = bouy_heap:clone_out(Root),
                  Copy = realm(fun() ->
                                       C = bouy_heap:clone_in(Term),
                                       A = bouy_heap:get(C, <<"a">>),
                                       bouy_heap:set(A, <<"v">>, 2),
                                       {bouy_heap:get(bouy_heap:get(C, <<"b">>), <<"v">>),
                                        bouy_heap:get(C, <<"self">>) =:= C,
                                        bouy_heap:array_items(bouy_heap:get(C, <<"list">>)),
                                        bouy_heap:own_keys(C)}
                               end),
                  ?assertEqual({2, true, [1, <<"two">>], [<<"a">>, <<"b">>, <<"list">>, <<"self">>]}, Copy),
                  ?assertEqual(1, bouy_heap:get(Shared, <<"v">>))
          end).

clone_rejects_functions_test() ->
    realm(fun() ->
                  O = bouy_heap:object(?P, [{<<"f">>, bouy_heap:function(fun(_, _) -> ok end)}]),
                  ?assertError({'$throw', _}, bouy_heap:clone_out(O))
          end).
