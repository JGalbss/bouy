%% internalBinding('sea') (src/node_sea.cc): the assets of a single executable
%% application. Buoy runs no SEA blob, so the process is never one: lib/sea.js
%% then throws ERR_NOT_IN_SINGLE_EXECUTABLE_APPLICATION, as Node does when it
%% runs a script.
-module(buoy_binding_sea).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"isSea">>, F(<<"isSea">>, 0, fun(_, _) -> false end)},
        {<<"isExperimentalSeaWarningNeeded">>, F(<<"isExperimentalSeaWarningNeeded">>, 0, fun(_, _) -> false end)},
        {<<"getAsset">>, F(<<"getAsset">>, 1, fun(_, _) -> undefined end)},
        {<<"getAssetKeys">>, F(<<"getAssetKeys">>, 0, fun(_, _) -> buoy_heap:new_array([]) end)}]).
