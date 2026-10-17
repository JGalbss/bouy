%% internalBinding('mksnapshot') (src/node_snapshotable.cc). Bouy builds no
%% startup snapshot.
-module(bouy_binding_mksnapshot).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Noop = fun(Name) -> {Name, bouy_node:fn(Name, 1, fun(_, _) -> undefined end)} end,
    bouy_node:object([Noop(N) || N <- [<<"setSerializeCallback">>, <<"setDeserializeCallback">>,
                                       <<"setDeserializeMainFunction">>]]
                     ++ [{<<"isBuildingSnapshotBuffer">>, bouy_node:typed_array(<<"Uint8Array">>, 1)},
                         {<<"anonymousMainPath">>, <<"__node_anonymous_main">>}]
                     ++ bouy_node:stubs(<<"mksnapshot">>, [<<"runEmbedderPreload">>, <<"compileSerializeMain">>])).
