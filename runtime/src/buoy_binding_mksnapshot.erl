%% internalBinding('mksnapshot') (src/node_snapshotable.cc). Buoy builds no
%% startup snapshot.
-module(buoy_binding_mksnapshot).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Noop = fun(Name) -> {Name, buoy_node:fn(Name, 1, fun(_, _) -> undefined end)} end,
    buoy_node:object([Noop(N) || N <- [<<"setSerializeCallback">>, <<"setDeserializeCallback">>,
                                       <<"setDeserializeMainFunction">>]]
                     ++ [{<<"isBuildingSnapshotBuffer">>, buoy_node:typed_array(<<"Uint8Array">>, 1)},
                         {<<"anonymousMainPath">>, <<"__node_anonymous_main">>}]
                     ++ buoy_node:stubs(<<"mksnapshot">>, [<<"runEmbedderPreload">>, <<"compileSerializeMain">>])).
