%% The WebAssembly namespace: the JavaScript API of WebAssembly
%% (webassembly.github.io/spec/js-api) on Wasmtime, through the NIFs of
%% buoy_native (crates/buoy-native/src/wasm.rs).
%%
%% Each process has one store, under ?STATE in the process dictionary, which
%% holds every instance, memory, table, global, and tag of the process, as the
%% API keeps them in one agent. A command of the store, such as a call of an
%% exported function, runs in slices of about a millisecond: between two
%% slices the NIF returns yield and the process polls again, so the BEAM
%% scheduler can preempt a long call, and a supervisor can kill it. A call of
%% a JavaScript import suspends the WebAssembly call: the NIF returns
%% {call, Id, Args, ResultTypes, Grown}, this module runs the function and
%% sends its result with the command {return, Returned}. While the import
%% runs, JavaScript can send other commands, such as a read of memory or a
%% nested call, to the store of the suspended call.
%%
%% The store names an extern by its handle. ?STATE maps each handle to its
%% JavaScript object, so one extern keeps one object, and maps the ids of the
%% JavaScript values in externref values, the JavaScript functions of the
%% imports, and the values that imports threw. These maps are roots of the
%% heap of the process.
%%
%% The buffer of a Memory is an ArrayBuffer whose data is {'$wasm', Handle}:
%% buoy_ref_buffer reads and writes its bytes with read/3 and write/3, which
%% are commands of the store. A grow of the memory detaches the buffer.
-module(buoy_ref_wasm).

-include("buoy_ref.hrl").

-export([intrinsics/0, globals/0, method/4, call_constructor/3]).
-export([read/3, write/3]).

-import(buoy_ref_realm, [arg/2, record/4, ctor_record/5]).

-define(STATE, '$buoy_wasm').
%% The attribute bits of an operation and an attribute of Web IDL.
-define(OPERATION, 7).
-define(ATTRIBUTE, 6).

-define(CLASSES, [<<"Module">>, <<"Instance">>, <<"Memory">>, <<"Table">>, <<"Global">>, <<"Tag">>, <<"Exception">>, <<"Suspending">>]).
-define(ERRORS, [<<"CompileError">>, <<"LinkError">>, <<"RuntimeError">>, <<"SuspendError">>]).

%%% The intrinsics

-spec intrinsics() -> [{term(), tuple()}].
intrinsics() ->
    Namespace = operations(<<"WebAssembly">>, [{<<"compile">>, 1}, {<<"validate">>, 1}, {<<"instantiate">>, 1}])
        ++ [{N, constructor(N)} || N <- [<<"Module">>, <<"Instance">>, <<"Table">>, <<"Memory">>, <<"Global">>, <<"Tag">>]]
        ++ [{<<"JSTag">>, {'$o', 'WebAssembly.JSTag'}, 4}, {<<"Exception">>, constructor(<<"Exception">>)}]
        ++ [{N, constructor(N)} || N <- [<<"CompileError">>, <<"LinkError">>, <<"RuntimeError">>]]
        ++ operations(<<"WebAssembly">>, [{<<"compileStreaming">>, 1}, {<<"instantiateStreaming">>, 1}])
        ++ [{<<"Suspending">>, constructor(<<"Suspending">>)}]
        ++ operations(<<"WebAssembly">>, [{<<"promising">>, 1}])
        ++ [{<<"SuspendError">>, constructor(<<"SuspendError">>)},
            {?SYM(toStringTag), <<"WebAssembly">>, 4}],
    [{'WebAssembly', record(object, ?OBJECT_PROTO, Namespace, none)},
     {'WebAssembly.JSTag', record(object, {'$o', proto_id(<<"Tag">>)}, [], none)}]
    ++ class(<<"Module">>, [], [], operations(<<"WebAssembly.Module">>, [{<<"imports">>, 1}, {<<"exports">>, 1}, {<<"customSections">>, 2}]))
    ++ class(<<"Instance">>, [], [<<"exports">>], [])
    ++ class(<<"Memory">>, [{<<"grow">>, 1}], [<<"buffer">>], [])
    ++ class(<<"Table">>, [{<<"grow">>, 1}, {<<"set">>, 1}, {<<"get">>, 1}], [<<"length">>], [])
    ++ class(<<"Global">>, [{<<"valueOf">>, 0}], [<<"value">>], [])
    ++ class(<<"Tag">>, [], [], [])
    ++ class(<<"Exception">>, [{<<"getArg">>, 2}, {<<"is">>, 1}], [], [])
    ++ class(<<"Suspending">>, [], [], [])
    ++ lists:append([error_class(N) || N <- ?ERRORS]).

operations(Owner, Names) -> [{K, V, ?OPERATION} || {K, V} <- ?METHODS(Owner, Names)].

%% The prototype and the constructor of the interface Name.
class(Name, Operations, Attributes, Statics) ->
    Owner = <<"WebAssembly.", Name/binary, ".prototype">>,
    Proto = record(object, ?OBJECT_PROTO,
                   [{<<"constructor">>, constructor(Name)}]
                   ++ operations(Owner, Operations)
                   ++ [attribute(Owner, A) || A <- Attributes]
                   ++ [{?SYM(toStringTag), <<"WebAssembly.", Name/binary>>, 4}], none),
    [{proto_id(Name), Proto},
     {{builtin, id(Name)}, ctor_record(Name, 1, {'$o', proto_id(Name)}, Statics, fun(NT, Args) -> construct(Name, NT, Args) end)}].

%% An attribute of Web IDL: a getter, and a setter for value of Global.
attribute(Owner, Name) ->
    Get = buoy_ref_realm:builtin(<<"get ", Owner/binary, ".", Name/binary>>, <<"get ", Name/binary>>, 0,
                                 fun(This, _) -> ?MODULE:method(Owner, Name, This, []) end),
    Set = case Name of
        <<"value">> -> buoy_ref_realm:builtin(<<"set ", Owner/binary, ".", Name/binary>>, <<"set ", Name/binary>>, 1,
                                              fun(This, Args) -> ?MODULE:method(Owner, <<"set value">>, This, Args) end);
        _ -> undefined
    end,
    {Name, {'$accessor', Get, Set}, ?ATTRIBUTE}.

%% A native error class: its prototype inherits Error.prototype, and its
%% constructor inherits Error.
error_class(Name) ->
    Proto = record(object, {'$o', 'Error.prototype'}, [{<<"constructor">>, constructor(Name)}, {<<"name">>, Name}, {<<"message">>, <<>>}], none),
    Ctor = ctor_record(Name, 1, {'$o', proto_id(Name)}, [], fun(NT, Args) -> construct_error(Name, NT, Args) end),
    [{proto_id(Name), Proto}, {{builtin, id(Name)}, setelement(2, Ctor, buoy_ref_realm:constructor(buoy_ref_error, <<"Error">>))}].

