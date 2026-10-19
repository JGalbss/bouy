%% The jobs of internalBinding('crypto') (CryptoJob of src/crypto/crypto_util.h):
%% `new Job(mode, ...params)` checks its parameters, and `job.run()` either
%% returns [err, result] (kCryptoJobSync) or calls `job.ondone(err, result)`
%% later (kCryptoJobAsync). An async job computes in its own Erlang process,
%% as Node computes on libuv's thread pool, so a long key generation never
%% stops the realm.
-module(buoy_crypto_job).

-export([class/2, perform/1]).

-define(ASYNC, 0).

-type outcome() :: {ok, term()} | {error, term()}.
-type config() :: {fun(() -> outcome()), fun((term()) -> term())}.
-export_type([outcome/0]).

%% The job class Name. Config(Params) runs in the realm when the job is
%% constructed: it checks the parameters, throws as Node's AdditionalConfig
%% throws, and returns {Work, Encode}. Work only reads Erlang terms, never
%% the JavaScript heap, and returns {ok, Out} or {error, Reason} (an error
%% of buoy_crypto:error_value/1, or a failure of buoy_crypto:fail/1). Encode(Out) makes the result in the realm.
-spec class(binary(), fun((list()) -> config()) | fun((list(), sync | async) -> config())) -> term().
class(Name, Config) ->
    buoy_crypto:class(Name, fun(This, Args) -> init(This, Args, Name, Config) end,
                      [{<<"run">>, 0, fun run/2}]).

init(This, Args, Name, Config) ->
    Mode = case buoy_node:arg(1, Args) of
        ?ASYNC -> async;
        _ -> sync
    end,
    Params = case Args of
        [_ | Rest] -> Rest;
        [] -> []
    end,
    buoy_crypto:put_state(This, {job, {Mode, configure(Config, Params, Mode)}}),
    %% CryptoJob is an AsyncWrap: init hooks see each job, and its ondone
    %% runs in the async context, and the domain, of its creation.
    buoy_binding_async_wrap:wrap(This, provider(Name)).

%% The AsyncWrap provider of the Traits of each job of src/crypto.
provider(<<"RandomBytesJob">>) -> <<"RANDOMBYTESREQUEST">>;
provider(<<"RandomPrimeJob">>) -> <<"RANDOMPRIMEREQUEST">>;
provider(<<"CheckPrimeJob">>) -> <<"CHECKPRIMEREQUEST">>;
provider(<<"PBKDF2Job">>) -> <<"PBKDF2REQUEST">>;
provider(<<"ScryptJob">>) -> <<"SCRYPTREQUEST">>;
provider(<<"Argon2Job">>) -> <<"ARGON2REQUEST">>;
provider(<<"HashJob">>) -> <<"HASHREQUEST">>;
provider(<<"SignJob">>) -> <<"SIGNREQUEST">>;
provider(<<"HmacJob">>) -> <<"SIGNREQUEST">>;
provider(<<"KmacJob">>) -> <<"SIGNREQUEST">>;
provider(<<"SecretKeyGenJob">>) -> <<"KEYGENREQUEST">>;
provider(Name) ->
    Suffix = fun(S) -> binary:longest_common_suffix([Name, S]) =:= byte_size(S) end,
    case {Suffix(<<"CipherJob">>), Suffix(<<"KeyPairGenJob">>), Suffix(<<"KeyExportJob">>)} of
        {true, _, _} -> <<"CIPHERREQUEST">>;
        {_, true, _} -> <<"KEYPAIRGENREQUEST">>;
        {_, _, true} -> <<"KEYEXPORTREQUEST">>;
        _ -> <<"DERIVEBITSREQUEST">>
    end.

%% A job whose failure depends on the mode, as a DeriveBits of Node that
%% throws only in kCryptoJobSync, takes the mode too.
configure(Config, Params, Mode) when is_function(Config, 2) -> Config(Params, Mode);
configure(Config, Params, _) -> Config(Params).

run(This, _) ->
    case buoy_crypto:state(This, job) of
        {sync, {Work, Encode}} -> buoy_heap:new_array(result(perform(Work), Encode));
        {async, {Work, Encode}} -> schedule(This, Work, Encode)
    end.

%% The outcome of Work. An error of OTP's crypto becomes the error that
%% OpenSSL reported to it, and any other failure an error of the job.
-spec perform(fun(() -> outcome())) -> outcome().
perform(Work) ->
    try Work()
    catch
        error:{crypto_failure, Reason} ->
            {error, Reason};
        error:{Tag, {_File, _Line}, Description} when Tag =:= error; Tag =:= badarg; Tag =:= notsup ->
            {error, {message, unicode:characters_to_binary(Description)}};
        %% A bug of the binding fails the job loudly, and never leaves the loop waiting.
        Class:Reason ->
            {error, {message, iolist_to_binary(io_lib:format("Crypto job failed: ~p:~0p", [Class, Reason]))}}
    end.

result({ok, Out}, Encode) ->
    try [undefined, Encode(Out)]
    catch
        error:{crypto_failure, Reason} -> [buoy_crypto:error_value(Reason), undefined]
    end;
result({error, Reason}, _) -> [buoy_crypto:error_value(Reason), undefined].

%% The job and Encode stay roots of the heap, in the process dictionary,
%% until the outcome comes back; only Erlang terms cross to the worker.
schedule(This, Work, Encode) ->
    Realm = self(),
    Ref = make_ref(),
    erlang:put({?MODULE, Ref}, {This, Encode}),
    buoy_node_loop:ref_handle(),
    {Traced, Finished} = buoy_trace:pool_work(<<"crypto">>, fun() -> perform(Work) end),
    _ = spawn(fun() ->
        Outcome = Traced(),
        buoy_node_stream:call(Realm, fun() -> Finished(), done(Ref, Outcome) end)
    end),
    undefined.

done(Ref, Outcome) ->
    {Job, Encode} = erlang:erase({?MODULE, Ref}),
    buoy_node_loop:unref_handle(),
    OnDone = buoy_heap:get(Job, <<"ondone">>),
    Args = try result(Outcome, Encode)
    catch error:{'$throw', Exception} -> [Exception]
    end,
    _ = buoy_binding_async_wrap:make_callback(Job, OnDone, Args),
    buoy_binding_async_wrap:emit_destroy(Job).
