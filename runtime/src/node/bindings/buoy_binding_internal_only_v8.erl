%% internalBinding('internal_only_v8') (src/internal_only_v8.cc): queryObjects,
%% which v8.queryObjects() and the heap tests of test/common call.
-module(buoy_binding_internal_only_v8).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"queryObjects">>, buoy_node:fn(<<"queryObjects">>, 0, fun(_, Args) ->
            query_objects(buoy_node:arg(1, Args))
        end)}
    ]).

%% The objects of the realm whose prototype chain holds Proto, as V8's
%% QueryObjects with Node's PrototypeChainHas predicate. The realm keeps its
%% objects in the process dictionary, under integer ids. Functions without a
%% record of their own are left out.
%% shortcut: no collection runs first, so garbage that the next gc frees still
%% counts; collect before the query once a binding can run gc/1 safely.
query_objects(Proto) ->
    case buoy_heap:is_object(Proto) of
        false ->
            undefined;
        true ->
            Ids = [Id || {Id, R} <- erlang:get(), is_integer(Id), is_object_record(R),
                         buoy_heap:class_of({'$o', Id}) =/= function, chain_has(element(2, R), Proto)],
            buoy_heap:new_array([{'$o', Id} || Id <- lists:sort(Ids)])
    end.

%% An object record: {Class, Proto, ...} with six elements, or a shaped record
%% (buoy_heap). A cell holds a JavaScript value, which is neither.
is_object_record({Class, _, _, _, _, _}) when is_atom(Class) -> true;
is_object_record(R) when is_tuple(R), tuple_size(R) >= 2, is_tuple(element(1, R)) -> element(1, element(1, R)) =:= '$shape';
is_object_record(_) -> false.

chain_has(null, _) -> false;
chain_has(Value, Proto) ->
    same(Value, Proto) orelse chain_has(buoy_heap:prototype_of(Value), Proto).

same(A, B) when is_tuple(A), is_tuple(B) -> element(2, A) =:= element(2, B);
same(_, _) -> false.
