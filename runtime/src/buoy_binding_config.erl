%% internalBinding('config') (src/node_config.cc): the features of the build.
%% Buoy has OpenSSL through OTP's crypto, and no Intl, inspector, or tracing yet.
-module(buoy_binding_config).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"isDebugBuild">>, false}, {<<"openSSLIsBoringSSL">>, false}, {<<"hasOpenSSL">>, true},
        {<<"fipsMode">>, false}, {<<"hasIntl">>, false}, {<<"hasTracing">>, false},
        {<<"hasNodeOptions">>, true}, {<<"hasInspector">>, false}, {<<"noBrowserGlobals">>, false},
        {<<"bits">>, 64},
        {<<"getDefaultLocale">>, buoy_node:fn(<<"getDefaultLocale">>, 0, fun(_, _) -> <<"en-US">> end)}]).
