%% internalBinding('diagnostics_channel') (src/node_diagnostics_channel.cc):
%% the index of each named channel and the subscriber counts that lib keeps
%% for the native side, which checks them before it publishes, as
%% diagnostics_channel::Channel::HasSubscribers does.
-module(buoy_binding_diagnostics_channel).

-export([binding/0, has_subscribers/1, trace_sync/3, trace_promise/3]).

-define(CHANNELS, '$buoy_node_channels').
-define(SUBSCRIBERS, '$buoy_node_channel_subscribers').

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    Subscribers = buoy_node:typed_array(<<"Uint32Array">>, 1024),
    erlang:put(?SUBSCRIBERS, Subscribers),
    buoy_node:object([
        {<<"getOrCreateChannelIndex">>, F(<<"getOrCreateChannelIndex">>, 1, fun(_, A) ->
            Name = buoy_node:arg(1, A),
            Channels = case erlang:get(?CHANNELS) of undefined -> #{}; C -> C end,
            case Channels of
                #{Name := Index} -> Index;
                _ ->
                    Index = map_size(Channels),
                    erlang:put(?CHANNELS, Channels#{Name => Index}),
                    Index
            end
        end)},
        {<<"linkNativeChannel">>, F(<<"linkNativeChannel">>, 1, fun(_, _) -> undefined end)},
        {<<"subscribers">>, Subscribers}]).

%% Whether the channel Name has a subscriber.
-spec has_subscribers(binary()) -> boolean().
has_subscribers(Name) ->
    case erlang:get(?CHANNELS) of
        #{Name := Index} -> buoy_heap:get(erlang:get(?SUBSCRIBERS), Index) > 0;
        _ -> false
    end.

%% TracingChannel.traceSync of the tracing channel Name around Fun, with a
%% context of the pairs that Context returns, when the channel has a
%% subscriber; else Fun().
-spec trace_sync(binary(), fun(() -> [{binary(), term()}]), fun(() -> term())) -> term().
trace_sync(Name, Context, Fun) ->
    case is_traced(Name) of
        true -> trace(Name, <<"traceSync">>, Context(), Fun);
        false -> Fun()
    end.

%% TracingChannel.tracePromise: Fun returns a promise, and the call returns
%% the promise of the trace, which settles with it.
-spec trace_promise(binary(), fun(() -> [{binary(), term()}]), fun(() -> term())) -> term().
trace_promise(Name, Context, Fun) ->
    case is_traced(Name) of
        true -> trace(Name, <<"tracePromise">>, Context(), Fun);
        false -> Fun()
    end.

is_traced(Name) ->
    buoy_node:ready() andalso erlang:get(?CHANNELS) =/= undefined
        andalso lists:any(fun(Event) -> has_subscribers(<<"tracing:", Name/binary, ":", Event/binary>>) end,
                          [<<"start">>, <<"end">>, <<"asyncStart">>, <<"asyncEnd">>, <<"error">>]).

trace(Name, Method, Pairs, Fun) ->
    {ok, Channels} = buoy_node:require(<<"diagnostics_channel">>),
    Tracing = buoy_heap:call(buoy_heap:get(Channels, <<"tracingChannel">>), Channels, [Name]),
    Traced = buoy_node:fn(<<>>, 0, fun(_, _) -> Fun() end),
    buoy_heap:call(buoy_heap:get(Tracing, Method), Tracing, [Traced, buoy_heap:object(null, Pairs)]).
