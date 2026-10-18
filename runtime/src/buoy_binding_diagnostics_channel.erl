%% internalBinding('diagnostics_channel') (src/node_diagnostics_channel.cc):
%% the index of each named channel and the subscriber counts that the
%% native side would read.
-module(buoy_binding_diagnostics_channel).

-export([binding/0]).

-define(CHANNELS, '$buoy_node_channels').

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
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
        {<<"subscribers">>, buoy_node:typed_array(<<"Uint32Array">>, 1024)}]).
