-module(buoy_heap_tests).

-include_lib("eunit/include/eunit.hrl").

%% The loader of the lazy intrinsic of lazy_intrinsic_test/0.
-export([load/1]).

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
                  A = buoy_heap:new_object(?P),
                  B = A,
                  buoy_heap:set(B, <<"x">>, 1),
                  ?assertEqual(1, buoy_heap:get(A, <<"x">>)),
                  C = buoy_heap:new_object(?P),
                  ?assertNotEqual(A, C)
          end).

insertion_order_test() ->
    realm(fun() ->
                  O = buoy_heap:new_object(?P),
                  [buoy_heap:set(O, buoy_heap:to_key(K), 1) || K <- [<<"b">>, <<"a">>, <<"2">>, <<"c">>, 1, <<"10">>]],
                  ?assertEqual([1, 2, 10, <<"b">>, <<"a">>, <<"c">>], buoy_heap:own_keys(O)),
                  buoy_heap:delete(O, <<"b">>),
                  buoy_heap:set(O, <<"b">>, 2),
                  ?assertEqual([1, 2, 10, <<"a">>, <<"c">>, <<"b">>], buoy_heap:own_keys(O))
          end).

prototype_chain_test() ->
    realm(fun() ->
                  Base = buoy_heap:object(null, [{<<"greet">>, <<"hi">>}]),
                  Mid = buoy_heap:new_object(Base),
                  Leaf = buoy_heap:new_object(Mid),
                  ?assertEqual(<<"hi">>, buoy_heap:get(Leaf, <<"greet">>)),
                  ?assert(buoy_heap:has(Leaf, <<"greet">>)),
                  ?assertNot(buoy_heap:has_own(Leaf, <<"greet">>)),
                  buoy_heap:set(Leaf, <<"greet">>, <<"own">>),
                  ?assertEqual(<<"own">>, buoy_heap:get(Leaf, <<"greet">>)),
                  ?assertEqual(<<"hi">>, buoy_heap:get(Mid, <<"greet">>)),
                  ?assertEqual(undefined, buoy_heap:get(Leaf, <<"missing">>))
          end).

