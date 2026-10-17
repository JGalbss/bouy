%% internalBinding('internal_only_v8') (src/internal_only_v8.cc): queryObjects,
%% which v8.queryObjects() and the heap tests of test/common call.
-module(bouy_binding_internal_only_v8).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    bouy_node:object([
        {<<"queryObjects">>, bouy_node:fn(<<"queryObjects">>, 0, fun(_, Args) ->
            query_objects(bouy_node:arg(1, Args))
        end)}
    ]).

%% The objects of the realm whose prototype chain holds Proto, as V8's
%% QueryObjects with Node's PrototypeChainHas predicate. The realm keeps its
%% objects in the process dictionary, under integer ids. Functions without a
%% record of their own are left out.
%% shortcut: no collection runs first, so garbage that the next gc frees still
%% counts; collect before the query once a binding can run gc/1 safely.
query_objects(Proto) ->
    case bouy_heap:is_object(Proto) of
        false ->
            undefined;
        true ->
            Ids = [Id || {Id, {Class, Parent, _, _, _, _}} <- erlang:get(), is_integer(Id), is_atom(Class),
                         Class =/= function, chain_has(Parent, Proto)],
            bouy_heap:new_array([{'$o', Id} || Id <- lists:sort(Ids)])
    end.

chain_has(null, _) -> false;
chain_has(Value, Proto) ->
    same(Value, Proto) orelse chain_has(bouy_heap:prototype_of(Value), Proto).

same(A, B) when is_tuple(A), is_tuple(B) -> element(2, A) =:= element(2, B);
same(_, _) -> false.