id(Name) -> <<"WebAssembly.", Name/binary>>.

proto_id(Name) -> binary_to_atom(<<"WebAssembly.", Name/binary, ".prototype">>).

constructor(Name) ->
    Id = id(Name),
    {'$f', {builtin, Id}, fun(This, Args) -> ?MODULE:call_constructor(Name, This, Args) end}.

-spec globals() -> [{binary(), term()}].
globals() -> [{<<"WebAssembly">>, {'$o', 'WebAssembly'}}].

%% A native error constructs without new; the interfaces need new.
-spec call_constructor(binary(), term(), list()) -> term().
call_constructor(Name, _This, Args) ->
    case lists:member(Name, ?ERRORS) of
        true -> construct_error(Name, constructor(Name), Args);
        false -> buoy_ref:type_error(<<"WebAssembly.", Name/binary, "(): WebAssembly.", Name/binary, " must be invoked with 'new'">>)
    end.

construct_error(Name, NewTarget, Args) ->
    E = buoy_heap:error_object(buoy_ref_realm:proto_for(NewTarget, proto_id(Name)), <<>>, <<>>),
    Header = case arg(1, Args) of
        undefined ->
            buoy_heap:delete(E, <<"message">>),
            Name;
        M ->
            Text = buoy_ref:to_string(M),
            buoy_heap:set(E, <<"message">>, Text),
            buoy_ref_string:concat([Name, <<": ">>, Text])
    end,
    buoy_heap:set(E, <<"stack">>, buoy_ref_string:concat(Header, <<"\n    at <anonymous>">>)),
    Options = arg(2, Args),
    ?IS_OBJECT(Options) andalso buoy_heap:has(Options, <<"cause">>) andalso
        buoy_heap:define(E, <<"cause">>, #{value => buoy_ref:get(Options, <<"cause">>), writable => true, enumerable => false, configurable => true}),
    E.

%% Throws the error Kind, a native error or one of ?ERRORS, with Message.
-spec throw(atom() | binary(), binary()) -> no_return().
throw(Kind, Message) when is_atom(Kind) -> buoy_heap:throw_error(Kind, Message);
throw(Kind, Message) ->
    Stack = buoy_ref_string:concat([Kind, <<": ">>, Message, <<"\n    at <buoy>">>]),
    erlang:error({'$throw', buoy_heap:error_object(buoy_heap:intrinsic(proto_id(Kind)), Message, Stack)}).

%%% The constructors

construct(<<"Module">>, NT, Args) ->
    Bytes = buffer_source(arg(1, Args), <<"WebAssembly.Module()">>, 0),
    module_object(compile(Bytes, <<"WebAssembly.Module()">>), Bytes, buoy_ref_realm:proto_for(NT, proto_id(<<"Module">>)));
construct(<<"Instance">>, NT, Args) ->
    Module = arg(1, Args),
    is_class(Module, wasm_module) orelse buoy_ref:type_error(<<"WebAssembly.Instance(): Argument 0 must be a WebAssembly.Module">>),
    instance(Module, arg(2, Args), buoy_ref_realm:proto_for(NT, proto_id(<<"Instance">>)), <<"WebAssembly.Instance()">>);
construct(<<"Memory">>, NT, Args) ->
    Context = <<"WebAssembly.Memory()">>,
    Descriptor = descriptor(arg(1, Args), Context),
    Index = case buoy_ref:get(Descriptor, <<"address">>) of
        undefined -> <<"i32">>;
        A -> buoy_ref:to_string(A)
    end,
    Limit = case Index of
        <<"i64">> -> 1 bsl 48;
        <<"i32">> -> 65536;
        _ -> buoy_ref:type_error(<<Context/binary, ": Descriptor property 'address' must be 'i32' or 'i64'">>)
    end,
    Initial = limit(Descriptor, <<"initial">>, Context, Limit, required),
    Maximum = limit(Descriptor, <<"maximum">>, Context, Limit, none),
    Maximum =/= none andalso Maximum < Initial andalso
        throw('RangeError', <<Context/binary, ": Property 'maximum': value ", (integer_to_binary(Maximum))/binary,
                              " is below the lower bound ", (integer_to_binary(Initial))/binary>>),
    Shared = buoy_ref:truthy(buoy_ref:get(Descriptor, <<"shared">>)),
    Shared andalso Maximum =:= none andalso buoy_ref:type_error(<<Context/binary, ": If shared is true, maximum property should be defined.">>),
    Type = reply(command({memory_new, Initial, Maximum, Shared}), Context),
    memory_object(Type, buoy_ref_realm:proto_for(NT, proto_id(<<"Memory">>)));
construct(<<"Table">>, NT, Args) ->
    Context = <<"WebAssembly.Table()">>,
    Descriptor = descriptor(arg(1, Args), Context),
    Element = case buoy_ref:get(Descriptor, <<"element">>) of
        undefined -> buoy_ref:type_error(<<Context/binary, ": Descriptor property 'element' must be a WebAssembly reference type">>);
        E -> ref_type(buoy_ref:to_string(E), <<Context/binary, ": Descriptor property 'element' must be a WebAssembly reference type">>)
    end,
    Initial = limit(Descriptor, <<"initial">>, Context, 10000000, required),
    Maximum = limit(Descriptor, <<"maximum">>, Context, 16#FFFFFFFF, none),
    Maximum =/= none andalso Maximum < Initial andalso
        throw('RangeError', <<Context/binary, ": Property 'maximum': value ", (integer_to_binary(Maximum))/binary,
                              " is below the lower bound ", (integer_to_binary(Initial))/binary>>),
    Init = case Args of
        [_, V | _] -> to_wasm(Element, V);
        _ -> to_wasm(Element, default(Element))
    end,
    Type = reply(command({table_new, Element, Initial, Maximum, Init}), Context),
    table_object(Type, buoy_ref_realm:proto_for(NT, proto_id(<<"Table">>)));
construct(<<"Global">>, NT, Args) ->
    Context = <<"WebAssembly.Global()">>,
    Descriptor = descriptor(arg(1, Args), Context),
    Mutable = buoy_ref:truthy(buoy_ref:get(Descriptor, <<"mutable">>)),
    Type = case buoy_ref:get(Descriptor, <<"value">>) of
        undefined -> buoy_ref:type_error(<<Context/binary, ": Descriptor property 'value' must be a WebAssembly type">>);
        T -> val_type(buoy_ref:to_string(T), <<Context/binary, ": Descriptor property 'value' must be a WebAssembly type">>)
    end,
    Type =:= v128 andalso buoy_ref:type_error(<<Context/binary, ": Descriptor property 'value' must be a WebAssembly type">>),
    Value = case arg(2, Args) of
        undefined -> to_wasm(Type, default_global(Type));
        V -> to_wasm(Type, V)
    end,
    Created = reply(command({global_new, Type, Mutable, Value}), Context),
    global_object(Created, buoy_ref_realm:proto_for(NT, proto_id(<<"Global">>)));
construct(<<"Tag">>, NT, Args) ->
    Context = <<"WebAssembly.Tag()">>,
    Descriptor = descriptor(arg(1, Args), Context),
    Parameters = buoy_ref:get(Descriptor, <<"parameters">>),
    ?IS_OBJECT(Parameters) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a tag type with 'parameters'">>),
    Types = [val_type(buoy_ref:to_string(P), <<Context/binary, ": Argument 0 parameter type at index #", (integer_to_binary(I))/binary, " must be a value type">>)
             || {I, P} <- lists:enumerate(0, buoy_ref_iterator:to_list(Parameters))],
    Created = reply(command({tag_new, Types}), Context),
    tag_object(Created, buoy_ref_realm:proto_for(NT, proto_id(<<"Tag">>)));
construct(<<"Exception">>, NT, Args) ->
    Context = <<"WebAssembly.Exception()">>,
    Tag = arg(1, Args),
    is_class(Tag, wasm_tag) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a WebAssembly tag">>),
    {_, Params} = buoy_heap:slots(Tag),
    Payload = arg(2, Args),
    ?IS_OBJECT(Payload) orelse buoy_ref:type_error(<<Context/binary, ": Argument 1 must be an iterable object">>),
    Values = buoy_ref_iterator:to_list(Payload),
    length(Values) =:= length(Params) orelse
        buoy_ref:type_error(<<Context/binary, ": Number of exception values does not match signature length">>),
    Converted = [to_js(to_wasm(T, V)) || {T, V} <- lists:zip(Params, Values)],
    E = buoy_heap:new_exotic(wasm_exception, buoy_ref_realm:proto_for(NT, proto_id(<<"Exception">>)), {Tag, Converted}),
    Options = arg(3, Args),
    ?IS_OBJECT(Options) andalso buoy_ref:truthy(buoy_ref:get(Options, <<"traceStack">>)) andalso
        buoy_heap:define(E, <<"stack">>, #{value => <<"Error\n    at <buoy>">>, writable => true, enumerable => false, configurable => true}),
    E;
construct(<<"Suspending">>, NT, Args) ->
    F = arg(1, Args),
    buoy_heap:is_callable(F) orelse buoy_ref:type_error(<<"WebAssembly.Suspending(): Argument 0 must be a function">>),
    buoy_heap:new_exotic(wasm_suspending, buoy_ref_realm:proto_for(NT, proto_id(<<"Suspending">>)), F).

descriptor(D, Context) ->
    ?IS_OBJECT(D) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a ", (descriptor_name(Context))/binary, " descriptor">>),
    D.

descriptor_name(<<"WebAssembly.Memory()">>) -> <<"memory">>;
descriptor_name(<<"WebAssembly.Table()">>) -> <<"table">>;
descriptor_name(<<"WebAssembly.Global()">>) -> <<"global">>;
descriptor_name(_) -> <<"tag">>.

%% A property of a descriptor that holds a limit: [EnforceRange] unsigned
%% long, at most Max.
limit(Descriptor, Name, Context, Max, Default) ->
    case buoy_ref:get(Descriptor, Name) of
        undefined when Default =:= required -> buoy_ref:type_error(<<Context/binary, ": Property '", Name/binary, "' is required">>);
        undefined -> Default;
        V ->
            N = buoy_ref:to_number(V),
            case buoy_ref_number:to_integer_or_infinity(N) of
                I when is_integer(I), I >= 0, I =< Max, N =/= 'NaN' -> I;
                _ when N =:= 'NaN'; N =:= 'Infinity'; N =:= '-Infinity' ->
                    buoy_ref:type_error(<<Context/binary, ": Property '", Name/binary, "' must be convertible to a valid number">>);
                I when is_integer(I), I < 0 ->
                    buoy_ref:type_error(<<Context/binary, ": Property '", Name/binary, "' must be non-negative">>);
                _ ->
                    buoy_ref:type_error(<<Context/binary, ": Property '", Name/binary, "': value ", (buoy_ref:to_string(N))/binary,
                                          " is above the upper bound ", (integer_to_binary(Max))/binary>>)
            end
    end.

%%% The objects of the externs

module_object(Module, Bytes, Proto) -> buoy_heap:new_exotic(wasm_module, Proto, {Module, Bytes}).

memory_object({memory, H, _Min, _Max, Shared, _Is64}, Proto) ->
    remember(H, fun() -> buoy_heap:new_exotic(wasm_memory, Proto, {H, Shared, none}) end).

table_object({table, H, Element, _Min, _Max}, Proto) ->
    remember(H, fun() -> buoy_heap:new_exotic(wasm_table, Proto, {H, Element}) end).

global_object({global, H, Type, Mutable}, Proto) ->
    remember(H, fun() -> buoy_heap:new_exotic(wasm_global, Proto, {H, Type, Mutable}) end).

tag_object({tag, H, Params}, Proto) ->
    remember(H, fun() -> buoy_heap:new_exotic(wasm_tag, Proto, {H, Params}) end).

%% The object of the extern Type. Name names an exported func.
extern_object({func, _, _, _, _} = Type, Name) -> func_object(Type, Name);
extern_object(Type, _Name) -> extern_object(Type).

extern_object({func, H, _, _, _} = Type) -> func_object(Type, integer_to_binary(H));
extern_object({memory, _, _, _, _, _} = Type) -> memory_object(Type, intrinsic(<<"Memory">>));
extern_object({table, _, _, _, _} = Type) -> table_object(Type, intrinsic(<<"Table">>));
extern_object({global, _, _, _} = Type) -> global_object(Type, intrinsic(<<"Global">>));
extern_object({tag, _, _} = Type) -> tag_object(Type, intrinsic(<<"Tag">>)).

intrinsic(Name) -> buoy_heap:intrinsic(proto_id(Name)).

remember(H, Make) ->
    State = state(),
    #{objects := Objects} = State,
    case Objects of
        #{H := O} ->
            O;
        _ ->
            O = Make(),
            erlang:put(?STATE, (state())#{objects => Objects#{H => O}}),
            O
    end.

%% The exported function of a func: the JavaScript function of an import, or
%% a function that calls the func, named Name, the index of the func in V8.
%% shortcut: a func that only a table, a global, or a result names has the
%% name of its handle, because the store does not give its index; parse the
%% element sections when a program depends on the name.
func_object({func, _H, _Params, _Results, Host}, _Name) when Host =/= none -> host_function(Host);
func_object({func, H, Params, Results, none}, Name) ->
    remember(H, fun() ->
                        Call = fun(_This, Args) -> call_func(H, Params, Results, Args) end,
                        buoy_heap:function(Call, Name, length(Params), #{wasm => H})
                end).

call_func(H, Params, Results, Args) ->
    Values = [to_wasm(T, V) || {T, V} <- lists:zip(Params, pad(Args, length(Params)))],
    from_results(reply(command({call, H, Values}), <<>>), Results).

pad(Args, N) when length(Args) >= N -> lists:sublist(Args, N);
pad(Args, N) -> Args ++ lists:duplicate(N - length(Args), undefined).

from_results([], _) -> undefined;
from_results([V], _) -> to_js(V);
from_results(Values, _) -> buoy_heap:new_array([to_js(V) || V <- Values]).

%% The handle of an exported function, or none.
func_handle({'$f', Id, _} = F) when is_integer(Id) ->
    case buoy_heap:slots(F) of
        #{wasm := H} -> H;
        _ -> none
    end;
func_handle(_) -> none.

%%% Instantiation

instance(Module, Imports, Proto, Context) ->
    {Res, Bytes} = buoy_heap:slots(Module),
    Types = buoy_native:wasm_imports(Res),
    Types =/= [] andalso not ?IS_OBJECT(Imports) andalso
        buoy_ref:type_error(<<Context/binary, ": Imports argument must be present and must be an object">>),
    Imports =:= undefined orelse ?IS_OBJECT(Imports) orelse
        buoy_ref:type_error(<<Context/binary, ": Argument 1 must be an object">>),
    Resolved = [import(Context, I, M, N, T, Imports) || {I, {M, N, T}} <- lists:enumerate(0, Types)],
    Exports = reply(command({instantiate, Res, Resolved}), Context),
    Indexes = func_indexes(Bytes),
    Object = buoy_heap:new_object(null),
    [buoy_heap:define(Object, buoy_ref_string:from_utf8(Name),
                      #{value => extern_object(Type, maps:get(Name, Indexes, <<"0">>)), writable => false, enumerable => true, configurable => false})
     || {Name, Type} <- Exports],
    buoy_heap:prevent_extensions(Object),
    buoy_heap:new_exotic(wasm_instance, Proto, Object).

%% The value for import #I, Module Name of type Type, of the import object.
import(Context, I, Module, Name, Type, Imports) ->
    Where = <<Context/binary, ": Import #", (integer_to_binary(I))/binary, " \"", Module/binary, "\"">>,
    Namespace = buoy_ref:get(Imports, buoy_ref_string:from_utf8(Module)),
    ?IS_OBJECT(Namespace) orelse buoy_ref:type_error(<<Where/binary, ": module is not an object or function">>),
    V = buoy_ref:get(Namespace, buoy_ref_string:from_utf8(Name)),
    Item = <<Where/binary, " \"", Name/binary, "\"">>,
    case Type of
        {func, _, _, _, _} ->
            buoy_heap:is_callable(V) orelse is_class(V, wasm_suspending) orelse throw(<<"LinkError">>, <<Item/binary, ": function import requires a callable">>),
            case func_handle(V) of
                none -> {host, host_id(V)};
                H -> {func, H}
            end;
        {global, _, ValType, Mutable} ->
            case is_class(V, wasm_global) of
                true ->
                    {global, element(1, buoy_heap:slots(V))};
                false when Mutable ->
                    throw(<<"LinkError">>, <<Item/binary, ": imported mutable global must be a WebAssembly.Global object">>);
                false ->
                    is_global_value(ValType, V) orelse
                        throw(<<"LinkError">>, <<Item/binary, ": global import must be a number, valid Wasm reference, or WebAssembly.Global object">>),
                    {value, to_wasm(ValType, V)}
            end;
        {memory, _, _, _, _, _} ->
            is_class(V, wasm_memory) orelse throw(<<"LinkError">>, <<Item/binary, ": memory import must be a WebAssembly.Memory object">>),
            {memory, element(1, buoy_heap:slots(V))};
        {table, _, _, _, _} ->
            is_class(V, wasm_table) orelse throw(<<"LinkError">>, <<Item/binary, ": table import requires a WebAssembly.Table">>),
            {table, element(1, buoy_heap:slots(V))};
        {tag, _, _} ->
            is_class(V, wasm_tag) orelse throw(<<"LinkError">>, <<Item/binary, ": tag import requires a WebAssembly.Tag">>),
            {tag, element(1, buoy_heap:slots(V))}
    end.

is_global_value(i64, V) -> is_tuple(V) andalso element(1, V) =:= '$bigint';
is_global_value(T, V) when T =:= i32; T =:= f32; T =:= f64 -> ?IS_NUMBER(V);
is_global_value(_, _) -> true.

%% The id of the JavaScript function of an import, the same for one function.
host_id(F) ->
    #{hosts := Hosts, host_ids := Ids, next := Next} = State = state(),
    case Ids of
        #{F := Id} -> Id;
        _ ->
            erlang:put(?STATE, State#{hosts => Hosts#{Next => F}, host_ids => Ids#{F => Next}, next => Next + 1}),
            Next
    end.

host_function(Id) -> maps:get(Id, maps:get(hosts, state())).

%%% Calls of imports

%% Runs Command in the store of the process: the reply, after each call of
%% an import that the command makes.
command(Command) ->
    Store = store(),
    pump(Store, buoy_native:wasm_command(Store, Command)).

pump(Store, yield) ->
    pump(Store, buoy_native:wasm_poll(Store));
pump(_Store, {done, Reply, Grown}) ->
    detach(Grown),
    Reply;
pump(Store, {call, Id, Args, Types, Grown}) ->
    detach(Grown),
    case call_host(Id, Args, Types) of
        {raise, Class, Reason, Stack} ->
            _ = pump(Store, buoy_native:wasm_command(Store, {return, aborted})),
            erlang:raise(Class, Reason, Stack);
        Returned ->
            pump(Store, buoy_native:wasm_command(Store, {return, Returned}))
    end.

%% The pump of a call of a promising export, whose Suspending imports wait
%% for their promise: the WebAssembly call stays suspended in the store, and
%% the reaction of the promise sends the result and pumps again. The store
%% has one stack, so a resume that is not the innermost suspension waits in
%% deferred until the calls inside it end.
pump_promising(Store, yield, Call) ->
    pump_promising(Store, buoy_native:wasm_poll(Store), Call);
pump_promising(_Store, {done, Reply, Grown}, {P, Results}) ->
    detach(Grown),
    try from_results(reply(Reply, <<>>), Results) of
        V -> buoy_jobs:resolve_promise(P, V)
    catch
        error:{'$throw', E} -> buoy_jobs:reject_promise(P, E)
    end,
    resume_deferred();
pump_promising(Store, {call, Id, Args, Types, Grown}, Call) ->
    detach(Grown),
    F = host_function(Id),
    case is_class(F, wasm_suspending) of
        true ->
            try buoy_ref:call(buoy_heap:slots(F), undefined, [to_js(A) || A <- Args]) of
                R ->
                    case buoy_jobs:is_promise(R) of
                        true -> suspend(Store, R, Types, Call);
                        false -> resume(Store, returned(fun() -> R end, Types), Call)
                    end
            catch
                error:Reason:Stack -> resume(Store, {thrown, keep_thrown(buoy_ref:caught(Reason, Stack))}, Call)
            end;
        false ->
            resume(Store, call_host(Id, Args, Types), Call)
    end.

resume(Store, {raise, Class, Reason, Stack}, Call) ->
    pump_promising(Store, buoy_native:wasm_command(Store, {return, aborted}), Call),
    erlang:raise(Class, Reason, Stack);
resume(Store, Returned, Call) ->
    pump_promising(Store, buoy_native:wasm_command(Store, {return, Returned}), Call).

suspend(Store, Promise, Types, Call) ->
    Token = make_ref(),
    push_suspended(Token),
    Continue = fun(Returned) -> resume_when_innermost(Token, fun() -> resume(Store, Returned, Call) end) end,
    buoy_jobs:perform_then(Promise,
                           fun(V) -> Continue(returned(fun() -> V end, Types)), undefined end,
                           fun(E) -> Continue({thrown, keep_thrown(E)}), undefined end,
                           undefined).

push_suspended(Token) ->
    State = #{suspended := Stack} = state(),
    erlang:put(?STATE, State#{suspended => [Token | Stack]}).

resume_when_innermost(Token, Resume) ->
    State = #{suspended := Stack, deferred := Deferred} = state(),
    case Stack of
        [Token | Rest] ->
            erlang:put(?STATE, State#{suspended => Rest}),
            Resume();
        _ ->
            erlang:put(?STATE, State#{deferred => Deferred#{Token => Resume}})
    end.

%% After a promising call ends, the suspension that is now innermost goes
%% on if its promise already settled.
resume_deferred() ->
    State = #{suspended := Stack, deferred := Deferred} = state(),
    case Stack of
        [Token | _] when is_map_key(Token, Deferred) ->
            erlang:put(?STATE, State#{deferred => maps:remove(Token, Deferred)}),
            resume_when_innermost(Token, maps:get(Token, Deferred));
        _ ->
            ok
    end.

%% Runs the JavaScript function of import Id: {values, Values} for the store,
%% {thrown, Id} when it throws, or {raise, ...} when the process fails. A
%% Suspending import outside a promising call throws a SuspendError, as in
%% V8, because a JavaScript frame lies between it and the promising export.
call_host(Id, Args, Types) ->
    F = host_function(Id),
    returned(fun() ->
                     case is_class(F, wasm_suspending) of
                         true -> throw(<<"SuspendError">>, <<"trying to suspend without WebAssembly.promising">>);
                         false -> buoy_ref:call(F, undefined, [to_js(A) || A <- Args])
                     end
             end, Types).

%% The returned value of the store for the result of Call.
returned(Call, Types) ->
    try
        {values, to_results(Types, Call())}
    catch
        error:Reason:Stack -> {thrown, keep_thrown(buoy_ref:caught(Reason, Stack))};
        Class:Reason:Stack -> {raise, Class, Reason, Stack}
    end.

to_results([], _) -> [];
to_results([T], V) -> [to_wasm(T, V)];
to_results(Types, V) ->
    Values = case ?IS_OBJECT(V) of
        true -> buoy_ref_iterator:to_list(V);
        false -> buoy_ref:type_error(<<"multi-return value must be iterable">>)
    end,
    length(Values) =:= length(Types) orelse buoy_ref:type_error(<<"multi-return length mismatch">>),
    [to_wasm(T, X) || {T, X} <- lists:zip(Types, Values)].

keep_thrown(V) ->
    #{thrown := Thrown, next := Next} = State = state(),
    erlang:put(?STATE, State#{thrown => Thrown#{Next => V}, next => Next + 1}),
    Next.

take_thrown(Id) ->
    #{thrown := Thrown} = State = state(),
    erlang:put(?STATE, State#{thrown => maps:remove(Id, Thrown)}),
    maps:get(Id, Thrown).

%% Detaches the buffer of each memory that grew.
detach(Grown) -> lists:foreach(fun detach_memory/1, Grown).

detach_memory(H) ->
    case maps:get(objects, state()) of
        #{H := M} ->
            case buoy_heap:slots(M) of
                {_, _, none} -> ok;
                {_, true, _} -> buoy_heap:set_slots(M, {H, true, none});
                {_, false, Buffer} ->
                    buoy_ref_buffer:detach(Buffer),
                    buoy_heap:set_slots(M, {H, false, none})
            end;
        _ ->
            ok
    end.

%%% The store of the process

store() -> maps:get(store, state()).

state() ->
    case erlang:get(?STATE) of
        undefined ->
            Limit = buoy_guard:limit(os:getenv("BUOY_MAX_MEMORY", "")),
            Store = try buoy_native:wasm_store(Limit)
                    catch error:_ -> throw('Error', <<"WebAssembly is not available: the runtime has no buoy_native library">>)
                    end,
            State = #{store => Store, objects => #{}, hosts => #{}, host_ids => #{},
                      externs => #{}, extern_ids => #{}, thrown => #{}, suspended => [], deferred => #{}, next => 1},
            erlang:put(?STATE, State),
            State;
        State ->
            State
    end.

%% The value of a reply, or the error it names.
reply(ok, _Context) -> undefined;
reply({ok, V}, _Context) -> V;
reply({trap, Message}, _Context) -> throw(<<"RuntimeError">>, Message);
reply(stack_overflow, _Context) -> throw('RangeError', <<"Maximum call stack size exceeded">>);
reply({thrown, Id}, _Context) -> erlang:error({'$throw', take_thrown(Id)});
reply(aborted, _Context) -> erlang:error(aborted);
reply({error, Kind, Message}, Context) ->
    Text = case Context of
        <<>> -> Message;
        _ -> <<Context/binary, ": ", Message/binary>>
    end,
    case Kind of
        link_error -> throw(<<"LinkError">>, Text);
        runtime_error -> throw(<<"RuntimeError">>, Text);
        range_error -> throw('RangeError', Text);
        type_error -> throw('TypeError', Text)
    end.

compile(Bytes, Context) ->
    case buoy_native:wasm_compile(Bytes) of
        {ok, Module} -> Module;
        {error, Message} -> throw(<<"CompileError">>, <<Context/binary, ": ", Message/binary>>)
    end.

%%% Values

%% ToWebAssemblyValue: the value of the store for V of the type Type.
to_wasm(i32, V) -> {i32, buoy_ref_number:to_int32(buoy_ref:to_number(V))};
to_wasm(i64, V) ->
    {'$bigint', I} = buoy_ref_bigint:to_big_int(V),
    {i64, buoy_ref_bigint:as_int_n(64, I)};
to_wasm(f32, V) -> {f32, buoy_ref:to_number(V)};
to_wasm(f64, V) -> {f64, buoy_ref:to_number(V)};
to_wasm(v128, _V) -> buoy_ref:type_error(<<"type incompatibility when transforming from/to JS">>);
to_wasm(funcref, null) -> {funcref, null};
to_wasm(funcref, V) ->
    case func_handle(V) of
        none -> buoy_ref:type_error(<<"type incompatibility when transforming from/to JS">>);
        H -> {funcref, H}
    end;
to_wasm(externref, null) -> {externref, null};
to_wasm(externref, V) -> {externref, extern_id(V)};
to_wasm(_, null) -> {externref, null};
to_wasm(_, _V) -> buoy_ref:type_error(<<"type incompatibility when transforming from/to JS">>).

%% ToJSValue.
to_js({i32, I}) -> I;
to_js({i64, I}) -> {'$bigint', I};
to_js({f32, N}) -> buoy_ref_number:canonical(N);
to_js({f64, N}) -> buoy_ref_number:canonical(N);
to_js(null) -> null;
to_js({funcref, H}) -> extern_object(reply(command({func_type, H}), <<>>));
to_js({host, Id}) -> host_function(Id);
to_js({externref, Id}) -> maps:get(Id, maps:get(externs, state()));
to_js(_) -> buoy_ref:type_error(<<"type incompatibility when transforming from/to JS">>).

extern_id(V) ->
    #{externs := Externs, extern_ids := Ids, next := Next} = State = state(),
    case Ids of
        #{V := Id} -> Id;
        _ ->
            erlang:put(?STATE, State#{externs => Externs#{Next => V}, extern_ids => Ids#{V => Next}, next => Next + 1}),
            Next
    end.

val_type(<<"i32">>, _) -> i32;
val_type(<<"i64">>, _) -> i64;
val_type(<<"f32">>, _) -> f32;
val_type(<<"f64">>, _) -> f64;
val_type(<<"v128">>, _) -> v128;
val_type(Name, Message) -> ref_type(Name, Message).

ref_type(<<"anyfunc">>, _) -> funcref;
ref_type(<<"funcref">>, _) -> funcref;
ref_type(<<"externref">>, _) -> externref;
ref_type(<<"anyref">>, _) -> anyref;
ref_type(<<"exnref">>, _) -> exnref;
ref_type(_, Message) -> buoy_ref:type_error(Message).

%% DefaultValue of a table element.
default(externref) -> undefined;
default(_) -> null.

default_global(i64) -> {'$bigint', 0};
default_global(externref) -> undefined;
default_global(T) when T =:= funcref; T =:= anyref; T =:= exnref -> null;
default_global(_) -> 0.

%%% Methods

-spec method(binary(), binary(), term(), list()) -> term().
method(<<"WebAssembly">>, <<"validate">>, _This, Args) ->
    buoy_native:wasm_validate(buffer_source(arg(1, Args), <<"WebAssembly.validate()">>, 0));
method(<<"WebAssembly">>, <<"compile">>, _This, Args) ->
    later(fun() -> Bytes = buffer_source(arg(1, Args), <<"WebAssembly.compile()">>, 0),
                   fun() -> new_module(Bytes, <<"WebAssembly.compile()">>) end
          end);
method(<<"WebAssembly">>, <<"instantiate">>, _This, Args) ->
    Context = <<"WebAssembly.instantiate()">>,
    Source = arg(1, Args),
    Imports = arg(2, Args),
    case is_class(Source, wasm_module) of
        true ->
            later(fun() -> fun() -> instance(Source, Imports, intrinsic(<<"Instance">>), Context) end end);
        false ->
            later(fun() ->
                          Bytes = buffer_source(Source, Context, 0),
                          Imports =:= undefined orelse ?IS_OBJECT(Imports) orelse
                              buoy_ref:type_error(<<Context/binary, ": Argument 1 must be an object">>),
                          fun() ->
                                  Module = new_module(Bytes, Context),
                                  Instance = instance(Module, Imports, intrinsic(<<"Instance">>), Context),
                                  buoy_heap:object(?OBJECT_PROTO, [{<<"module">>, Module}, {<<"instance">>, Instance}])
                          end
                  end)
    end;
method(<<"WebAssembly">>, <<"compileStreaming">>, _This, Args) -> streaming(arg(1, Args), none);
method(<<"WebAssembly">>, <<"instantiateStreaming">>, _This, Args) -> streaming(arg(1, Args), {imports, arg(2, Args)});
method(<<"WebAssembly">>, <<"promising">>, _This, Args) ->
    F = arg(1, Args),
    H = func_handle(F),
    H =/= none orelse buoy_ref:type_error(<<"WebAssembly.promising(): Argument 0 must be a WebAssembly exported function">>),
    {func, _, Params, Results, _} = reply(command({func_type, H}), <<>>),
    Call = fun(_, CallArgs) ->
                   P = buoy_jobs:new_promise(),
                   try [to_wasm(T, V) || {T, V} <- lists:zip(Params, pad(CallArgs, length(Params)))] of
                       Values ->
                           Store = store(),
                           pump_promising(Store, buoy_native:wasm_command(Store, {call, H, Values}), {P, Results})
                   catch
                       error:{'$throw', E} -> buoy_jobs:reject_promise(P, E)
                   end,
                   P
           end,
    buoy_heap:function(Call, <<>>, length(Params), #{});
method(<<"WebAssembly.Module">>, <<"imports">>, _This, Args) ->
    {Res, _} = module_arg(arg(1, Args), <<"WebAssembly.Module.imports()">>),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"module">>, buoy_ref_string:from_utf8(M)}, {<<"name">>, buoy_ref_string:from_utf8(N)}, {<<"kind">>, kind(T)}])
                         || {M, N, T} <- buoy_native:wasm_imports(Res)]);
method(<<"WebAssembly.Module">>, <<"exports">>, _This, Args) ->
    {Res, _} = module_arg(arg(1, Args), <<"WebAssembly.Module.exports()">>),
    buoy_heap:new_array([buoy_heap:object(?OBJECT_PROTO, [{<<"name">>, buoy_ref_string:from_utf8(N)}, {<<"kind">>, kind(T)}])
                         || {N, T} <- buoy_native:wasm_exports(Res)]);
method(<<"WebAssembly.Module">>, <<"customSections">>, _This, Args) ->
    Context = <<"WebAssembly.Module.customSections()">>,
    {_, Bytes} = module_arg(arg(1, Args), Context),
    arg(2, Args) =:= undefined andalso buoy_ref:type_error(<<Context/binary, ": Argument 1 is required">>),
    Name = buoy_ref_string:to_utf8(buoy_ref:to_string(arg(2, Args))),
    buoy_heap:new_array([new_buffer(Data) || {N, Data} <- custom_sections(Bytes), N =:= Name]);
method(<<"WebAssembly.Instance.prototype">>, <<"exports">>, This, _Args) ->
    receiver(This, wasm_instance, <<"WebAssembly.Instance.exports">>);
method(<<"WebAssembly.Memory.prototype">>, <<"buffer">>, This, _Args) ->
    receiver(This, wasm_memory, <<"WebAssembly.Memory.buffer">>),
    buffer(This);
method(<<"WebAssembly.Memory.prototype">>, <<"grow">>, This, Args) ->
    Context = <<"WebAssembly.Memory.grow()">>,
    {H, _, _} = receiver(This, wasm_memory, Context),
    Delta = enforce_range(arg(1, Args), Context, <<"Argument 0">>, 16#FFFFFFFF),
    case command({memory_grow, H, Delta}) of
        {ok, Old} ->
            detach_memory(H),
            Old;
        {error, _, _} ->
            throw('RangeError', <<Context/binary, ": Maximum memory size exceeded">>)
    end;
method(<<"WebAssembly.Table.prototype">>, <<"length">>, This, _Args) ->
    {H, _} = receiver(This, wasm_table, <<"WebAssembly.Table.length">>),
    reply(command({table_size, H}), <<>>);
method(<<"WebAssembly.Table.prototype">>, <<"get">>, This, Args) ->
    Context = <<"WebAssembly.Table.get()">>,
    {H, _} = receiver(This, wasm_table, Context),
    Index = enforce_range(arg(1, Args), Context, <<"Argument 0">>, 16#FFFFFFFF),
    [V] = reply(command({table_get, H, Index}), <<>>),
    to_js(V);
method(<<"WebAssembly.Table.prototype">>, <<"set">>, This, Args) ->
    Context = <<"WebAssembly.Table.set()">>,
    {H, Element} = receiver(This, wasm_table, Context),
    Index = enforce_range(arg(1, Args), Context, <<"Argument 0">>, 16#FFFFFFFF),
    Value = case Args of
        [_, V | _] -> element_value(Element, V, Context);
        _ -> to_wasm(Element, default(Element))
    end,
    reply(command({table_set, H, Index, Value}), <<>>);
method(<<"WebAssembly.Table.prototype">>, <<"grow">>, This, Args) ->
    Context = <<"WebAssembly.Table.grow()">>,
    {H, Element} = receiver(This, wasm_table, Context),
    Delta = enforce_range(arg(1, Args), Context, <<"Argument 0">>, 16#FFFFFFFF),
    Value = case Args of
        [_, V | _] -> element_value(Element, V, Context);
        _ -> to_wasm(Element, default(Element))
    end,
    reply(command({table_grow, H, Delta, Value}), <<>>);
method(<<"WebAssembly.Global.prototype">>, Name, This, Args) when Name =:= <<"value">>; Name =:= <<"valueOf">> ->
    {H, _, _} = receiver(This, wasm_global, <<"WebAssembly.Global.", Name/binary>>),
    _ = Args,
    [V] = reply(command({global_get, H}), <<>>),
    to_js(V);
method(<<"WebAssembly.Global.prototype">>, <<"set value">>, This, Args) ->
    {H, Type, Mutable} = receiver(This, wasm_global, <<"set WebAssembly.Global.value">>),
    Mutable orelse buoy_ref:type_error(<<"set WebAssembly.Global.value: Can't set the value of an immutable global.">>),
    Args =:= [] andalso buoy_ref:type_error(<<"set WebAssembly.Global.value: Argument 0 is required">>),
    reply(command({global_set, H, to_wasm(Type, arg(1, Args))}), <<>>);
method(<<"WebAssembly.Exception.prototype">>, <<"getArg">>, This, Args) ->
    Context = <<"WebAssembly.Exception.getArg()">>,
    {Tag, Values} = receiver(This, wasm_exception, Context),
    is_class(arg(1, Args), wasm_tag) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a WebAssembly.Tag">>),
    arg(1, Args) =:= Tag orelse buoy_ref:type_error(<<Context/binary, ": First argument does not match the exception tag">>),
    Index = enforce_range(arg(2, Args), Context, <<"Index">>, 16#FFFFFFFF),
    Index < length(Values) orelse throw('RangeError', <<Context/binary, ": Index out of range">>),
    lists:nth(Index + 1, Values);
method(<<"WebAssembly.Exception.prototype">>, <<"is">>, This, Args) ->
    Context = <<"WebAssembly.Exception.is()">>,
    {Tag, _} = receiver(This, wasm_exception, Context),
    is_class(arg(1, Args), wasm_tag) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a WebAssembly.Tag">>),
    arg(1, Args) =:= Tag.

element_value(funcref, V, Context) ->
    V =:= null orelse func_handle(V) =/= none orelse
        buoy_ref:type_error(<<Context/binary, ": Argument 1 is invalid for table: function-typed object expected">>),
    to_wasm(funcref, V);
element_value(Element, V, _Context) -> to_wasm(Element, V).

kind({func, _, _, _, _}) -> <<"function">>;
kind({memory, _, _, _, _, _}) -> <<"memory">>;
kind({table, _, _, _, _}) -> <<"table">>;
kind({global, _, _, _}) -> <<"global">>;
kind({tag, _, _}) -> <<"tag">>.

module_arg(M, Context) ->
    is_class(M, wasm_module) orelse buoy_ref:type_error(<<Context/binary, ": Argument 0 must be a WebAssembly.Module">>),
    buoy_heap:slots(M).

new_module(Bytes, Context) ->
    module_object(compile(Bytes, Context), Bytes, intrinsic(<<"Module">>)).

%% A promise of the value of the fun that Start returns. Start runs now,
%% so the bytes of a buffer are copied at the call, and its fun runs as a
%% job, as V8 compiles and instantiates in the background. A throw rejects.
later(Start) ->
    P = buoy_jobs:new_promise(),
    try Start() of
        Work -> buoy_jobs:enqueue(fun() -> settle(P, Work) end)
    catch
        error:{'$throw', E} -> buoy_jobs:reject_promise(P, E)
    end,
    P.

settle(P, Work) ->
    try Work() of
        V -> buoy_jobs:resolve_promise(P, V)
    catch
        error:{'$throw', E} -> buoy_jobs:reject_promise(P, E)
    end.

%% compileStreaming and instantiateStreaming: the callback that
%% internalBinding('wasm_web_api').setImplementation gave reads the
%% Response into a stream state, whose finish compiles the bytes.
streaming(Source, Mode) ->
    P = buoy_jobs:new_promise(),
    Implementation = buoy_binding_wasm_web_api:implementation(),
    Chunks = buoy_heap:cell([]),
    Push = fun(_, Args) ->
                   buoy_heap:cell_set(Chunks, [buffer_source(arg(1, Args), <<"push">>, 0) | buoy_heap:cell_get(Chunks)]),
                   undefined
           end,
    Finish = fun(_, _) ->
                     Bytes = iolist_to_binary(lists:reverse(buoy_heap:cell_get(Chunks))),
                     Work = fun() ->
                                    Module = new_module(Bytes, <<"WebAssembly.compileStreaming()">>),
                                    case Mode of
                                        none -> Module;
                                        {imports, Imports} ->
                                            Instance = instance(Module, Imports, intrinsic(<<"Instance">>), <<"WebAssembly.instantiateStreaming()">>),
                                            buoy_heap:object(?OBJECT_PROTO, [{<<"module">>, Module}, {<<"instance">>, Instance}])
                                    end
                            end,
                     buoy_jobs:enqueue(fun() -> settle(P, Work) end),
                     undefined
             end,
    Abort = fun(_, Args) -> buoy_jobs:reject_promise(P, arg(1, Args)), undefined end,
    State = buoy_heap:object(?OBJECT_PROTO, [{<<"setURL">>, buoy_heap:function(fun(_, _) -> undefined end, <<"setURL">>, 1, #{})},
                                             {<<"push">>, buoy_heap:function(Push, <<"push">>, 1, #{})},
                                             {<<"finish">>, buoy_heap:function(Finish, <<"finish">>, 0, #{})},
                                             {<<"abort">>, buoy_heap:function(Abort, <<"abort">>, 1, #{})}]),
    try buoy_ref:call(Implementation, undefined, [State, Source])
    catch error:{'$throw', E} -> buoy_jobs:reject_promise(P, E)
    end,
    P.

%% The bytes of a BufferSource, copied.
buffer_source(V, Context, Index) ->
    is_buffer_source(V) orelse
        buoy_ref:type_error(<<Context/binary, ": Argument ", (integer_to_binary(Index))/binary, " must be a buffer source">>),
    buoy_node_encoding:view_bytes(V).

is_buffer_source(V) when ?IS_OBJECT(V) ->
    lists:member(buoy_heap:class_of(V), [typed_array, data_view, array_buffer, shared_array_buffer]);
is_buffer_source(_) -> false.

new_buffer(Bytes) ->
    B = buoy_ref_buffer:allocate(byte_size(Bytes)),
    buoy_ref_buffer:write(B, 0, Bytes),
    B.

%% [EnforceRange] unsigned long.
enforce_range(V, Context, What, Max) ->
    N = buoy_ref:to_number(V),
    case N of
        _ when N =:= 'NaN'; N =:= 'Infinity'; N =:= '-Infinity' ->
            buoy_ref:type_error(<<Context/binary, ": ", What/binary, " must be convertible to a valid number">>);
        _ ->
            I = buoy_ref_number:to_integer_or_infinity(N),
            I >= 0 orelse buoy_ref:type_error(<<Context/binary, ": ", What/binary, " must be non-negative">>),
            I =< Max orelse buoy_ref:type_error(<<Context/binary, ": ", What/binary, " must be in the unsigned long range">>),
            I
    end.

is_class(V, Class) -> ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= Class.

receiver(This, Class, Context) ->
    is_class(This, Class) orelse
        buoy_ref:type_error(<<Context/binary, ": Receiver is not a ", (class_name(Class))/binary>>),
    buoy_heap:slots(This).

class_name(wasm_instance) -> <<"WebAssembly.Instance">>;
class_name(wasm_memory) -> <<"WebAssembly.Memory">>;
class_name(wasm_table) -> <<"WebAssembly.Table">>;
class_name(wasm_global) -> <<"WebAssembly.Global">>;
class_name(wasm_exception) -> <<"WebAssembly.Exception">>.

%%% The buffer of a memory

%% The ArrayBuffer of the memory M, a new one after each grow.
buffer(M) ->
    case buoy_heap:slots(M) of
        {_, _, Buffer} when Buffer =/= none -> Buffer;
        {H, Shared, none} ->
            Size = reply(command({memory_size, H}), <<>>),
            {Class, Proto} = case Shared of
                true -> {shared_array_buffer, buoy_heap:intrinsic('SharedArrayBuffer.prototype')};
                false -> {array_buffer, buoy_heap:intrinsic('ArrayBuffer.prototype')}
            end,
            Buffer = buoy_heap:new_exotic(Class, Proto, {{'$wasm', H}, Size, none}),
            buoy_heap:set_slots(M, {H, Shared, Buffer}),
            Buffer
    end.

%% Count bytes of the memory H from Offset, for buoy_ref_buffer.
-spec read(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> binary().
read(H, Offset, Count) -> reply(command({memory_read, H, Offset, Count}), <<>>).

-spec write(non_neg_integer(), non_neg_integer(), binary()) -> ok.
write(H, Offset, Bytes) ->
    _ = reply(command({memory_write, H, Offset, Bytes}), <<>>),
    ok.

%%% The sections of a module

%% The custom sections of the bytes of a valid module: [{Name, Data}].
custom_sections(<<_:8/binary, Sections/binary>>) -> custom_sections(Sections, []).

custom_sections(<<>>, Acc) -> lists:reverse(Acc);
custom_sections(<<Id, Rest/binary>>, Acc) ->
    {Size, Body} = leb(Rest),
    <<Section:Size/binary, Next/binary>> = Body,
    case Id of
        0 ->
            {Length, Named} = leb(Section),
            <<Name:Length/binary, Data/binary>> = Named,
            custom_sections(Next, [{Name, Data} | Acc]);
        _ ->
            custom_sections(Next, Acc)
    end.

%% The func index of each exported func, by export name.
func_indexes(<<_:8/binary, Sections/binary>>) ->
    try exports_section(Sections) catch error:_ -> #{} end.

exports_section(<<>>) -> #{};
exports_section(<<Id, Rest/binary>>) ->
    {Size, Body} = leb(Rest),
    <<Section:Size/binary, Next/binary>> = Body,
    case Id of
        7 ->
            {Count, Entries} = leb(Section),
            export_entries(Count, Entries, #{});
        _ ->
            exports_section(Next)
    end.

export_entries(0, _, Acc) -> Acc;
export_entries(N, Bin, Acc) ->
    {Length, Named} = leb(Bin),
    <<Name:Length/binary, Kind, Indexed/binary>> = Named,
    {Index, Rest} = leb(Indexed),
    Acc1 = case Kind of
        0 -> Acc#{Name => integer_to_binary(Index)};
        _ -> Acc
    end,
    export_entries(N - 1, Rest, Acc1).

leb(Bin) -> leb(Bin, 0, 0).

leb(<<1:1, Low:7, Rest/binary>>, Shift, Acc) -> leb(Rest, Shift + 7, Acc bor (Low bsl Shift));
leb(<<0:1, Low:7, Rest/binary>>, Shift, Acc) -> {Acc bor (Low bsl Shift), Rest}.
