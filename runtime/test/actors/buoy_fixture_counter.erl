-module(buoy_fixture_counter).

%% The shape that the compiler gives this class (contract section 9):
%%
%%   class NotFound extends Data.TaggedError("NotFound") {}
%%   export class Counter {
%%     #count: number;
%%     #log: unknown[] = [];
%%     constructor(start = 0) { this.#count = start; }
%%     inc(by = 1) { this.#count += by; return this.#count; }
%%     get() { return this.#count; }
%%     record(item) { this.#log.push(item); return this.#log.length; }
%%     log() { return this.#log; }
%%     fail(message) { throw new Error(message); }
%%     me() { return self(this); }
%%     selfGet() { try { return self(this).get(); } catch (e) { return e._tag; } }
%%     async parallelSelf() {
%%       try { return await Promise.all([self(this).get()]); } catch (e) { return e._tag; }
%%     }
%%     succeed(value) { return Effect.succeed(value); }
%%     missing() { this.#count += 100; return Effect.fail(new NotFound()); }
%%     die() { return Effect.die(new Error("defect")); }
%%   }
%%
%% `ref.m(args)` compiles to buoy_rt:call_method/3, which calls buoy_actor:call/3
%% for a ref. These fixtures call buoy_actor:call/3 directly.

-export([
    'Counter#new'/1,
    'Counter#pure'/0,
    'Counter#dispatch'/3,
    'Counter#streams'/0,
    'Counter#inc'/2,
    'Counter#get'/2,
    'Counter#record'/2,
    'Counter#log'/2,
    'Counter#fail'/2,
    'Counter#me'/2,
    'Counter#selfGet'/2,
    'Counter#parallelSelf'/2,
    'Counter#succeed'/2,
    'Counter#missing'/2,
    'Counter#die'/2
]).

-spec 'Counter#new'(list()) -> map().
'Counter#new'(Args) ->
    Start =
        case buoy_rt:arg(1, Args) of
            undefined -> 0;
            Value -> Value
        end,
    #{<<"#count">> => Start, <<"#log">> => []}.

%% The constructor only binds its argument, so the compiler marks it pure and
%% spawn() runs it in the calling process (contract section 9).
-spec 'Counter#pure'() -> true.
'Counter#pure'() -> true.

-spec 'Counter#dispatch'(binary(), map(), list()) -> {term(), map()}.
'Counter#dispatch'(<<"inc">>, This, Args) -> 'Counter#inc'(This, Args);
'Counter#dispatch'(<<"get">>, This, Args) -> 'Counter#get'(This, Args);
'Counter#dispatch'(<<"record">>, This, Args) -> 'Counter#record'(This, Args);
'Counter#dispatch'(<<"log">>, This, Args) -> 'Counter#log'(This, Args);
'Counter#dispatch'(<<"fail">>, This, Args) -> 'Counter#fail'(This, Args);
'Counter#dispatch'(<<"me">>, This, Args) -> 'Counter#me'(This, Args);
'Counter#dispatch'(<<"selfGet">>, This, Args) -> 'Counter#selfGet'(This, Args);
'Counter#dispatch'(<<"parallelSelf">>, This, Args) -> 'Counter#parallelSelf'(This, Args);
'Counter#dispatch'(<<"succeed">>, This, Args) -> 'Counter#succeed'(This, Args);
'Counter#dispatch'(<<"missing">>, This, Args) -> 'Counter#missing'(This, Args);
'Counter#dispatch'(<<"die">>, This, Args) -> 'Counter#die'(This, Args);
'Counter#dispatch'(Method, _This, _Args) ->
    buoy_error:throw(<<"TypeError">>, <<"Counter.", Method/binary, " is not a function">>).

-spec 'Counter#streams'() -> [binary()].
'Counter#streams'() -> [].

-spec 'Counter#inc'(map(), list()) -> {integer(), map()}.
'Counter#inc'(#{<<"#count">> := Count} = This, Args) ->
    By =
        case buoy_rt:arg(1, Args) of
            undefined -> 1;
            Value -> Value
        end,
    Count1 = Count + By,
    {Count1, This#{<<"#count">> := Count1}}.

-spec 'Counter#get'(map(), list()) -> {integer(), map()}.
'Counter#get'(#{<<"#count">> := Count} = This, _Args) ->
    {Count, This}.

-spec 'Counter#record'(map(), list()) -> {integer(), map()}.
'Counter#record'(#{<<"#log">> := Log} = This, Args) ->
    Log1 = Log ++ [buoy_rt:arg(1, Args)],
    {length(Log1), This#{<<"#log">> := Log1}}.

-spec 'Counter#log'(map(), list()) -> {list(), map()}.
'Counter#log'(#{<<"#log">> := Log} = This, _Args) ->
    {Log, This}.

-spec 'Counter#fail'(map(), list()) -> no_return().
'Counter#fail'(_This, Args) ->
    erlang:error({'$throw', buoy_error:new(<<"Error">>, buoy_rt:arg(1, Args))}).

-spec 'Counter#me'(map(), list()) -> {term(), map()}.
'Counter#me'(This, _Args) ->
    {buoy:self([This]), This}.

-spec 'Counter#selfGet'(map(), list()) -> {term(), map()}.
'Counter#selfGet'(This, _Args) ->
    {tag_of(fun() -> buoy_actor:call(buoy:self([This]), <<"get">>, []) end), This}.

-spec 'Counter#parallelSelf'(map(), list()) -> {term(), map()}.
'Counter#parallelSelf'(This, _Args) ->
    Me = buoy:self([This]),
    {tag_of(fun() -> buoy_task:all([fun() -> buoy_actor:call(Me, <<"get">>, []) end]) end), This}.

-spec 'Counter#succeed'(map(), list()) -> {term(), map()}.
'Counter#succeed'(This, Args) ->
    Value = buoy_rt:arg(1, Args),
    {{'$effect', fun() -> {ok, Value} end}, This}.

-spec 'Counter#missing'(map(), list()) -> {term(), map()}.
'Counter#missing'(#{<<"#count">> := Count} = This, _Args) ->
    NotFound = buoy_error:new(<<"NotFound">>, <<>>, #{<<"_tag">> => <<"NotFound">>}),
    {{'$effect', fun() -> {error, NotFound} end}, This#{<<"#count">> := Count + 100}}.

-spec 'Counter#die'(map(), list()) -> {term(), map()}.
'Counter#die'(This, _Args) ->
    Defect = buoy_error:new(<<"Error">>, <<"defect">>),
    {{'$effect', fun() -> erlang:error({'$throw', Defect}) end}, This}.

%% `try { return f(); } catch (e) { return e._tag; }`
tag_of(Fun) ->
    try
        Fun()
    catch
        error:Reason:Stack -> maps:get(<<"_tag">>, buoy_rt:caught(Reason, Stack))
    end.
