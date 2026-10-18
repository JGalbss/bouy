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
-export_type([outcome/0]).

%% The job class Name. Config(Params) runs in the realm when the job is
%% constructed: it checks the parameters, throws as Node's AdditionalConfig
%% throws, and returns {Work, Encode}. Work only reads Erlang terms, never
%% the JavaScript heap, and returns {ok, Out} or {error, Reason} (an error
%% of buoy_crypto:error_value/1). Encode(Out) makes the result in the realm.
-spec class(binary(), fun((list()) -> {fun(() -> outcome()), fun((term()) -> term())})) -> term().
class(Name, Config) ->
    buoy_crypto:class(Name, fun(This, Args) -> init(This, Args, Config) end,
                      [{<<"run">>, 0, fun run/2}]).

init(This, Args, Config) ->
    Mode = case buoy_node:arg(1, Args) of
        ?ASYNC -> async;
        _ -> sync
    end,
    Params = case Args of
        [_ | Rest] -> Rest;
        [] -> []
    end,
    buoy_crypto:put_state(This, {job, {Mode, Config(Params)}}).

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
        error:{Tag, {_File, _Line}, Description} when Tag =:= error; Tag =:= badarg; Tag =:= notsup ->
            {error, {message, unicode:characters_to_binary(Description)}};
        %% A bug of the binding fails the job loudly, and never leaves the loop waiting.
        Class:Reason ->
            {error, {message, iolist_to_binary(io_lib:format("Crypto job failed: ~p:~0p", [Class, Reason]))}}
    end.

result({ok, Out}, Encode) -> [undefined, Encode(Out)];
result({error, Reason}, _) -> [buoy_crypto:error_value(Reason), undefined].

%% The job and Encode stay roots of the heap, in the process dictionary,
%% until the outcome comes back; only Erlang terms cross to the worker.
schedule(This, Work, Encode) ->
    Realm = self(),
    Ref = make_ref(),
    erlang:put({?MODULE, Ref}, {This, Encode}),
    buoy_node_loop:ref_handle(),
    _ = spawn(fun() ->
        Outcome = perform(Work),
        buoy_node_stream:call(Realm, fun() -> done(Ref, Outcome) end)
    end),
    undefined.

done(Ref, Outcome) ->
    {Job, Encode} = erlang:erase({?MODULE, Ref}),
    buoy_node_loop:unref_handle(),
    OnDone = buoy_heap:get(Job, <<"ondone">>),
    Args = try result(Outcome, Encode)
    catch error:{'$throw', Exception} -> [Exception]
    end,
    buoy_heap:call(OnDone, Job, Args).
