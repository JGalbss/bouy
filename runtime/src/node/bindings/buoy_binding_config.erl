%% internalBinding('config') (src/node_config.cc): the features of the build.
%% Buoy has no OpenSSL, Intl, or inspector yet.
-module(buoy_binding_config).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"isDebugBuild">>, false}, {<<"openSSLIsBoringSSL">>, false}, {<<"hasOpenSSL">>, false},
        {<<"fipsMode">>, false}, {<<"hasIntl">>, false}, {<<"hasTracing">>, true},
        {<<"hasNodeOptions">>, true}, {<<"hasInspector">>, false}, {<<"noBrowserGlobals">>, false},
        {<<"bits">>, 64},
        {<<"getDefaultLocale">>, buoy_node:fn(<<"getDefaultLocale">>, 0, fun(_, _) -> <<"en-US">> end)}]).
