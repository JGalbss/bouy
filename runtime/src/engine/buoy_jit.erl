-module(buoy_jit).

%% The native tier (section 17.11 of the contract). The compiler lowers each island of
%% typed code to the IR of `crates/buoy-jit-ir`, which `Module:'$jit'(Index)` returns,
%% and starts the function of the island with
%%
%%     case buoy_jit:enter(Module, Index, Args, Prepare) of
%%         {ok, Value, Written} -> <assign Written to its variables>, Value;
%%         deopt -> <the Erlang tier>
%%     end
%%
%% `enter/4` compiles the IR once per VM with the NIF library `buoy_jit.so`, which the CLI
%% writes next to the runtime's .beam files, and keeps the code in a persistent term. It runs
%% `Prepare`, which checks that the classes and intrinsics of the island are as their
%% definitions made them and returns `{Classes, Globals}`: each class of the island with
%% the keys of its fields, and the values of the variables that the island reads or
%% writes. Then it runs the machine code in time slices in this process.
%%
%% The objects and arrays that the globals reach cross by copy: `import/2` flattens them
%% into items, and when the run returns, `write_back/4` writes the fields of each item to
%% its object and makes an object for each item that the run made. `Written` holds the
%% new values of the variables that the island writes. Any failure, a value of another
%% type, or a bail of the run returns `deopt` before anything is written, and the Erlang
%% tier runs the call from its start, so that second run is exact.

-export([enter/4, seal/1, pristine/1, intrinsic/2, intrinsics/0]).
-export([compile/1, context/1, run/6]).

-on_load(init/0).

%% A process that bails this often from one island stops trying it.
-define(MAX_BAILS, 4).

%% `BUOY_JIT=0` keeps every call in the Erlang tier. A runtime without the library, such
%% as the build of rebar3, does the same.
init() ->
    persistent_term:put({?MODULE, trace}, os:getenv("BUOY_JIT_TRACE", "") =/= ""),
    case {os:getenv("BUOY_JIT", ""), code:where_is_file("buoy_jit.so")} of
        {Off, _} when Off =:= "0"; Off =:= "off" ->
            ok;
        {_, non_existing} ->
            ok;
        {_, Path} ->
            case erlang:load_nif(filename:rootname(Path), 0) of
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

-spec run(reference(), reference(), non_neg_integer(), [term()], [term()], [item()]) ->
    {ok, term(), [term()], [item()]} | {bail, atom()} | badtype | busy.
run(_Code, _Context, _Entry, _Args, _Globals, _Items) -> erlang:nif_error(not_loaded).

%% An object of a class of the island, by the index of its class, or an array.
-type item() :: {non_neg_integer() | array, [term()]}.
%% Each class of the island, in the order of its index, with the keys of its fields.
-type classes() :: [{term(), [binary()]}].

-spec enter(module(), non_neg_integer(), [term()], fun(() -> {classes(), [term()]})) ->
    {ok, term(), [term()]} | deopt.
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
                {ok, _, _} -> Outcome;
                _ -> deopt
            end
    end.

run_island(Code, Key, Args, Prepare) ->
    case prepare(Prepare) of
        {ok, {Classes, Globals}} ->
            case import(Globals, Classes) of
                {ok, Values, Ids, Items} ->
                    try run(Code, context(), 0, Args, Values, Items) of
                        {ok, Value, Written, After} ->
                            {ok, Value, write_back(Written, After, Ids, Classes)};
                        {bail, Reason} ->
                            erlang:put(Key, bails(erlang:get(Key)) + 1),
                            {deopt, Reason};
                        Other ->
                            {deopt, Other}
                    catch
                        error:_ -> {deopt, error}
                    end;
                badtype ->
                    {deopt, badtype}
            end;
        error ->
            {deopt, guard}
    end.

