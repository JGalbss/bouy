%% internalBinding('url') (src/node_url.cc): the WHATWG URL parser of ada
%% that lib/internal/url calls.
-module(bouy_binding_url).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    bouy_node:object([{<<"urlComponents">>, bouy_node:typed_array(<<"Uint32Array">>, 9)}]
                     ++ bouy_node:stubs(<<"url">>, [<<"domainToASCII">>, <<"domainToUnicode">>, <<"format">>, <<"getOrigin">>,
                                                    <<"parse">>, <<"pathToFileURL">>, <<"update">>, <<"canParse">>])).
