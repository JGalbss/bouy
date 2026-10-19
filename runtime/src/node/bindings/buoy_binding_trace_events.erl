%% internalBinding('trace_events') (src/node_trace_events.cc), with trace and
%% isTraceCategoryEnabled, which V8's builtins-trace.cc gives Node. The
%% categories and the writer belong to the VM (buoy_trace); this realm keeps
%% the buffers of getCategoryEnabledBuffer and the handler that lib toggles
%% the async_hooks tracing with.
-module(buoy_binding_trace_events).

-export([binding/0, trace/2]).

-include("buoy_ref.hrl").

-define(SET, {'#', ?MODULE, <<"categories">>}).
%% #{Group => [Uint8Array]}: the buffers of getCategoryEnabledBuffer.
-define(BUFFERS, '$buoy_trace_buffers').

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    A = fun buoy_node:arg/2,
    CategorySet = buoy_node:constructor(<<"CategorySet">>, 1, fun(This, Args) ->
        Categories = [utf8(C) || C <- buoy_heap:array_items(A(1, Args))],
        buoy_heap:private_put(This, ?SET, {Categories, false}),
        undefined
    end),
    Proto = buoy_heap:get(CategorySet, <<"prototype">>),
    [buoy_heap:define(Proto, Name, #{value => F(Name, 0, Fun), writable => true, enumerable => false, configurable => true})
     || {Name, Fun} <- [{<<"enable">>, fun(This, _) -> toggle(This, true) end},
                        {<<"disable">>, fun(This, _) -> toggle(This, false) end}]],
    buoy_node:object([
        {<<"CategorySet">>, CategorySet},
        {<<"getEnabledCategories">>, F(<<"getEnabledCategories">>, 0, fun(_, _) ->
            case buoy_trace:categories() of
                [] -> undefined;
                Categories -> buoy_ref_string:from_utf8(iolist_to_binary(lists:join(<<",">>, Categories)))
            end
        end)},
        {<<"setTraceCategoryStateUpdateHandler">>, F(<<"setTraceCategoryStateUpdateHandler">>, 1, fun(_, Args) ->
            buoy_node_loop:set_callback(trace_category_state, A(1, Args)),
            undefined
        end)},
        {<<"getCategoryEnabledBuffer">>, F(<<"getCategoryEnabledBuffer">>, 1, fun(_, Args) -> buffer(utf8(A(1, Args))) end)},
        {<<"isTraceCategoryEnabled">>, F(<<"isTraceCategoryEnabled">>, 1, fun(_, Args) ->
            buoy_trace:enabled(category(A(1, Args)))
        end)},
        {<<"trace">>, F(<<"trace">>, 5, fun ?MODULE:trace/2)}]).

%% Builtin Trace of V8: trace(phase, category, name, id, data) records an
%% event when its category group is enabled, with data as JSON in args.data.
-spec trace(term(), list()) -> boolean().
trace(_This, Args) ->
    [Phase, Category, Name, Id, Data] = [buoy_node:arg(I, Args) || I <- lists:seq(1, 5)],
    Group = category(Category),
    case buoy_trace:enabled(Group) of
        false ->
            false;
        true ->
            is_number(Phase) orelse type_error(<<"Trace event phase must be a number.">>),
            ?IS_STRING(Name) orelse type_error(<<"Trace event name must be a string.">>),
            Name =:= <<>> andalso type_error(<<"Trace event name must not be an empty string.">>),
            EventId = case Id of
                undefined -> none;
                null -> none;
                N when is_number(N) -> int32(N);
                _ -> type_error(<<"Trace event id must be a number.">>)
            end,
            Fields = case Data of
                undefined -> [];
                _ ->
                    case buoy_ref_json:stringify(Data, undefined, undefined) of
                        undefined -> [];
                        Json -> [{<<"data">>, {json, buoy_ref_string:to_utf8(Json)}}]
                    end
            end,
            buoy_trace:event(int32(Phase) band 16#FF, Group, buoy_ref_string:to_utf8(Name), EventId, Fields),
            true
    end.

category(Category) when ?IS_STRING(Category) -> buoy_ref_string:to_utf8(Category);
category(_) -> type_error(<<"Trace event category must be a string.">>).

-spec type_error(binary()) -> no_return().
type_error(Message) -> buoy_heap:throw_error('TypeError', Message).

%% DoubleToInt32.
int32(N) when is_integer(N) -> wrap32(N);
int32(N) when is_float(N), N == N, N - N == 0 -> wrap32(trunc(N));
int32(_) -> 0.

wrap32(N) ->
    case N band 16#FFFFFFFF of
        U when U >= 16#80000000 -> U - 16#100000000;
        U -> U
    end.

utf8(Value) -> buoy_ref_string:to_utf8(buoy_ref:to_string(Value)).

%% NodeCategorySet::Enable starts the agent, as a command line without
%% categories leaves it stopped, and adds the categories once; Disable
%% removes them.
toggle(This, Enable) ->
    {ok, {Categories, Enabled}} = buoy_heap:private_find(This, ?SET),
    case {Enable, Enabled} of
        {true, false} when Categories =/= [] ->
            buoy_trace:start(),
            buoy_trace:add(Categories),
            buoy_heap:private_put(This, ?SET, {Categories, true}),
            changed();
        {false, true} ->
            buoy_trace:remove(Categories),
            buoy_heap:private_put(This, ?SET, {Categories, false}),
            changed();
        _ ->
            ok
    end,
    undefined.

%% TrackingTraceStateObserver: the buffers of this realm show the new state,
%% and lib's handler learns whether node.async_hooks is traced.
changed() ->
    maps:foreach(fun(Group, Buffers) ->
        State = case buoy_trace:enabled(Group) of true -> 1; false -> 0 end,
        [buoy_heap:set(B, 0, State) || B <- Buffers]
    end, buffers()),
    case buoy_node_loop:callback(trace_category_state) of
        undefined -> ok;
        Handler -> _ = buoy_heap:call(Handler, undefined, [buoy_trace:enabled(<<"node.async_hooks">>)]), ok
    end.

%% A Uint8Array whose byte 0 is 1 while Group is enabled.
buffer(Group) ->
    Buffer = buoy_node:typed_array(<<"Uint8Array">>, 1),
    buoy_heap:set(Buffer, 0, case buoy_trace:enabled(Group) of true -> 1; false -> 0 end),
    erlang:put(?BUFFERS, maps:update_with(Group, fun(Bs) -> [Buffer | Bs] end, [Buffer], buffers())),
    Buffer.

buffers() ->
    case erlang:get(?BUFFERS) of
        undefined -> #{};
        B -> B
    end.