accessor_test() ->
    realm(fun() ->
                  Proto = buoy_heap:new_object(null),
                  Getter = buoy_heap:function(fun(This, []) -> buoy_heap:get(This, <<"_x">>) * 2 end),
                  Setter = buoy_heap:function(fun(This, [V]) -> buoy_heap:set(This, <<"_x">>, V) end),
                  buoy_heap:define(Proto, <<"x">>, #{get => Getter, set => Setter, enumerable => false, configurable => true}),
                  O = buoy_heap:new_object(Proto),
                  buoy_heap:set(O, <<"x">>, 21),
                  ?assertEqual(42, buoy_heap:get(O, <<"x">>)),
                  ?assertEqual(21, buoy_heap:get(O, <<"_x">>)),
                  ?assertNot(buoy_heap:has_own(O, <<"x">>)),
                  ReadOnly = buoy_heap:new_object(null),
                  buoy_heap:define(ReadOnly, <<"y">>, #{get => Getter}),
                  ?assertError({'$throw', _}, buoy_heap:set(buoy_heap:new_object(ReadOnly), <<"y">>, 1))
          end).

array_test() ->
    realm(fun() ->
                  A = buoy_heap:new_array([1, 2, 3]),
                  ?assertEqual(3, buoy_heap:get(A, <<"length">>)),
                  buoy_heap:set(A, 5, 6),
                  ?assertEqual(6, buoy_heap:get(A, <<"length">>)),
                  ?assertNot(buoy_heap:has_own(A, 4)),
                  ?assertEqual([1, 2, 3, undefined, undefined, 6], buoy_heap:array_items(A)),
                  buoy_heap:set(A, <<"length">>, 2),
                  ?assertEqual([1, 2], buoy_heap:array_items(A)),
                  ?assertEqual(undefined, buoy_heap:get(A, 5)),
                  ?assertEqual(0, buoy_heap:to_key(<<"0">>)),
                  ?assertEqual(<<"01">>, buoy_heap:to_key(<<"01">>)),
                  ?assertEqual(<<"4294967295">>, buoy_heap:to_key(<<"4294967295">>))
          end).

function_object_test() ->
    realm(fun() ->
                  F = buoy_heap:function(fun(_This, [X]) -> X + 1 end),
                  G = F,
                  buoy_heap:set(F, <<"calls">>, 0),
                  ?assertEqual(0, buoy_heap:get(G, <<"calls">>)),
                  ?assertEqual(2, buoy_heap:call(F, undefined, [1])),
                  Named = buoy_heap:function(fun(_, _) -> ok end, <<"named">>, 0, #{}),
                  ?assertEqual(<<"named">>, buoy_heap:get(Named, <<"name">>)),
                  ?assertEqual([], buoy_heap:enumerable_keys(Named)),
                  ?assertError({'$throw', _}, buoy_heap:call(1, undefined, []))
          end).

cell_test() ->
    realm(fun() ->
                  C = buoy_heap:cell(0),
                  Inc = fun() -> buoy_heap:cell_set(C, buoy_heap:cell_get(C) + 1) end,
                  Inc(), Inc(),
                  ?assertEqual(2, buoy_heap:cell_get(C))
          end).

symbol_test() ->
    realm(fun() ->
                  A = buoy_heap:symbol(<<"a">>),
                  ?assertNotEqual(A, buoy_heap:symbol(<<"a">>)),
                  ?assertEqual(buoy_heap:symbol_for(<<"k">>), buoy_heap:symbol_for(<<"k">>)),
                  O = buoy_heap:new_object(?P),
                  buoy_heap:set(O, A, 1),
                  buoy_heap:set(O, <<"s">>, 2),
                  ?assertEqual([<<"s">>, A], buoy_heap:own_keys(O)),
                  ?assertEqual([<<"s">>], buoy_heap:enumerable_keys(O)),
                  ?assertEqual(1, buoy_heap:get(O, A))
          end).

frozen_test() ->
    realm(fun() ->
                  O = buoy_heap:object(?P, [{<<"a">>, 1}]),
                  buoy_heap:freeze(O),
                  ?assertError({'$throw', _}, buoy_heap:set(O, <<"a">>, 2)),
                  ?assertError({'$throw', _}, buoy_heap:set(O, <<"b">>, 2)),
                  ?assertEqual(1, buoy_heap:get(O, <<"a">>))
          end).

gc_frees_unreachable_test() ->
    realm(fun() ->
                  Kept = buoy_heap:object(?P, [{<<"child">>, buoy_heap:new_object(?P)}]),
                  [buoy_heap:new_object(?P) || _ <- lists:seq(1, 100)],
                  #{live := Live, freed := Freed} = buoy_heap:gc([Kept]),
                  ?assertEqual(2, Live),
                  ?assertEqual(100, Freed),
                  Child = buoy_heap:get(Kept, <<"child">>),
                  ?assertEqual([], buoy_heap:own_keys(Child))
          end).

array_holes_test() ->
    realm(fun() ->
                  A = buoy_heap:new_array([undefined, 1]),
                  ?assert(buoy_heap:has_own(A, 0)),
                  buoy_heap:delete(A, 1),
                  ?assertNot(buoy_heap:has_own(A, 1)),
                  ?assertEqual([0, <<"length">>], buoy_heap:own_keys(A)),
                  ?assertEqual([0], buoy_heap:enumerable_keys(A)),
                  ?assertEqual(2, buoy_heap:array_push(A, [])),
                  ?assertEqual(4, buoy_heap:array_push(A, [x, y])),
                  ?assertEqual([undefined, undefined, x, y], buoy_heap:array_items(A))
          end).

%% The length of an array is writable, not enumerable, and not
%% configurable, and a write converts the value with ToUint32.
array_length_rules_test() ->
    realm(fun() ->
                  A = buoy_heap:new_array([a, b, c]),
                  ?assertEqual({data, 3, 1}, buoy_heap:get_own(A, <<"length">>)),
                  buoy_heap:set(A, <<"length">>, <<"1">>),
                  ?assertEqual([a], buoy_heap:array_items(A)),
                  ?assertError({'$throw', _}, buoy_heap:set(A, <<"length">>, 1.5)),
                  ?assertError({'$throw', _}, buoy_heap:delete(A, <<"length">>)),
                  buoy_heap:define(A, <<"length">>, #{writable => false}),
                  ?assertEqual({data, 1, 0}, buoy_heap:get_own(A, <<"length">>)),
                  ?assertError({'$throw', _}, buoy_heap:set(A, 5, x)),
                  %% A read-only length keeps its value, and the length is never
                  %% configurable, enumerable, or an accessor.
                  ?assertError({'$throw', _}, buoy_heap:define(A, <<"length">>, #{value => 3})),
                  ?assertEqual(A, buoy_heap:define(A, <<"length">>, #{value => 1})),
                  B = buoy_heap:new_array([]),
                  ?assertError({'$throw', _}, buoy_heap:define(B, <<"length">>, #{configurable => true})),
                  ?assertError({'$throw', _}, buoy_heap:define(B, <<"length">>, #{enumerable => true})),
                  ?assertError({'$throw', _}, buoy_heap:define(B, <<"length">>, #{get => undefined}))
          end).

gc_cycles_test() ->
    realm(fun() ->
                  A = buoy_heap:new_object(?P),
                  B = buoy_heap:object(?P, [{<<"a">>, A}]),
                  buoy_heap:set(A, <<"b">>, B),
                  ?assertMatch(#{live := 0, freed := 2}, buoy_heap:gc([])),
                  C = buoy_heap:new_object(?P),
                  buoy_heap:set(C, <<"self">>, C),
                  ?assertMatch(#{live := 1, freed := 0}, buoy_heap:gc([C]))
          end).

gc_traces_fun_env_test() ->
    realm(fun() ->
                  Counter = buoy_heap:cell(0),
                  Box = buoy_heap:object(?P, [{<<"n">>, 7}]),
                  Closure = buoy_heap:function(fun(_, _) -> {buoy_heap:cell_get(Counter), buoy_heap:get(Box, <<"n">>)} end),
                  Holder = buoy_heap:object(?P, [{<<"f">>, Closure}]),
                  [buoy_heap:cell(I) || I <- lists:seq(1, 10)],
                  #{live := Live} = buoy_heap:gc([Holder]),
                  %% The holder, the closure has no record, the cell, and the box.
                  ?assertEqual(4, Live),
                  ?assertEqual({0, 7}, buoy_heap:call(buoy_heap:get(Holder, <<"f">>), undefined, []))
          end).

gc_roots_in_pdict_test() ->
    realm(fun() ->
                  O = buoy_heap:new_object(?P),
                  erlang:put({module_binding, x}, O),
                  ?assertMatch(#{live := 1}, buoy_heap:gc([])),
                  erlang:erase({module_binding, x}),
                  ?assertMatch(#{live := 0, freed := 1}, buoy_heap:gc([]))
          end).

clone_preserves_shape_test() ->
    realm(fun() ->
                  Shared = buoy_heap:object(?P, [{<<"v">>, 1}]),
                  Root = buoy_heap:object(?P, [{<<"a">>, Shared}, {<<"b">>, Shared}, {<<"list">>, buoy_heap:new_array([1, <<"two">>])}]),
                  buoy_heap:set(Root, <<"self">>, Root),
                  Term = buoy_heap:clone_out(Root),
                  Copy = realm(fun() ->
                                       C = buoy_heap:clone_in(Term),
                                       A = buoy_heap:get(C, <<"a">>),
                                       buoy_heap:set(A, <<"v">>, 2),
                                       {buoy_heap:get(buoy_heap:get(C, <<"b">>), <<"v">>),
                                        buoy_heap:get(C, <<"self">>) =:= C,
                                        buoy_heap:array_items(buoy_heap:get(C, <<"list">>)),
                                        buoy_heap:own_keys(C)}
                               end),
                  ?assertEqual({2, true, [1, <<"two">>], [<<"a">>, <<"b">>, <<"list">>, <<"self">>]}, Copy),
                  ?assertEqual(1, buoy_heap:get(Shared, <<"v">>))
          end).

clone_rejects_functions_test() ->
    realm(fun() ->
                  O = buoy_heap:object(?P, [{<<"f">>, buoy_heap:function(fun(_, _) -> ok end)}]),
                  ?assertError({'$throw', _}, buoy_heap:clone_out(O))
          end).

define_validates_test() ->
    realm(fun() ->
                  O = buoy_heap:new_object(?P),
                  ?assert(buoy_heap:define_own_property(O, <<"x">>, #{value => 1})),
                  ?assertEqual({data, 1, 0}, buoy_heap:get_own(O, <<"x">>)),
                  %% A non-configurable, non-writable property keeps its value and kind.
                  ?assertNot(buoy_heap:define_own_property(O, <<"x">>, #{value => 2})),
                  ?assertNot(buoy_heap:define_own_property(O, <<"x">>, #{get => undefined})),
                  ?assertNot(buoy_heap:define_own_property(O, <<"x">>, #{enumerable => true})),
                  ?assert(buoy_heap:define_own_property(O, <<"x">>, #{value => 1, writable => false})),
                  ?assert(buoy_heap:prevent_extensions(O)),
                  ?assertNot(buoy_heap:define_own_property(O, <<"y">>, #{value => 1}))
          end).

array_length_test() ->
    realm(fun() ->
                  A = buoy_heap:new_array([a, b, c, d]),
                  ?assert(buoy_heap:define_own_property(A, 1, #{configurable => false})),
                  %% Shrinking stops above the non-configurable element and reports failure.
                  ?assertNot(buoy_heap:define_own_property(A, <<"length">>, #{value => 0})),
                  ?assertEqual(2, buoy_heap:get(A, <<"length">>)),
                  ?assert(buoy_heap:define_own_property(A, <<"length">>, #{writable => false})),
                  ?assertNot(buoy_heap:define_own_property(A, 5, #{value => x})),
                  ?assertNot(buoy_heap:set(A, 5, x, A))
          end).

set_receiver_test() ->
    realm(fun() ->
                  Proto = buoy_heap:new_object(?P),
                  buoy_heap:define(Proto, <<"fixed">>, #{value => 1, writable => false}),
                  O = buoy_heap:new_object(Proto),
                  ?assertNot(buoy_heap:set(O, <<"fixed">>, 2, O)),
                  Receiver = buoy_heap:new_object(?P),
                  ?assert(buoy_heap:set(O, <<"other">>, 3, Receiver)),
                  ?assertEqual(3, buoy_heap:get(Receiver, <<"other">>)),
                  ?assertNot(buoy_heap:has_own(O, <<"other">>))
          end).

set_prototype_test() ->
    realm(fun() ->
                  A = buoy_heap:new_object(?P),
                  B = buoy_heap:new_object(A),
                  ?assertNot(buoy_heap:set_prototype(A, B)),
                  ?assertNot(buoy_heap:set_prototype(?P, A)),
                  ?assert(buoy_heap:set_prototype(B, null)),
                  ?assertEqual(null, buoy_heap:prototype_of(B))
          end).

mapped_arguments_test() ->
    realm(fun() ->
                  Cell = buoy_heap:cell(1),
                  Args = buoy_ref:mapped_arguments([1, 2], [Cell], undefined),
                  buoy_heap:set(Args, 0, 5),
                  ?assertEqual(5, buoy_heap:cell_get(Cell)),
                  buoy_heap:cell_set(Cell, 7),
                  ?assertEqual(7, buoy_heap:get(Args, 0)),
                  %% A non-writable define ends the mapping.
                  buoy_heap:define(Args, 0, #{writable => false}),
                  buoy_heap:cell_set(Cell, 9),
                  ?assertEqual(7, buoy_heap:get(Args, 0))
          end).

proxy_invariant_test() ->
    realm(fun() ->
                  Target = buoy_heap:new_object(?P),
                  buoy_heap:define(Target, <<"x">>, #{value => 1}),
                  Get = buoy_heap:function(fun(_, _) -> 2 end),
                  Handler = buoy_heap:object(?P, [{<<"get">>, Get}]),
                  Proxy = buoy_heap:proxy(Target, Handler),
                  %% A trap may not report another value for a fixed property.
                  ?assertError({'$throw', _}, buoy_heap:get(Proxy, <<"x">>)),
                  ?assertEqual(2, buoy_heap:get(Proxy, <<"y">>))
          end).

private_names_ignore_integrity_test() ->
    realm(fun() ->
                  O = buoy_heap:new_object(?P),
                  K = {'#', <<"C">>, <<"x">>},
                  buoy_heap:define(O, K, #{value => 1, writable => true, enumerable => true, configurable => true}),
                  buoy_heap:freeze(O),
                  %% Private names are no properties: freeze leaves them writable.
                  ?assertEqual(2, buoy_heap:set(O, K, 2)),
                  ?assertEqual(2, buoy_heap:get(O, K)),
                  N = buoy_heap:new_object(?P),
                  buoy_heap:prevent_extensions(N),
                  ?assertEqual(3, buoy_heap:set(N, {'#', <<"C">>, <<"y">>}, 3)),
                  ?assertEqual([], buoy_heap:own_keys(N))
          end).

weak_map_drops_dead_keys_test() ->
    realm(fun() ->
                  M = buoy_heap:new_exotic(weakmap, ?P, #{}),
                  Kept = buoy_heap:new_object(?P),
                  Value = buoy_heap:new_object(?P),
                  Dead = buoy_heap:new_object(?P),
                  buoy_heap:set_slots(M, #{Kept => Value, Dead => buoy_heap:new_object(?P)}),
                  buoy_heap:gc([M, Kept]),
                  %% The live key keeps its value, which nothing else holds; the dead key goes.
                  ?assertEqual(#{Kept => Value}, buoy_heap:slots(M)),
                  ?assertEqual(object, buoy_heap:class_of(Value)),
                  ?assertEqual(undefined, erlang:get(element(2, Dead)))
          end).

weak_ref_and_registry_test() ->
    realm(fun() ->
                  Target = buoy_heap:new_object(?P),
                  Ref = buoy_heap:new_exotic(weak_ref, ?P, Target),
                  Held = buoy_heap:new_object(?P),
                  Cleanup = buoy_heap:function(fun(_, [H]) -> erlang:put(cleaned, H) end),
                  Registry = buoy_heap:new_exotic(finalization_registry, ?P, {Cleanup, [{Target, Held, undefined}]}),
                  buoy_heap:gc([Ref, Registry]),
                  ?assertEqual(undefined, buoy_heap:slots(Ref)),
                  ?assertEqual({Cleanup, []}, buoy_heap:slots(Registry)),
                  buoy_jobs:drain(),
                  ?assertEqual(Held, erlang:get(cleaned))
          end).

%% A static record {lazy, Module} builds its record in each realm on the
%% first read, and only then.
lazy_intrinsic_test() ->
    buoy_heap:install_intrinsic('LazyProbe', {lazy, ?MODULE}),
    Lazy = {'$o', 'LazyProbe'},
    Read = fun() ->
                   First = buoy_heap:get(Lazy, <<"x">>),
                   buoy_heap:set(Lazy, <<"x">>, 2),
                   {First, buoy_heap:get(Lazy, <<"x">>), get(lazy_loads)}
           end,
    ?assertEqual({1, 2, 1}, realm(Read)),
    ?assertEqual({1, 2, 1}, realm(Read)),
    persistent_term:erase({buoy_heap, 'LazyProbe'}).

-spec load(atom()) -> tuple().
load(Id) ->
    put(lazy_loads, length([x || get(lazy_loads) =/= undefined]) + 1),
    Record = {object, ?P, #{<<"x">> => 1}, [<<"x">>], #{}, none},
    put(Id, Record),
    Record.

%% An object that gains plain data properties keeps a shape: its record holds
%% the values in a tuple, and objects with the same keys in the same order
%% share the shape.
shapes_share_test() ->
    realm(fun() ->
                  A = buoy_heap:new_object(?P),
                  B = buoy_heap:new_object(?P),
                  [buoy_heap:set(O, K, V) || O <- [A, B], {K, V} <- [{<<"x">>, 1}, {<<"y">>, 2}]],
                  {'$o', IdA} = A,
                  {'$o', IdB} = B,
                  ?assertMatch({{'$shape', _, {<<"x">>, <<"y">>}, _}, ?P, 1, 2}, erlang:get(IdA)),
                  ?assertEqual(element(1, erlang:get(IdA)), element(1, erlang:get(IdB))),
                  buoy_heap:set(A, <<"x">>, 10),
                  ?assertEqual(10, buoy_heap:get(A, <<"x">>)),
                  ?assertEqual(1, buoy_heap:get(B, <<"x">>)),
                  ?assertEqual([<<"x">>, <<"y">>], buoy_heap:own_keys(A)),
                  ?assertEqual({data, 2, 7}, buoy_heap:get_own(A, <<"y">>)),
                  ?assert(buoy_heap:has(A, <<"y">>)),
                  ?assertEqual(object, buoy_heap:class_of(A)),
                  ?assertEqual(none, buoy_heap:slots(A))
          end).

%% A delete, an accessor, an attribute, an index key, or a frozen object
%% leaves the shape for the record of every other object, with the same
%% properties in the same order.
shapes_leave_test() ->
    realm(fun() ->
                  Changes = [fun(O) -> buoy_heap:delete(O, <<"a">>) end,
                             fun(O) -> buoy_heap:define(O, <<"g">>, #{get => undefined, enumerable => true, configurable => true}) end,
                             fun(O) -> buoy_heap:define(O, <<"a">>, #{enumerable => false}) end,
                             fun(O) -> buoy_heap:set(O, 0, zero) end,
                             fun(O) -> buoy_heap:set(O, buoy_heap:well_known(iterator), it) end,
                             fun(O) -> buoy_heap:freeze(O) end,
                             fun(O) -> buoy_heap:prevent_extensions(O) end],
                  Results = [begin
                                 O = buoy_heap:new_object(?P),
                                 buoy_heap:set(O, <<"a">>, 1),
                                 buoy_heap:set(O, <<"b">>, 2),
                                 _ = Change(O),
                                 {'$o', Id} = O,
                                 {element(1, erlang:get(Id)), buoy_heap:own_keys(O), buoy_heap:enumerable_keys(O)}
                             end || Change <- Changes],
                  ?assertEqual([{object, [<<"b">>], [<<"b">>]},
                                {object, [<<"a">>, <<"b">>, <<"g">>], [<<"a">>, <<"b">>, <<"g">>]},
                                {object, [<<"a">>, <<"b">>], [<<"b">>]},
                                {object, [0, <<"a">>, <<"b">>], [0, <<"a">>, <<"b">>]},
                                {object, [<<"a">>, <<"b">>, buoy_heap:well_known(iterator)], [<<"a">>, <<"b">>]},
                                {object, [<<"a">>, <<"b">>], [<<"a">>, <<"b">>]},
                                {object, [<<"a">>, <<"b">>], [<<"a">>, <<"b">>]}], Results)
          end).

%% A new key of a shaped object still meets a setter or a read-only property
%% up the prototype chain.
shapes_inherited_setter_test() ->
    realm(fun() ->
                  Self = self(),
                  Proto = buoy_heap:new_object(?P),
                  Setter = buoy_heap:function(fun(This, [V]) -> Self ! {set, This, V}, undefined end),
                  buoy_heap:define(Proto, <<"s">>, #{set => Setter, configurable => true}),
                  buoy_heap:define(Proto, <<"r">>, #{value => 1, writable => false}),
                  O = buoy_heap:new_object(Proto),
                  buoy_heap:set(O, <<"s">>, 5),
                  ?assertEqual(ok, receive {set, O, 5} -> ok after 0 -> missing end),
                  ?assertError({'$throw', _}, buoy_heap:set(O, <<"r">>, 2)),
                  ?assertEqual([], buoy_heap:own_keys(O))
          end).

%% get_slot/3 and set_slot/4 read and write the slot when the key is at the
%% expected position, and fall back to [[Get]] and [[Set]] otherwise.
slots_test() ->
    realm(fun() ->
                  O = buoy_heap:literal_shaped({<<"a">>, <<"b">>}, {'_', ?P, 1, 2}),
                  ?assertEqual(2, buoy_heap:get_slot(O, <<"b">>, 2)),
                  ?assertEqual(2, buoy_heap:get_slot(O, <<"b">>, 1)),
                  ?assertEqual(2, buoy_heap:get_slot(O, <<"b">>, 9)),
                  ?assertEqual(undefined, buoy_heap:get_slot(O, <<"c">>, 1)),
                  ?assertEqual(3, buoy_heap:set_slot(O, <<"b">>, 3, 2)),
                  ?assertEqual(4, buoy_heap:set_slot(O, <<"c">>, 4, 3)),
                  ?assertEqual([<<"a">>, <<"b">>, <<"c">>], buoy_heap:own_keys(O)),
                  ?assertEqual({3, 4}, {buoy_heap:get(O, <<"b">>), buoy_heap:get(O, <<"c">>)}),
                  buoy_heap:delete(O, <<"a">>),
                  ?assertEqual(3, buoy_heap:get_slot(O, <<"b">>, 2)),
                  ?assertEqual(5, buoy_heap:set_slot(O, <<"b">>, 5, 2)),
                  ?assertEqual(5, buoy_heap:get(O, <<"b">>)),
                  ?assertError({'$throw', _}, buoy_heap:get_slot(undefined, <<"b">>, 1)),
                  ?assertEqual(undefined, buoy_heap:get_slot(7, <<"b">>, 1))
          end).

%% The collector marks the values of a shaped record.
gc_traces_shaped_values_test() ->
    realm(fun() ->
                  Child = buoy_heap:new_object(?P),
                  Holder = buoy_heap:new_object(?P),
                  [buoy_heap:set(Holder, K, Child) || K <- [<<"a">>, <<"b">>, <<"c">>, <<"d">>]],
                  [buoy_heap:new_object(?P) || _ <- lists:seq(1, 5)],
                  ?assertMatch(#{live := 2, freed := 5}, buoy_heap:gc([Holder])),
                  ?assertEqual([], buoy_heap:own_keys(buoy_heap:get(Holder, <<"d">>)))
          end).

%% A shape has at most 64 keys: the next key moves the object out of shapes.
shape_size_limit_test() ->
    realm(fun() ->
                  O = buoy_heap:new_object(?P),
                  Keys = [integer_to_binary(I) || I <- lists:seq(1, 70)],
                  Named = [<<"k", K/binary>> || K <- Keys],
                  [buoy_heap:set(O, K, K) || K <- Named],
                  ?assertEqual(Named, buoy_heap:own_keys(O)),
                  ?assertEqual(<<"k70">>, buoy_heap:get(O, <<"k70">>)),
                  {'$o', Id} = O,
                  ?assertEqual(object, element(1, erlang:get(Id)))
          end).
