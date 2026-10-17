%% internalBinding('config') (src/node_config.cc): the features of the build.
%% Bouy has no OpenSSL, Intl, inspector, or tracing yet.
-module(bouy_binding_config).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    bouy_node:object([
        {<<"isDebugBuild">>, false}, {<<"openSSLIsBoringSSL">>, false}, {<<"hasOpenSSL">>, false},
        {<<"fipsMode">>, false}, {<<"hasIntl">>, false}, {<<"hasTracing">>, false},
        {<<"hasNodeOptions">>, true}, {<<"hasInspector">>, false}, {<<"noBrowserGlobals">>, false},
        {<<"bits">>, 64},
        {<<"getDefaultLocale">>, bouy_node:fn(<<"getDefaultLocale">>, 0, fun(_, _) -> <<"en-US">> end)}]).