%% The values of the globals for the NIF, the ids of the objects that they reach, and the
%% item of each such object: its class index and fields, or the elements of an array.
%% `badtype` when a global reaches a value that no item can hold, such as a function, an
%% object of another class, an accessor, a hole, or a frozen object.
import(Globals, Classes) ->
    try
        {Values, State} = lists:mapfoldl(fun walk/2, #{classes => Classes, count => 0}, Globals),
        Count = maps:get(count, State),
        Ids = [maps:get({id, N}, State) || N <- lists:seq(0, Count - 1)],
        Items = [maps:get({item, N}, State) || N <- lists:seq(0, Count - 1)],
        {ok, Values, Ids, Items}
    catch
        throw:badtype -> badtype
    end.

walk({'$o', Id}, State) when is_integer(Id) ->
    case State of
        #{{seen, Id} := N} ->
            {{'$ref', N}, State};
        #{count := N} ->
            Seen = State#{count := N + 1, {seen, Id} => N, {id, N} => Id},
            %% record/1 gives a shaped object (buoy_heap) in the form of every other one.
            {Item, Walked} = item(buoy_heap:record({'$o', Id}), Seen),
            {{'$ref', N}, Walked#{{item, N} => Item}}
    end;
walk({'$u16', Units} = Value, State) when is_binary(Units) ->
    {Value, State};
walk(Value, State) when is_number(Value); is_atom(Value); is_binary(Value) ->
    {Value, State};
walk(_, _) ->
    throw(badtype).

item({object, {'$o', _} = Proto, Props, _, Attrs, none}, State0) when Attrs =:= #{} ->
    State = with_protos(State0),
    {Class, Keys} =
        case State of
            #{protos := #{Proto := Found}} -> Found;
            #{} -> throw(badtype)
        end,
    map_size(Props) =:= length(Keys) orelse throw(badtype),
    {Fields, Walked} = lists:mapfoldl(fun(Key, S) -> walk(field(Key, Props), S) end, State, Keys),
    {{Class, Fields}, Walked};
item({array, {'$o', 'Array.prototype'}, Props, [], Attrs, {Length, Elements}}, State) when
    map_size(Props) =:= 0, Attrs =:= #{}, map_size(Elements) =:= Length
->
    {Values, Walked} = lists:mapfoldl(
        fun(Index, S) -> walk(field(Index, Elements), S) end, State, lists:seq(0, Length - 1)
    ),
    {{array, Values}, Walked};
item(_, _) ->
    throw(badtype).

field(Key, Props) ->
    case Props of
        #{Key := {'$accessor', _, _}} -> throw(badtype);
        #{Key := Value} -> Value;
        #{} -> throw(badtype)
    end.

%% The index and the field keys of each class of the island, by its prototype, read when
%% the first object needs them.
with_protos(#{protos := _} = State) ->
    State;
with_protos(#{classes := Classes} = State) ->
    Protos = maps:from_list([
        {buoy_heap:get(Class, <<"prototype">>), {Index, Keys}}
     || {Index, {Class, Keys}} <- lists:enumerate(0, Classes)
    ]),
    State#{protos => Protos}.

%% Writes each item back to the object of its id, makes an object for each item past them,
%% and returns the values of the written globals.
write_back(Written, Items, Ids, Classes) ->
    {Old, New} = lists:split(length(Ids), Items),
    Made = [made(Item, Classes) || Item <- New],
    Objects = list_to_tuple([{'$o', Id} || Id <- Ids] ++ Made),
    lists:foreach(
        fun({{'$o', Id}, Item}) -> fill(Id, Item, Objects, Classes) end,
        lists:zip(tuple_to_list(Objects), Old ++ New)
    ),
    [resolve(Value, Objects) || Value <- Written].

made({array, _}, _) ->
    buoy_heap:new_array([]);
made({Class, _}, Classes) ->
    {Value, Keys} = lists:nth(Class + 1, Classes),
    Proto = buoy_heap:get(Value, <<"prototype">>),
    buoy_heap:literal(Proto, #{}, lists:reverse(Keys)).

fill(Id, {array, Elements}, Objects, _) ->
    Values = [resolve(Element, Objects) || Element <- Elements],
    {array, Proto, Props, Keys, Attrs, _} = erlang:get(Id),
    Slots = {length(Values), maps:from_list(lists:enumerate(0, Values))},
    erlang:put(Id, {array, Proto, Props, Keys, Attrs, Slots});
fill(Id, {Class, Fields}, Objects, Classes) ->
    {_, Keys} = lists:nth(Class + 1, Classes),
    Values = [resolve(Field, Objects) || Field <- Fields],
    {object, Proto, _, Order, Attrs, Slots} = buoy_heap:record({'$o', Id}),
    erlang:put(Id, {object, Proto, maps:from_list(lists:zip(Keys, Values)), Order, Attrs, Slots}).

resolve({'$ref', N}, Objects) -> element(N + 1, Objects);
resolve(Value, _) -> Value.

%% `BUOY_JIT_TRACE` prints each entry of an island and how it ended to stderr.
trace(Module, Index, Outcome) ->
    case persistent_term:get({?MODULE, trace}, false) of
        true ->
            What =
                case Outcome of
                    {ok, _, _} -> native;
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
