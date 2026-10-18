-module(buoy_jit).

%% The native tier (section 17.10 of the contract). The compiler lowers each island of
%% typed code to the IR of `crates/buoy-jit-ir`, which `Module:'$jit'(Index)` returns,
%% and starts the function of the island with
%%
%%     case buoy_jit:enter(Module, Index, Args, Prepare) of
%%         {ok, Value} -> Value;
%%         deopt -> <the Erlang tier>
%%     end
%%
%% `enter/4` compiles the IR once per VM with the NIF library `buoy_jit`, whose path
%% `BUOY_JIT` gives without the `.so`, and keeps the code in a persistent term. It runs
%% `Prepare`, which checks that the classes and intrinsics of the island are as their
%% definitions made them and returns the values of the variables that the island reads,
%% and then runs the machine code in time slices in this process. Any failure, a value of
%% another type, or a bail of the run returns `deopt`, and the Erlang tier runs the call
%% from its start. An island writes nothing outside the objects it makes, so that second
%% run is exact.

-export([enter/4, seal/1, pristine/1, intrinsic/2, intrinsics/0]).
-export([compile/1, context/1, run/5]).

-on_load(init/0).

%% A process that bails this often from one island stops trying it.
-define(MAX_BAILS, 4).

init() ->
    persistent_term:put({?MODULE, trace}, os:getenv("BUOY_JIT_TRACE", "") =/= ""),
    case os:getenv("BUOY_JIT", "") of
        Path when Path =:= ""; Path =:= "0"; Path =:= "off" ->
            ok;
        Path ->
            case erlang:load_nif(Path, 0) of
                ok -> persistent_term:put({?MODULE, loaded}, true);
                {error, _} -> ok
            end,
            ok
    end.

%% The NIFs, which `init/0` replaces.
-spec compile(binary()) -> {ok, reference()} | {error, binary()}.
compile(_Bytes) -> erlang:nif_error(not_loaded).

-spec context(non_neg_integer()) -> reference().
context(_HeapLimit) -> erlang:nif_error(not_loaded).

-spec run(reference(), reference(), non_neg_integer(), [term()], [term()]) ->
    {ok, term()} | {bail, atom()} | badtype | busy.
run(_Code, _Context, _Entry, _Args, _Globals) -> erlang:nif_error(not_loaded).

-spec enter(module(), non_neg_integer(), [term()], fun(() -> [term()])) ->
    {ok, term()} | deopt.
enter(Module, Index, Args, Prepare) ->
    case code(Module, Index) of
        none ->
            deopt;
        Code ->
            Key = {'$buoy_jit_bails', Module, Index},
            Outcome =
                case erlang:get(Key) of
                    Bails when is_integer(Bails), Bails >= ?MAX_BAILS -> {deopt, bails};
                    _ -> run_island(Code, Key, Args, Prepare)
                end,
            trace(Module, Index, Outcome),
            case Outcome of
                {ok, _} -> Outcome;
                _ -> deopt
            end
    end.

run_island(Code, Key, Args, Prepare) ->
    case prepare(Prepare) of
        {ok, Globals} ->
            try run(Code, context(), 0, Args, Globals) of
                {ok, Value} ->
                    {ok, Value};
                {bail, Reason} ->
                    erlang:put(Key, bails(erlang:get(Key)) + 1),
                    {deopt, Reason};
                Other ->
                    {deopt, Other}
            catch
                error:_ -> {deopt, error}
            end;
        error ->
            {deopt, guard}
    end.

%% `BUOY_JIT_TRACE` prints each entry of an island and how it ended to stderr.
trace(Module, Index, Outcome) ->
    case persistent_term:get({?MODULE, trace}, false) of
        true ->
            What =
                case Outcome of
                    {ok, _} -> native;
                    {deopt, Reason} -> Reason
                end,
            io:format(standard_error, "buoy jit: ~s ~B ~s~n", [Module, Index, What]);
        false ->
            ok
    end.

bails(undefined) -> 0;
bails(Count) -> Count.

prepare(Prepare) ->
    try Prepare() of
        Globals -> {ok, Globals}
    catch
        _:_ -> error
    end.

%% The machine code of the island, compiled on first use. `none` when the library is not
%% loaded or the IR does not compile.
code(Module, Index) ->
    Key = {?MODULE, Module, Index},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Code = compile_island(Module, Index),
            persistent_term:put(Key, Code),
            Code;
        Code ->
            Code
    end.

compile_island(Module, Index) ->
    case persistent_term:get({?MODULE, loaded}, false) of
        false ->
            none;
        true ->
            try compile(Module:'$jit'(Index)) of
                {ok, Code} ->
                    Code;
                {error, Message} ->
                    trace(Module, Index, {deopt, Message}),
                    none
            catch
                _:_ -> none
            end
    end.

%% The context of this process: its native stack and heap.
context() ->
    case erlang:get('$buoy_jit_context') of
        undefined ->
            Limit = buoy_guard:limit(os:getenv("BUOY_MAX_MEMORY", "")) div 4,
            Context = context(Limit),
            erlang:put('$buoy_jit_context', Context),
            Context;
        Context ->
            Context
    end.

%% Records the class as its definition made it, right after the definition runs. An island
%% runs only while the class and its prototype keep these records: a write to either, such
%% as a replaced method, makes it run in the Erlang tier.
-spec seal(term()) -> term().
seal({'$f', Id, _} = Class) ->
    case buoy_heap:get(Class, <<"prototype">>) of
        {'$o', Proto} -> erlang:put({'$buoy_jit_seal', Id}, {erlang:get(Id), Proto, erlang:get(Proto)});
        _ -> ok
    end,
    Class;
seal(Class) ->
    Class.

%% Throws unless the class keeps the records of its seal.
-spec pristine(term()) -> ok.
pristine({'$f', Id, _}) ->
    {Record, Proto, ProtoRecord} = erlang:get({'$buoy_jit_seal', Id}),
    true = erlang:get(Id) =:= Record andalso erlang:get(Proto) =:= ProtoRecord,
    ok.

%% Throws unless `Value` is the intrinsic `Id` of the first realm, unchanged.
-spec intrinsic(term(), atom()) -> ok.
intrinsic(Value, Id) ->
    {'$o', Id} = Value,
    undefined = erlang:get(Id),
    ok.

%% Throws unless the prototypes that every island relies on are unchanged: an island reads
%% no property of them, and a property that a program adds to one could change what a
%% field write, an element read, or a `for...of` loop does.
-spec intrinsics() -> ok.
intrinsics() ->
    undefined = erlang:get('$buoy_realm'),
    lists:foreach(
        fun(Id) -> undefined = erlang:get(Id) end,
        ['Object.prototype', 'Array.prototype', 'ArrayIterator.prototype', 'Iterator.prototype']
    ).
