%% internalBinding('builtins') (src/node_builtins.cc): the ids of the built-in
%% modules that the runtime holds, the function around the code of each, and
%% the build configuration that process.config parses.
-module(bouy_binding_builtins).

-export([binding/0]).

-spec binding() -> term().
binding() ->
    Ids = bouy_heap:new_array(bouy_node:ids()),
    bouy_node:object([
        {<<"builtinIds">>, Ids},
        {<<"config">>, config()},
        {<<"compileFunction">>, bouy_node:fn(<<"compileFunction">>, 1, fun(_, Args) ->
            bouy_node:compile(bouy_ref:to_string(bouy_ref_realm:arg(1, Args)))
        end)},
        {<<"hasCachedBuiltins">>, bouy_node:fn(<<"hasCachedBuiltins">>, 0, fun(_, _) -> true end)},
        {<<"setInternalLoaders">>, bouy_node:fn(<<"setInternalLoaders">>, 2, fun(_, Args) ->
            bouy_node:set_loaders(bouy_ref_realm:arg(1, Args), bouy_ref_realm:arg(2, Args)),
            undefined
        end)},
        {<<"getCacheUsage">>, bouy_node:fn(<<"getCacheUsage">>, 0, fun(_, _) ->
            bouy_node:object([{K, bouy_heap:new_array([])} || K <- [<<"compiledWithCache">>, <<"compiledWithoutCache">>, <<"compiledInSnapshot">>]])
        end)}
    ]).

%% The JSON of process.config: the variables that Node's lib and tests read.
%% Intl, OpenSSL, and the inspector are off, so the tests that need them skip.
config() ->
    Variables = #{
        asan => 0, coverage => false, debug_node => false, host_arch => bouy_node_process:arch(),
        target_arch => bouy_node_process:arch(), node_byteorder => <<"little">>,
        node_module_version => 141, napi_build_version => <<"10">>, node_no_browser_globals => false,
        node_shared => false, node_shared_openssl => false, node_use_amaro => false,
        node_use_openssl => false, node_use_node_snapshot => false, node_use_node_code_cache => false,
        node_use_v8_platform => true, node_use_quic => false, v8_enable_i18n_support => 0,
        v8_enable_inspector => 0, v8_enable_pointer_compression => 0, v8_enable_31bit_smis_on_64bit_arch => 0,
        single_executable_application => false, icu_small => false, is_debug => 0,
        node_builtin_shareable_builtins => []
    },
    Text = iolist_to_binary(json:encode(#{target_defaults => #{}, variables => Variables})),
    bouy_ref_string:from_utf8(Text).
