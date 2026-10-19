%% internalBinding('sqlite') (src/node_sqlite.cc): DatabaseSync, StatementSync,
%% Session, the SQLTagStore of createTagStore, backup(), and the constants.
%%
%% Each DatabaseSync owns a connection thread of buoy_native
%% (crates/buoy-native/src/sqlite.rs). A method sends a command and waits for
%% its reply; a user-defined function, an aggregate, the authorizer, and the
%% callbacks of applyChangeset reach the realm as calls while it waits, and
%% the realm answers each one. A JavaScript exception in a call makes SQLite
%% fail the statement, and the method then throws the exception, as Node's
%% ignore_next_sqlite_error_ does.
-module(buoy_binding_sqlite).

-include("buoy_ref.hrl").

-export([binding/0, command/2]).

-define(DB, {'#', ?MODULE, <<"db">>}).
-define(STMT, {'#', ?MODULE, <<"stmt">>}).
-define(SESSION, {'#', ?MODULE, <<"session">>}).
-define(ITER, {'#', ?MODULE, <<"iter">>}).
-define(STORE, {'#', ?MODULE, <<"store">>}).
-define(LIMITS, {'#', ?MODULE, <<"limits">>}).
%% The JavaScript exception of a call, which the command throws when it ends.
-define(PENDING, '$buoy_sqlite_pending').
%% The callbacks of the applyChangeset that runs.
-define(APPLY, '$buoy_sqlite_apply').

-define(SQLITE_OK, 0).
-define(SQLITE_DENY, 1).
-define(SQLITE_IGNORE, 2).
-define(SQLITE_BUSY, 5).
-define(SQLITE_LOCKED, 6).
-define(SQLITE_DONE, 101).
-define(SQLITE_CHANGESET_ABORT, 2).
-define(SQLITE_UTF8, 1).
-define(SQLITE_DETERMINISTIC, 16#800).
-define(SQLITE_DIRECTONLY, 16#80000).
-define(DBCONFIG_ENABLE_LOAD_EXTENSION, 1005).
-define(DBCONFIG_DEFENSIVE, 1010).
-define(MAX_SAFE, 9007199254740991).
-define(INT32_MAX, 2147483647).

%% kLimitMapping: the names of the limits, in the order of their ids.
-define(LIMIT_NAMES, [<<"length">>, <<"sqlLength">>, <<"column">>, <<"exprDepth">>, <<"compoundSelect">>,
                      <<"vdbeOp">>, <<"functionArg">>, <<"attach">>, <<"likePatternLength">>,
                      <<"variableNumber">>, <<"triggerDepth">>]).

-spec binding() -> term().
binding() ->
    buoy_node:object([
        {<<"DatabaseSync">>, database_class()},
        {<<"StatementSync">>, illegal_class(<<"StatementSync">>, statement)},
        {<<"Session">>, illegal_class(<<"Session">>, session)},
        {<<"constants">>, constants()},
        {<<"backup">>, buoy_node:fn(<<"backup">>, 2, fun(_, Args) -> backup(Args) end)}]).

%%% Classes

database_class() ->
    Proto = buoy_node:object([]),
    Class = buoy_heap:function(fun(_, _) -> construct_call_required() end, <<"DatabaseSync">>, 0,
                               #{construct => fun(NewTarget, Args) -> new_database(NewTarget, Proto, Args) end}),
    buoy_heap:define(Proto, <<"constructor">>, #{value => Class, writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(Class, <<"prototype">>, #{value => Proto, writable => false, enumerable => false, configurable => false}),
    methods(Proto, [
        {<<"open">>, fun(This, _) -> open(This), undefined end},
        {<<"close">>, fun(This, _) -> close(This) end},
        {?SYM(dispose), fun(This, _) -> dispose(This) end},
        {<<"prepare">>, fun prepare/2},
        {<<"exec">>, fun exec/2},
        {<<"function">>, fun function/2},
        {<<"createTagStore">>, fun create_tag_store/2},
        {<<"location">>, fun location/2},
        {<<"aggregate">>, fun aggregate/2},
        {<<"createSession">>, fun create_session/2},
        {<<"applyChangeset">>, fun apply_changeset/2},
        {<<"enableLoadExtension">>, fun enable_load_extension/2},
        {<<"enableDefensive">>, fun enable_defensive/2},
        {<<"loadExtension">>, fun load_extension/2},
        {<<"setAuthorizer">>, fun set_authorizer/2}]),
    Getters = [{<<"isOpen">>, fun(This, _) -> maps:get(open, db_state(This)) end},
               {<<"isTransaction">>, fun(This, _) -> is_transaction(This) end},
               {<<"limits">>, fun(This, _) -> limits(This) end}],
    put_realm(database_getters, [{Name, getter(Name, Fun)} || {Name, Fun} <- Getters]),
    Class.

%% StatementSync and Session: their constructors throw, and the binding makes
%% their instances.
illegal_class(Name, Kind) ->
    Class = buoy_node:constructor(Name, 0, fun(_, _) -> illegal_constructor() end),
    Proto = buoy_heap:get(Class, <<"prototype">>),
    put_realm({proto, Kind}, Proto),
    case Kind of
        statement ->
            methods(Proto, [
                {<<"iterate">>, fun(This, Args) -> statement_iterate(This, Args) end},
                {<<"all">>, fun(This, Args) -> statement_all(This, Args) end},
                {<<"get">>, fun(This, Args) -> statement_get(This, Args) end},
                {<<"run">>, fun(This, Args) -> statement_run(This, Args) end},
                {<<"columns">>, fun(This, _) -> columns(This) end},
                {<<"setAllowBareNamedParameters">>, fun(This, Args) ->
                    set_flag(This, Args, bare, <<"The \"allowBareNamedParameters\" argument must be a boolean.">>) end},
                {<<"setAllowUnknownNamedParameters">>, fun(This, Args) ->
                    set_flag(This, Args, unknown, <<"The \"enabled\" argument must be a boolean.">>) end},
                {<<"setReadBigInts">>, fun(This, Args) ->
                    set_flag(This, Args, big_ints, <<"The \"readBigInts\" argument must be a boolean.">>) end},
                {<<"setReturnArrays">>, fun(This, Args) ->
                    set_flag(This, Args, return_arrays, <<"The \"returnArrays\" argument must be a boolean.">>) end}]),
            put_realm(statement_getters,
                      [{<<"sourceSQL">>, getter(<<"sourceSQL">>, fun(This, _) -> source_sql(This) end)},
                       {<<"expandedSQL">>, getter(<<"expandedSQL">>, fun(This, _) -> expanded_sql(This) end)}]);
        session ->
            methods(Proto, [
                {<<"changeset">>, fun(This, _) -> session_changes(This, false) end},
                {<<"patchset">>, fun(This, _) -> session_changes(This, true) end},
                {<<"close">>, fun(This, _) -> session_close(This) end},
                {?SYM(dispose), fun(This, _) -> swallow(fun() -> session_close(This) end) end}])
    end,
    Class.

%% The methods of a FunctionTemplate, whose length is 0.
methods(Proto, Methods) ->
    [buoy_heap:define(Proto, Key, #{value => buoy_node:fn(method_name(Key), 0, Fun), writable => true,
                                    enumerable => false, configurable => true})
     || {Key, Fun} <- Methods],
    ok.

method_name({'$sym', _, Description}) -> <<"[", Description/binary, "]">>;
method_name(Name) -> Name.

getter(Name, Fun) -> buoy_node:fn(<<"get ", Name/binary>>, 0, Fun).

%% The accessors of an InstanceTemplate, with DontDelete.
define_getters(Object, Getters) ->
    [buoy_heap:define(Object, Name, #{get => Get, enumerable => true, configurable => false}) || {Name, Get} <- Getters],
    ok.

put_realm(Key, Value) -> erlang:put({?MODULE, buoy_heap:realm(), Key}, Value).

get_realm(Key) ->
    case erlang:get({?MODULE, buoy_heap:realm(), Key}) of
        undefined ->
            _ = buoy_node:binding(<<"sqlite">>),
            erlang:get({?MODULE, buoy_heap:realm(), Key});
        Value -> Value
    end.

constants() ->
    Names = [{<<"SQLITE_CHANGESET_OMIT">>, 0}, {<<"SQLITE_CHANGESET_REPLACE">>, 1}, {<<"SQLITE_CHANGESET_ABORT">>, 2},
             {<<"SQLITE_CHANGESET_DATA">>, 1}, {<<"SQLITE_CHANGESET_NOTFOUND">>, 2},
             {<<"SQLITE_CHANGESET_CONFLICT">>, 3}, {<<"SQLITE_CHANGESET_CONSTRAINT">>, 4},
             {<<"SQLITE_CHANGESET_FOREIGN_KEY">>, 5}, {<<"SQLITE_OK">>, 0}, {<<"SQLITE_DENY">>, 1},
             {<<"SQLITE_IGNORE">>, 2}, {<<"SQLITE_CREATE_INDEX">>, 1}, {<<"SQLITE_CREATE_TABLE">>, 2},
             {<<"SQLITE_CREATE_TEMP_INDEX">>, 3}, {<<"SQLITE_CREATE_TEMP_TABLE">>, 4},
             {<<"SQLITE_CREATE_TEMP_TRIGGER">>, 5}, {<<"SQLITE_CREATE_TEMP_VIEW">>, 6},
             {<<"SQLITE_CREATE_TRIGGER">>, 7}, {<<"SQLITE_CREATE_VIEW">>, 8}, {<<"SQLITE_DELETE">>, 9},
             {<<"SQLITE_DROP_INDEX">>, 10}, {<<"SQLITE_DROP_TABLE">>, 11}, {<<"SQLITE_DROP_TEMP_INDEX">>, 12},
             {<<"SQLITE_DROP_TEMP_TABLE">>, 13}, {<<"SQLITE_DROP_TEMP_TRIGGER">>, 14},
             {<<"SQLITE_DROP_TEMP_VIEW">>, 15}, {<<"SQLITE_DROP_TRIGGER">>, 16}, {<<"SQLITE_DROP_VIEW">>, 17},
             {<<"SQLITE_INSERT">>, 18}, {<<"SQLITE_PRAGMA">>, 19}, {<<"SQLITE_READ">>, 20},
             {<<"SQLITE_SELECT">>, 21}, {<<"SQLITE_TRANSACTION">>, 22}, {<<"SQLITE_UPDATE">>, 23},
             {<<"SQLITE_ATTACH">>, 24}, {<<"SQLITE_DETACH">>, 25}, {<<"SQLITE_ALTER_TABLE">>, 26},
             {<<"SQLITE_REINDEX">>, 27}, {<<"SQLITE_ANALYZE">>, 28}, {<<"SQLITE_CREATE_VTABLE">>, 29},
             {<<"SQLITE_DROP_VTABLE">>, 30}, {<<"SQLITE_FUNCTION">>, 31}, {<<"SQLITE_SAVEPOINT">>, 32},
             {<<"SQLITE_COPY">>, 0}, {<<"SQLITE_RECURSIVE">>, 33}],
    Constants = buoy_node:object([]),
    %% NODE_DEFINE_CONSTANT: ReadOnly and DontDelete.
    [buoy_heap:define(Constants, Name, #{value => Value, writable => false, enumerable => true, configurable => false})
     || {Name, Value} <- Names],
    Constants.

%%% DatabaseSync

new_database(NewTarget, Fallback, Args) ->
    Proto = case buoy_heap:get(NewTarget, <<"prototype">>) of
        P when ?IS_OBJECT(P) -> P;
        _ -> Fallback
    end,
    This = buoy_heap:new_object(Proto),
    define_getters(This, get_realm(database_getters)),
    buoy_heap:define(This, buoy_heap:symbol_for(<<"sqlite-type">>),
                     #{value => <<"node:sqlite">>, writable => true, enumerable => true, configurable => true}),
    Location = database_path(buoy_node:arg(1, Args), <<"path">>),
    {Open, Config} = case length(Args) > 1 of
        true -> database_options(buoy_node:arg(2, Args));
        false -> {true, default_config()}
    end,
    buoy_heap:private_put(This, ?DB, #{conn => buoy_native:sqlite_connection(), open => false, epoch => 0,
                                       location => Location, config => Config,
                                       enable_extension => maps:get(allow_extension, Config),
                                       authorizer => null, limits => undefined}),
    case Open of
        true -> open(This);
        false -> ok
    end,
    This.

default_config() ->
    #{read_only => false, foreign_keys => true, dqs => false, allow_extension => false, timeout => 0,
      big_ints => false, return_arrays => false, bare => true, unknown => false, defensive => true, limits => []}.

%% ValidateDatabasePath: a string or a Uint8Array without a zero byte, or a
%% file: URL.
database_path(Path, Field) ->
    Invalid = fun() ->
        type_error(<<"The \"", Field/binary, "\" argument must be a string, Uint8Array, or URL without null bytes.">>)
    end,
    case Path of
        _ when ?IS_STRING(Path) ->
            no_null(utf8(Path), Invalid);
        _ when ?IS_OBJECT(Path) ->
            case is_uint8_array(Path) of
                true -> no_null(buoy_node_encoding:view_bytes(Path), Invalid);
                false ->
                    case buoy_heap:get(Path, <<"href">>) of
                        Href when ?IS_STRING(Href) ->
                            Location = no_null(utf8(Href), Invalid),
                            case Location of
                                <<"file:", _/binary>> -> Location;
                                _ -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_URL_SCHEME">>,
                                                          <<"The URL must be of scheme file:">>)
                            end;
                        _ -> Invalid()
                    end
            end;
        _ -> Invalid()
    end.

no_null(Bytes, Invalid) ->
    case binary:match(Bytes, <<0>>) of
        nomatch -> Bytes;
        _ -> Invalid()
    end.

database_options(Options) when ?IS_OBJECT(Options) ->
    Bool = fun(Key) -> option_boolean(Options, Key, <<"options.", Key/binary>>) end,
    Open = Bool(<<"open">>),
    Pairs = [{read_only, Bool(<<"readOnly">>)},
             {foreign_keys, Bool(<<"enableForeignKeyConstraints">>)},
             {dqs, Bool(<<"enableDoubleQuotedStringLiterals">>)},
             {allow_extension, Bool(<<"allowExtension">>)},
             {timeout, option_int32(Options, <<"timeout">>)},
             {big_ints, Bool(<<"readBigInts">>)},
             {return_arrays, Bool(<<"returnArrays">>)},
             {bare, Bool(<<"allowBareNamedParameters">>)},
             {unknown, Bool(<<"allowUnknownNamedParameters">>)},
             {defensive, Bool(<<"defensive">>)},
             {limits, initial_limits(buoy_heap:get(Options, <<"limits">>))}],
    Config = lists:foldl(fun({_, undefined}, C) -> C;
                            ({Key, Value}, C) -> C#{Key => Value}
                         end, default_config(), Pairs),
    {Open =/= false, Config};
database_options(_) ->
    type_error(<<"The \"options\" argument must be an object.">>).

option_boolean(Options, Key, Field) ->
    case buoy_heap:get(Options, Key) of
        undefined -> undefined;
        V when is_boolean(V) -> V;
        _ -> type_error(<<"The \"", Field/binary, "\" argument must be a boolean.">>)
    end.

option_int32(Options, Key) ->
    case buoy_heap:get(Options, Key) of
        undefined -> undefined;
        V -> case is_int32(V) of
                 true -> V;
                 false -> type_error(<<"The \"options.", Key/binary, "\" argument must be an integer.">>)
             end
    end.

initial_limits(undefined) -> undefined;
initial_limits(Limits) when ?IS_OBJECT(Limits) ->
    lists:filtermap(
        fun({Id, Name}) ->
            case buoy_heap:get(Limits, Name) of
                undefined -> false;
                V ->
                    is_int32(V) orelse type_error(<<"The \"options.limits.", Name/binary, "\" argument must be an integer.">>),
                    V >= 0 orelse out_of_range(<<"The \"options.limits.", Name/binary, "\" argument must be non-negative.">>),
                    {true, {Id, V}}
            end
        end, lists:enumerate(0, ?LIMIT_NAMES));
initial_limits(_) ->
    type_error(<<"The \"options.limits\" argument must be an object.">>).

db_state(This) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?DB) of
        {ok, State} -> State;
        _ -> illegal_invocation()
    end.

save_db(This, State) -> buoy_heap:private_put(This, ?DB, State).

%% A DatabaseSync that is open, or the ERR_INVALID_STATE of Node.
open_db(This) ->
    State = db_state(This),
    maps:get(open, State) orelse invalid_state(<<"database is not open">>),
    State.

open(This) ->
    State = db_state(This),
    maps:get(open, State) andalso invalid_state(<<"database is already open">>),
    #{location := Location, config := Config} = State,
    #{read_only := ReadOnly, dqs := Dqs, foreign_keys := ForeignKeys, defensive := Defensive,
      timeout := Timeout, limits := Limits, allow_extension := AllowExtension} = Config,
    Command = {open, Location, ReadOnly, Dqs, ForeignKeys, Defensive, Timeout, Limits, AllowExtension},
    case call(This, Command) of
        ok ->
            save_db(This, (db_state(This))#{open => true});
        {failed, Kept, Failure} ->
            save_db(This, (db_state(This))#{open => Kept}),
            throw_sqlite(Failure)
    end.

close(This) ->
    open_db(This),
    check(call(This, close)),
    State = db_state(This),
    save_db(This, State#{open => false, epoch => maps:get(epoch, State) + 1}),
    undefined.

dispose(This) ->
    swallow(fun() -> close(This) end).

swallow(Fun) ->
    try Fun() of
        _ -> undefined
    catch
        error:{'$throw', _} -> undefined
    end.

is_transaction(This) ->
    open_db(This),
    check(call(This, is_transaction)).

prepare(This, Args) ->
    State = open_db(This),
    Sql = string_arg(buoy_node:arg(1, Args), <<"sql">>),
    Overrides = case Args of
        [_, Options | _] when Options =/= undefined -> prepare_options(Options);
        _ -> #{}
    end,
    #{config := Config} = State,
    Flags = maps:with([return_arrays, big_ints, bare, unknown], Config),
    new_statement(This, check(call(This, {prepare, Sql})), maps:merge(Flags, Overrides)).

prepare_options(Options) when ?IS_OBJECT(Options) ->
    Pairs = [{return_arrays, <<"returnArrays">>}, {big_ints, <<"readBigInts">>},
             {bare, <<"allowBareNamedParameters">>}, {unknown, <<"allowUnknownNamedParameters">>}],
    maps:from_list([{Flag, V} || {Flag, Key} <- Pairs,
                                 V <- [option_boolean(Options, Key, <<"options.", Key/binary>>)], V =/= undefined]);
prepare_options(_) ->
    type_error(<<"The \"options\" argument must be an object.">>).

exec(This, Args) ->
    open_db(This),
    Sql = string_arg(buoy_node:arg(1, Args), <<"sql">>),
    check(call(This, {exec, Sql})),
    undefined.

%% DatabaseSync::CustomFunction(name, [options,] function).
function(This, Args) ->
    open_db(This),
    Name = string_arg(buoy_node:arg(1, Args), <<"name">>),
    FnIndex = case length(Args) < 3 of
        true -> 2;
        false -> 3
    end,
    Options = case FnIndex of
        3 -> function_options(buoy_node:arg(2, Args));
        2 -> #{}
    end,
    Fn = buoy_node:arg(FnIndex, Args),
    buoy_heap:is_callable(Fn) orelse type_error(<<"The \"function\" argument must be a function.">>),
    Argc = case maps:get(varargs, Options, false) of
        true -> -1;
        false -> to_int32(buoy_heap:get(Fn, <<"length">>))
    end,
    Flags = ?SQLITE_UTF8
        bor flag(maps:get(deterministic, Options, false), ?SQLITE_DETERMINISTIC)
        bor flag(maps:get(direct_only, Options, false), ?SQLITE_DIRECTONLY),
    Id = erlang:unique_integer([positive]),
    erlang:put({?MODULE, function, Id}, {Fn, maps:get(big_ints, Options, false)}),
    check(call(This, {function, Name, Argc, Flags, Id})),
    undefined.

function_options(Options) when ?IS_OBJECT(Options) ->
    Pairs = [{big_ints, <<"useBigIntArguments">>}, {varargs, <<"varargs">>},
             {deterministic, <<"deterministic">>}, {direct_only, <<"directOnly">>}],
    maps:from_list([{Flag, V} || {Flag, Key} <- Pairs,
                                 V <- [option_boolean(Options, Key, <<"options.", Key/binary>>)], V =/= undefined]);
function_options(_) ->
    type_error(<<"The \"options\" argument must be an object.">>).

flag(true, Bit) -> Bit;
flag(false, _) -> 0.

%% DatabaseSync::AggregateFunction(name, options).
aggregate(This, Args) ->
    open_db(This),
    Name = utf8(buoy_ref:to_string(buoy_node:arg(1, Args))),
    Options = buoy_node:arg(2, Args),
    Get = fun(Key) ->
        case ?IS_OBJECT(Options) of
            true -> buoy_heap:get(Options, Key);
            false -> undefined
        end
    end,
    Start = Get(<<"start">>),
    Start =:= undefined andalso
        type_error(<<"The \"options.start\" argument must be a function or a primitive value.">>),
    Step = Get(<<"step">>),
    buoy_heap:is_callable(Step) orelse type_error(<<"The \"options.step\" argument must be a function.">>),
    Result = Get(<<"result">>),
    Bool = fun(Key) ->
        case Get(Key) of
            undefined -> false;
            V when is_boolean(V) -> V;
            _ -> type_error(<<"The \"options.", Key/binary, "\" argument must be a boolean.">>)
        end
    end,
    BigInts = Bool(<<"useBigIntArguments">>),
    Varargs = Bool(<<"varargs">>),
    DirectOnly = Bool(<<"directOnly">>),
    Inverse = case Get(<<"inverse">>) of
        undefined -> none;
        I -> buoy_heap:is_callable(I) orelse type_error(<<"The \"options.inverse\" argument must be a function.">>), I
    end,
    Argc = case Varargs of
        true -> -1;
        false ->
            StepArgs = to_int32(buoy_heap:get(Step, <<"length">>)) - 1,
            InverseArgs = case Inverse of
                none -> StepArgs;
                _ -> to_int32(buoy_heap:get(Inverse, <<"length">>)) - 1
            end,
            lists:max([StepArgs, InverseArgs, 0])
    end,
    Id = erlang:unique_integer([positive]),
    erlang:put({?MODULE, aggregate, Id},
               #{start => Start, step => Step, inverse => Inverse, big_ints => BigInts,
                 result => case buoy_heap:is_callable(Result) of
                               true -> Result;
                               false -> none
                           end}),
    Flags = ?SQLITE_UTF8 bor flag(DirectOnly, ?SQLITE_DIRECTONLY),
    check(call(This, {aggregate, Name, Argc, Flags, Id, Inverse =/= none})),
    undefined.

location(This, Args) ->
    open_db(This),
    Name = case buoy_node:arg(1, Args) of
        undefined -> <<"main">>;
        V -> string_arg(V, <<"dbName">>)
    end,
    case check(call(This, {location, Name})) of
        null -> null;
        File -> js(File)
    end.

%% DatabaseSync::CreateSession: the options first, then the database.
create_session(This, Args) ->
    {Table, Db} = case Args of
        [Options | _] when ?IS_OBJECT(Options) ->
            {own_string(Options, <<"table">>, null), own_string(Options, <<"db">>, <<"main">>)};
        [_ | _] ->
            type_error(<<"The \"options\" argument must be an object.">>);
        [] ->
            {null, <<"main">>}
    end,
    State = open_db(This),
    Table1 = case Table of
        <<>> -> null;
        _ -> Table
    end,
    {ok, Handle} = check(call(This, {session, Db, Table1})),
    Session = buoy_heap:new_object(get_realm({proto, session})),
    buoy_heap:private_put(Session, ?SESSION, #{db => This, handle => Handle, epoch => maps:get(epoch, State)}),
    Session.

own_string(Options, Key, Default) ->
    case buoy_heap:has_own(Options, Key) of
        false -> Default;
        true ->
            case buoy_heap:get(Options, Key) of
                V when ?IS_STRING(V) -> utf8(V);
                _ -> type_error(<<"The \"options.", Key/binary, "\" argument must be a string.">>)
            end
    end.

apply_changeset(This, Args) ->
    open_db(This),
    Changeset = buoy_node:arg(1, Args),
    is_uint8_array(Changeset) orelse type_error(<<"The \"changeset\" argument must be a Uint8Array.">>),
    {Filter, Conflict} = case Args of
        [_, Options | _] when Options =/= undefined -> apply_options(Options);
        _ -> {none, none}
    end,
    Saved = erlang:put(?APPLY, {Filter, Conflict}),
    try
        check(call(This, {apply_changeset, buoy_node_encoding:view_bytes(Changeset), Filter =/= none, Conflict =/= none}))
    after
        restore(?APPLY, Saved)
    end.

apply_options(Options) when ?IS_OBJECT(Options) ->
    Conflict = case buoy_heap:get(Options, <<"onConflict">>) of
        undefined -> none;
        C -> buoy_heap:is_callable(C) orelse type_error(<<"The \"options.onConflict\" argument must be a function.">>), C
    end,
    Filter = case buoy_heap:has_own(Options, <<"filter">>) of
        false -> none;
        true ->
            F = buoy_heap:get(Options, <<"filter">>),
            buoy_heap:is_callable(F) orelse type_error(<<"The \"options.filter\" argument must be a function.">>),
            F
    end,
    {Filter, Conflict};
apply_options(_) ->
    type_error(<<"The \"options\" argument must be an object.">>).

enable_load_extension(This, Args) ->
    State = db_state(This),
    Allow = buoy_node:arg(1, Args),
    is_boolean(Allow) orelse type_error(<<"The \"allow\" argument must be a boolean.">>),
    #{config := #{allow_extension := Allowed}} = State,
    (Allowed =:= false andalso Allow =:= true) andalso
        invalid_state(<<"Cannot enable extension loading because it was disabled at database creation.">>),
    save_db(This, State#{enable_extension => Allow}),
    case maps:get(open, State) of
        true -> check(call(This, {db_config, ?DBCONFIG_ENABLE_LOAD_EXTENSION, flag(Allow, 1)}));
        false -> ok
    end,
    undefined.

enable_defensive(This, Args) ->
    open_db(This),
    Active = buoy_node:arg(1, Args),
    is_boolean(Active) orelse type_error(<<"The \"active\" argument must be a boolean.">>),
    check(call(This, {db_config, ?DBCONFIG_DEFENSIVE, flag(Active, 1)})),
    undefined.

load_extension(This, Args) ->
    State = open_db(This),
    #{config := #{allow_extension := Allowed}, enable_extension := Enabled} = State,
    Allowed orelse invalid_state(<<"extension loading is not allowed">>),
    Enabled orelse invalid_state(<<"extension loading is not allowed">>),
    Path = string_arg(buoy_node:arg(1, Args), <<"path">>),
    Entry = case buoy_node:arg(2, Args) of
        E when ?IS_STRING(E) -> utf8(E);
        E when ?IS_OBJECT(E) ->
            case is_view(E) of
                true -> buoy_node_encoding:view_bytes(E);
                false -> null
            end;
        _ -> null
    end,
    case call(This, {load_extension, Path, Entry}) of
        ok -> undefined;
        {load_error, null} ->
            buoy_node:throw_code('Error', <<"ERR_LOAD_SQLITE_EXTENSION">>, <<"Failed to load SQLite extension">>);
        {load_error, Message} ->
            buoy_node:throw_code('Error', <<"ERR_LOAD_SQLITE_EXTENSION">>, js(Message));
        Other -> check(Other)
    end.

set_authorizer(This, Args) ->
    State = db_state(This),
    case buoy_node:arg(1, Args) of
        null ->
            save_db(This, State#{authorizer => null}),
            maps:get(open, State) andalso check(call(This, {authorizer, false})),
            undefined;
        Fn ->
            buoy_heap:is_callable(Fn) orelse type_error(<<"The \"callback\" argument must be a function or null.">>),
            save_db(This, State#{authorizer => Fn}),
            check(call(This, {authorizer, true})),
            undefined
    end.

%% The limits object: an accessor for each limit, as the named interceptors
%% of DatabaseSyncLimits.
limits(This) ->
    State = db_state(This),
    case maps:get(limits, State) of
        undefined ->
            Limits = buoy_node:object([]),
            [buoy_heap:define(Limits, Name,
                              #{get => buoy_node:fn(Name, 0, fun(_, _) -> limit(This, Id, -1) end),
                                set => buoy_node:fn(Name, 1, fun(_, [V | _]) -> set_limit(This, Id, V);
                                                               (_, []) -> set_limit(This, Id, undefined) end),
                                enumerable => true, configurable => false})
             || {Id, Name} <- lists:enumerate(0, ?LIMIT_NAMES)],
            save_db(This, (db_state(This))#{limits => Limits}),
            Limits;
        Limits ->
            Limits
    end.

limit(This, Id, Value) ->
    open_db(This),
    check(call(This, {limit, Id, Value})).

set_limit(This, Id, Value) ->
    open_db(This),
    Message = <<"Limit value must be a non-negative integer or Infinity.">>,
    New = case Value of
        'Infinity' -> ?INT32_MAX;
        _ when not ?IS_NUMBER(Value) -> type_error(Message);
        _ ->
            is_int32(Value) orelse type_error(Message),
            Value >= 0 orelse out_of_range(<<"Limit value must be non-negative.">>),
            Value
    end,
    _ = check(call(This, {limit, Id, New})),
    undefined.

create_tag_store(This, Args) ->
    open_db(This),
    Capacity = case buoy_node:arg(1, Args) of
        N when ?IS_NUMBER(N) -> to_int32(N);
        _ -> 1000
    end,
    Store = buoy_heap:new_object(tag_store_proto()),
    [buoy_heap:define(Store, Name, #{get => Get, enumerable => true, configurable => false})
     || {Name, Get} <- get_realm(tag_store_getters)],
    buoy_heap:private_put(Store, ?STORE, #{db => This, capacity => Capacity, cache => []}),
    Store.

%% SQLTagStore's prototype, which createTagStore makes once per realm.
tag_store_proto() ->
    case erlang:get({?MODULE, buoy_heap:realm(), tag_store}) of
        undefined ->
            Class = buoy_node:constructor(<<"SQLTagStore">>, 0, fun(_, _) -> illegal_constructor() end),
            Proto = buoy_heap:get(Class, <<"prototype">>),
            methods(Proto, [
                {<<"get">>, fun(This, Args) -> tag(This, Args, get) end},
                {<<"all">>, fun(This, Args) -> tag(This, Args, all) end},
                {<<"iterate">>, fun(This, Args) -> tag(This, Args, iterate) end},
                {<<"run">>, fun(This, Args) -> tag(This, Args, run) end},
                {<<"clear">>, fun(This, _) -> save_store(This, (store_state(This))#{cache => []}), undefined end}]),
            put_realm(tag_store_getters,
                      [{<<"capacity">>, getter(<<"capacity">>, fun(This, _) -> maps:get(capacity, store_state(This)) end)},
                       {<<"db">>, getter(<<"db">>, fun(This, _) -> maps:get(db, store_state(This)) end)},
                       {<<"size">>, getter(<<"size">>, fun(This, _) -> length(maps:get(cache, store_state(This))) end)}]),
            put_realm(tag_store, Proto),
            Proto;
        Proto ->
            Proto
    end.

store_state(This) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?STORE) of
        {ok, State} -> State;
        _ -> illegal_invocation()
    end.

save_store(This, State) -> buoy_heap:private_put(This, ?STORE, State).

%% SQLTagStore::Get, All, Iterate, and Run: the statement of the template from
%% the cache, its parameters bound by position.
tag(This, Args, Kind) ->
    #{db := Db} = store_state(This),
    open_db(Db),
    Statement = tag_statement(This, Args),
    Params = tl(Args),
    Count = length(statement_params(Statement)),
    Values = [{I, bind_value(V, I)} || {I, V} <- lists:enumerate(1, lists:sublist(Params, Count))],
    execute(Statement, Kind, {false, Values}).

tag_statement(This, Args) ->
    Strings = case Args of
        [S | _] when ?IS_OBJECT(S) -> S;
        _ -> type_error(<<"First argument must be an array of strings (template literal).">>)
    end,
    buoy_heap:class_of(Strings) =:= array orelse
        type_error(<<"First argument must be an array of strings (template literal).">>),
    Parts = buoy_heap:array_items(Strings),
    NParams = length(Args) - 1,
    Sql = iolist_to_binary(
        [[case ?IS_STRING(Part) of
              true -> utf8(Part);
              false -> type_error(<<"Template literal parts must be strings.">>)
          end,
          case I < NParams of
              true -> <<"?">>;
              false -> <<>>
          end] || {I, Part} <- lists:enumerate(0, Parts)]),
    State = store_state(This),
    #{db := Db, cache := Cache, capacity := Capacity} = State,
    Cached = case lists:keyfind(Sql, 1, Cache) of
        {Sql, S1} ->
            case is_finalized(stmt_state(S1)) of
                true -> none;
                false -> S1
            end;
        false -> none
    end,
    Statement = case Cached of
        none ->
            Handle = case call(Db, {prepare, Sql}) of
                {ok, H} -> H;
                Failure -> check(Failure)
            end,
            #{config := Config} = db_state(Db),
            new_statement(Db, {ok, Handle}, maps:with([return_arrays, big_ints, bare, unknown], Config));
        S2 -> S2
    end,
    Rest = lists:keydelete(Sql, 1, Cache),
    save_store(This, State#{cache => lists:sublist([{Sql, Statement} | Rest], max(0, Capacity))}),
    Statement.

%%% StatementSync

new_statement(Db, {ok, Handle}, Flags) ->
    Statement = buoy_heap:new_object(get_realm({proto, statement})),
    define_getters(Statement, get_realm(statement_getters)),
    #{epoch := Epoch} = db_state(Db),
    buoy_heap:private_put(Statement, ?STMT,
                          Flags#{db => Db, handle => case Handle of
                                                         empty -> none;
                                                         H -> H
                                                     end,
                                 epoch => Epoch, generation => 0, params => undefined, bare_names => undefined}),
    Statement.

stmt_state(This) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?STMT) of
        {ok, State} -> State;
        _ -> illegal_invocation()
    end.

save_stmt(This, State) -> buoy_heap:private_put(This, ?STMT, State).

is_finalized(#{handle := none}) -> true;
is_finalized(#{db := Db, epoch := Epoch}) -> maps:get(epoch, db_state(Db)) =/= Epoch.

%% A statement that is not finalized.
live_stmt(This) ->
    State = stmt_state(This),
    is_finalized(State) andalso invalid_state(<<"statement has been finalized">>),
    State.

set_flag(This, Args, Flag, Message) ->
    State = live_stmt(This),
    Value = buoy_node:arg(1, Args),
    is_boolean(Value) orelse type_error(Message),
    save_stmt(This, State#{Flag => Value}),
    undefined.

%% ResetStatement and BindParams, then the run of Kind.
statement_all(This, Args) -> statement_execute(This, Args, all).
statement_get(This, Args) -> statement_execute(This, Args, get).
statement_run(This, Args) -> statement_execute(This, Args, run).
statement_iterate(This, Args) -> statement_execute(This, Args, iterate).

statement_execute(This, Args, Kind) ->
    State = live_stmt(This),
    save_stmt(This, State#{generation => maps:get(generation, State) + 1}),
    Binding = {true, bind_params(This, Args)},
    execute(This, Kind, Binding).

execute(This, Kind, Binding) ->
    #{db := Db, handle := Handle} = State = stmt_state(This),
    BigInts = maps:get(big_ints, State),
    case Kind of
        run ->
            {ok, Changes, Last} = check(call(Db, {run, Handle, Binding})),
            Convert = case BigInts of
                true -> fun(I) -> {'$bigint', I} end;
                false -> fun buoy_ref_number:canonical/1
            end,
            buoy_node:object([{<<"changes">>, Convert(Changes)}, {<<"lastInsertRowid">>, Convert(Last)}]);
        get ->
            case check(call(Db, {get, Handle, Binding})) of
                none -> undefined;
                {row, Names, Values} -> row(State, Names, Values)
            end;
        all ->
            {rows, Names, Rows} = check(call(Db, {all, Handle, Binding})),
            Keys = keys(Names),
            buoy_heap:new_array([row_from(State, Keys, Values) || Values <- Rows]);
        iterate ->
            check(call(Db, {iterate, Handle, Binding})),
            iterator(This, State)
    end.

row(State, Names, Values) -> row_from(State, keys(Names), Values).

row_from(State, Keys, Values) ->
    BigInts = maps:get(big_ints, State),
    JsValues = [to_js(V, BigInts) || V <- Values],
    case maps:get(return_arrays, State) of
        true -> buoy_heap:new_array(JsValues);
        false -> buoy_heap:object(null, lists:zip(Keys, JsValues))
    end.

keys(Names) -> [buoy_heap:to_key(js(Name)) || Name <- Names].

%% StatementSync::BindParams: an object of named parameters first, then the
%% anonymous ones in order. Returns [{Index, Value}].
bind_params(This, Args) ->
    Params = statement_params(This),
    {Named, Positional} = case Args of
        [First | Rest] when ?IS_OBJECT(First) ->
            case is_view(First) of
                true -> {[], Args};
                false -> {bind_named(This, First, Params), Rest}
            end;
        _ -> {[], Args}
    end,
    Named ++ bind_anonymous(Positional, Params, 1).

bind_named(This, Object, Params) ->
    State = stmt_state(This),
    Bare = maps:get(bare, State),
    BareNames = case Bare of
        true -> bare_names(This, Params);
        false -> #{}
    end,
    Indexed = maps:from_list(lists:reverse([{Name, I} || {I, Name} <- lists:enumerate(1, Params), Name =/= null])),
    lists:filtermap(
        fun(Key) ->
            KeyText = utf8(buoy_ref:to_string(buoy_heap:key_to_value(Key))),
            Index = case maps:find(KeyText, Indexed) of
                {ok, I} -> I;
                error when Bare ->
                    case maps:find(KeyText, BareNames) of
                        {ok, Full} -> maps:get(Full, Indexed);
                        error -> 0
                    end;
                error -> 0
            end,
            case Index of
                0 ->
                    maps:get(unknown, State) orelse
                        invalid_state(<<"Unknown named parameter '", KeyText/binary, "'">>),
                    false;
                _ ->
                    {true, {Index, bind_value(buoy_heap:get(Object, Key), Index)}}
            end
        end, [K || K <- buoy_heap:enumerable_keys(Object), not is_symbol(K)]).

%% The bare names of the named parameters, which Node makes once.
bare_names(This, Params) ->
    State = stmt_state(This),
    case maps:get(bare_names, State) of
        undefined ->
            Names = lists:foldl(
                fun(null, Acc) -> Acc;
                   (<<_, Bare/binary>> = Full, Acc) ->
                        case maps:find(Bare, Acc) of
                            {ok, Full} -> Acc;
                            {ok, Existing} ->
                                invalid_state(<<"Cannot create bare named parameter '", Bare/binary,
                                                "' because of conflicting names '", Existing/binary, "' and '",
                                                Full/binary, "'.">>);
                            error -> Acc#{Bare => Full}
                        end
                end, #{}, Params),
            save_stmt(This, (stmt_state(This))#{bare_names => Names}),
            Names;
        Names ->
            Names
    end.

bind_anonymous([], _Params, _Index) -> [];
bind_anonymous([Value | Rest], Params, Index) ->
    Anonymous = skip_named(Params, Index),
    [{Anonymous, bind_value(Value, Anonymous)} | bind_anonymous(Rest, Params, Anonymous + 1)].

%% The next index from Index whose parameter is anonymous or beyond the last.
skip_named(Params, Index) when Index > length(Params) -> Index;
skip_named(Params, Index) ->
    case lists:nth(Index, Params) of
        null -> Index;
        <<"?", _/binary>> -> Index;
        _ -> skip_named(Params, Index + 1)
    end.

statement_params(This) ->
    State = stmt_state(This),
    case maps:get(params, State) of
        undefined ->
            #{db := Db, handle := Handle} = State,
            Params = check(call(Db, {params, Handle})),
            save_stmt(This, (stmt_state(This))#{params => Params}),
            Params;
        Params ->
            Params
    end.

%% StatementSync::BindValue.
bind_value(V, _Index) when is_integer(V) -> float(V);
bind_value(V, _Index) when is_float(V) -> V;
bind_value(V, _Index) when V =:= 'NaN'; V =:= 'Infinity'; V =:= '-Infinity' -> V;
bind_value(V, _Index) when ?IS_STRING(V) -> utf8(V);
bind_value(null, _Index) -> null;
bind_value({'$bigint', I}, _Index) when I >= -16#8000000000000000, I =< 16#7FFFFFFFFFFFFFFF -> I;
bind_value({'$bigint', _}, _Index) ->
    buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_VALUE">>, <<"BigInt value is too large to bind.">>);
bind_value(V, Index) ->
    case ?IS_OBJECT(V) andalso is_view(V) of
        true -> {blob, buoy_node_encoding:view_bytes(V)};
        false -> type_error(<<"Provided value cannot be bound to SQLite parameter ", (integer_to_binary(Index))/binary, ".">>)
    end.

columns(This) ->
    #{db := Db, handle := Handle} = live_stmt(This),
    buoy_heap:new_array(
        [buoy_heap:object(null, [{<<"column">>, js_nullable(Column)}, {<<"database">>, js_nullable(Database)},
                                 {<<"name">>, js_nullable(Name)}, {<<"table">>, js_nullable(Table)},
                                 {<<"type">>, js_nullable(Type)}])
         || {Column, Database, Name, Table, Type} <- check(call(Db, {columns, Handle}))]).

source_sql(This) ->
    #{db := Db, handle := Handle} = live_stmt(This),
    js(check(call(Db, {sql, Handle}))).

expanded_sql(This) ->
    #{db := Db, handle := Handle} = live_stmt(This),
    js(check(call(Db, {expanded_sql, Handle}))).

%%% StatementSyncIterator

iterator(Statement, #{generation := Generation}) ->
    Proto = iterator_proto(),
    %% Node sets the prototype of the prototype to Iterator.prototype at each iterate().
    case buoy_heap:get(buoy_ref_realm:global_object(), <<"Iterator">>) of
        Iterator when ?IS_OBJECT(Iterator) ->
            buoy_heap:set_prototype_of(Proto, buoy_heap:get(Iterator, <<"prototype">>));
        _ -> ok
    end,
    Iter = buoy_heap:new_object(Proto),
    buoy_heap:private_put(Iter, ?ITER, #{statement => Statement, generation => Generation, done => false}),
    Iter.

iterator_proto() ->
    case erlang:get({?MODULE, buoy_heap:realm(), iterator}) of
        undefined ->
            Class = buoy_node:constructor(<<"StatementSyncIterator">>, 0, fun(_, _) -> illegal_constructor() end),
            Proto = buoy_heap:get(Class, <<"prototype">>),
            methods(Proto, [{<<"next">>, fun(This, _) -> iterator_next(This) end},
                            {<<"return">>, fun(This, _) -> iterator_return(This) end}]),
            put_realm(iterator, Proto),
            Proto;
        Proto ->
            Proto
    end.

iter_state(This) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?ITER) of
        {ok, State} -> State;
        _ -> illegal_invocation()
    end.

iter_result(Done, Value) -> buoy_heap:object(null, [{<<"done">>, Done}, {<<"value">>, Value}]).

iterator_next(This) ->
    #{statement := Statement, generation := Generation, done := Done} = iter_state(This),
    #{db := Db, handle := Handle} = State = live_stmt(Statement),
    case Done of
        true -> iter_result(true, null);
        false ->
            maps:get(generation, State) =:= Generation orelse invalid_state(<<"iterator was invalidated">>),
            case check(call(Db, {next, Handle})) of
                done -> iter_result(true, null);
                {row, Names, Values} -> iter_result(false, row(State, Names, Values))
            end
    end.

iterator_return(This) ->
    #{statement := Statement} = Iter = iter_state(This),
    #{db := Db, handle := Handle} = live_stmt(Statement),
    check(call(Db, {reset, Handle})),
    buoy_heap:private_put(This, ?ITER, Iter#{done => true}),
    iter_result(true, null).

%%% Session

session_state(This) ->
    case ?IS_OBJECT(This) andalso buoy_heap:private_find(This, ?SESSION) of
        {ok, State} -> State;
        _ -> illegal_invocation()
    end.

%% The handle of a session that is open, on a database that is open.
live_session(This) ->
    #{db := Db, handle := Handle, epoch := Epoch} = session_state(This),
    #{open := Open, epoch := DbEpoch} = db_state(Db),
    Open orelse invalid_state(<<"database is not open">>),
    (Handle =/= none andalso Epoch =:= DbEpoch) orelse invalid_state(<<"session is not open">>),
    {Db, Handle}.

session_changes(This, Patchset) ->
    {Db, Handle} = live_session(This),
    uint8_array(check(call(Db, {changeset, Handle, Patchset}))).

session_close(This) ->
    {Db, Handle} = live_session(This),
    check(call(Db, {delete_session, Handle})),
    buoy_heap:private_put(This, ?SESSION, (session_state(This))#{handle => none}),
    undefined.

%%% backup(sourceDb, path, options)

backup(Args) ->
    Source = buoy_node:arg(1, Args),
    ?IS_OBJECT(Source) orelse type_error(<<"The \"sourceDb\" argument must be an object.">>),
    case buoy_heap:private_find(Source, ?DB) of
        {ok, _} -> backup_database(Source, Args);
        error -> undefined
    end.

backup_database(Source, Args) ->
    open_db(Source),
    Path = database_path(buoy_node:arg(2, Args), <<"path">>),
    {Rate, SourceDb, TargetDb, Progress} = case length(Args) > 2 of
        true -> backup_options(buoy_node:arg(3, Args));
        false -> {100, <<"main">>, <<"main">>, none}
    end,
    Promise = buoy_jobs:new_promise(),
    case call(Source, {backup_init, Path, SourceDb, TargetDb}) of
        Id when is_integer(Id) ->
            backup_step(Source, Id, Rate, Progress, Promise);
        Failure ->
            buoy_jobs:reject_promise(Promise, sqlite_error(Failure))
    end,
    Promise.

backup_options(Options) when ?IS_OBJECT(Options) ->
    Rate = case buoy_heap:get(Options, <<"rate">>) of
        undefined -> 100;
        R -> is_int32(R) orelse type_error(<<"The \"options.rate\" argument must be an integer.">>), R
    end,
    String = fun(Key, Default) ->
        case buoy_heap:get(Options, Key) of
            undefined -> Default;
            V when ?IS_STRING(V) -> utf8(V);
            _ -> type_error(<<"The \"options.", Key/binary, "\" argument must be a string.">>)
        end
    end,
    SourceDb = String(<<"source">>, <<"main">>),
    TargetDb = String(<<"target">>, <<"main">>),
    Progress = case buoy_heap:get(Options, <<"progress">>) of
        undefined -> none;
        P -> buoy_heap:is_callable(P) orelse type_error(<<"The \"options.progress\" argument must be a function.">>), P
    end,
    {Rate, SourceDb, TargetDb, Progress};
backup_options(_) ->
    type_error(<<"The \"options\" argument must be an object.">>).

%% One sqlite3_backup_step in a process of its own, as Node runs it on the
%% thread pool; the realm handles its result in a later macrotask. The realm
%% keeps the database, the progress function, and the promise as roots of its
%% heap meanwhile.
backup_step(Source, Id, Rate, Progress, Promise) ->
    #{conn := Conn} = db_state(Source),
    Realm = self(),
    Key = {?MODULE, backup, make_ref()},
    erlang:put(Key, {Source, Progress, Promise}),
    buoy_node_loop:ref_handle(),
    _ = spawn(fun() ->
        Ref = make_ref(),
        Reply = case buoy_native:sqlite_command(Conn, Ref, {backup_step, Id, Rate}) of
            true -> receive {buoy_sqlite, Ref, R} -> R end;
            false -> gone
        end,
        Realm ! {'$buoy_node_call', fun() ->
            buoy_node_loop:unref_handle(),
            {S, P, Pr} = erlang:erase(Key),
            after_backup_step(S, Id, Rate, P, Pr, Reply)
        end}
    end),
    ok.

%% BackupJob::AfterThreadPoolWork.
after_backup_step(Source, Id, Rate, Progress, Promise, {step, Code, _ErrStr, Remaining, Pages})
  when Code =:= ?SQLITE_OK; Code =:= ?SQLITE_DONE; Code =:= ?SQLITE_BUSY; Code =:= ?SQLITE_LOCKED ->
    case Remaining of
        0 when Code =:= ?SQLITE_DONE ->
            _ = finish_backup(Source, Id),
            buoy_jobs:resolve_promise(Promise, Pages);
        0 ->
            buoy_jobs:reject_promise(Promise, sqlite_error(finish_backup(Source, Id)));
        _ ->
            Continue = case Progress of
                none -> ok;
                _ ->
                    Info = buoy_node:object([{<<"totalPages">>, Pages}, {<<"remainingPages">>, Remaining}]),
                    try buoy_heap:call(Progress, null, [Info]) of
                        _ -> ok
                    catch
                        error:{'$throw', E} -> {error, E}
                    end
            end,
            case Continue of
                ok ->
                    backup_step(Source, Id, Rate, Progress, Promise);
                {error, Error} ->
                    _ = finish_backup(Source, Id),
                    buoy_jobs:reject_promise(Promise, Error)
            end
    end,
    ok;
after_backup_step(Source, Id, _Rate, _Progress, Promise, {step, Code, ErrStr, _, _}) ->
    _ = finish_backup(Source, Id),
    buoy_jobs:reject_promise(Promise, sqlite_error({sqlite_error, Code, ErrStr, ErrStr})),
    ok;
after_backup_step(_Source, _Id, _Rate, _Progress, Promise, _Gone) ->
    buoy_jobs:reject_promise(Promise, error_with_code('Error', <<"ERR_INVALID_STATE">>, <<"database is not open">>)),
    ok.

%% Finishes a backup and closes its destination: the error of the
%% destination before it closed.
finish_backup(Source, Id) ->
    try call(Source, {backup_finish, Id})
    catch error:{'$throw', _} -> gone
    end.

%%% The connection: commands, replies, and the calls of SQLite

%% Sends Command to the connection of Db and waits for the reply, answering
%% each call of SQLite meanwhile. An exception that a call threw is thrown
%% when the command ends.
call(Db, Command) ->
    #{conn := Conn} = db_state(Db),
    Ref = make_ref(),
    Saved = erlang:erase(?PENDING),
    Reply = case buoy_native:sqlite_command(Conn, Ref, Command) of
        true -> await(Db, Conn, Ref);
        false -> gone
    end,
    Pending = erlang:erase(?PENDING),
    restore(?PENDING, Saved),
    case Pending of
        undefined -> Reply;
        {throw, E} -> erlang:error({'$throw', E});
        {raise, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.

%% Sends Command to the connection Conn of a binding that registers no
%% JavaScript call, such as internalBinding('webstorage'), and waits for the
%% reply.
-spec command(buoy_native:sqlite_connection(), atom() | tuple()) -> term().
command(Conn, Command) ->
    Ref = make_ref(),
    case buoy_native:sqlite_command(Conn, Ref, Command) of
        true -> receive {buoy_sqlite, Ref, Reply} -> Reply end;
        false -> gone
    end.

restore(Key, undefined) -> erlang:erase(Key), ok;
restore(Key, Value) -> erlang:put(Key, Value), ok.

await(Db, Conn, Ref) ->
    receive
        {buoy_sqlite, Ref, Reply} ->
            Reply;
        {buoy_sqlite_call, Ref, Call} ->
            _ = buoy_native:sqlite_answer(Conn, answer(Db, Call)),
            await(Db, Conn, Ref)
    end.

%% Runs Fun for a call: an exception becomes the pending one, and the call
%% answers Failed.
guarded(Fun, Failed) ->
    case erlang:get(?PENDING) of
        undefined ->
            try Fun()
            catch
                error:{'$throw', E} -> erlang:put(?PENDING, {throw, E}), Failed;
                Class:Reason:Stack -> erlang:put(?PENDING, {raise, Class, Reason, Stack}), Failed
            end;
        _ ->
            Failed
    end.

answer(_Db, {function, Id, Args}) ->
    guarded(fun() ->
        {Fn, BigInts} = erlang:get({?MODULE, function, Id}),
        result(buoy_heap:call(Fn, undefined, [to_js(A, BigInts) || A <- Args]))
    end, ignore);
answer(_Db, {aggregate, Id, Op, Key, Args}) ->
    aggregate_call(erlang:get({?MODULE, aggregate, Id}), Op, Key, Args);
answer(Db, {authorize, Action, Params}) ->
    guarded(fun() -> authorize(Db, Action, Params) end, ?SQLITE_DENY);
answer(_Db, {filter, Table}) ->
    {Filter, _} = erlang:get(?APPLY),
    guarded(fun() -> buoy_ref:truthy(buoy_heap:call(Filter, null, [js(Table)])) end, false);
answer(_Db, {conflict, Kind}) ->
    {_, Conflict} = erlang:get(?APPLY),
    guarded(fun() ->
        R = buoy_heap:call(Conflict, null, [Kind]),
        case is_int32(R) of
            true -> R;
            false -> -1
        end
    end, ?SQLITE_CHANGESET_ABORT).

%% CustomAggregate: the value of a group lives in the realm, under the key that
%% SQLite keeps in the aggregate context.
aggregate_call(Agg, Op, Key, Args) when Op =:= step; Op =:= inverse ->
    guarded(fun() ->
        Value = group_value(Agg, Key),
        Fn = maps:get(Op, Agg),
        BigInts = maps:get(big_ints, Agg),
        New = buoy_heap:call(Fn, undefined, [Value | [to_js(A, BigInts) || A <- Args]]),
        {_, Window} = erlang:get({?MODULE, group, Key}),
        erlang:put({?MODULE, group, Key}, {New, Window}),
        ok
    end, ignore);
aggregate_call(Agg, value, Key, []) ->
    guarded(fun() ->
        Value = group_value(Agg, Key),
        erlang:put({?MODULE, group, Key}, {Value, true}),
        aggregate_result(Agg, Value)
    end, ignore);
aggregate_call(Agg, final, Key, []) ->
    case erlang:get({?MODULE, group, Key}) of
        {_, true} ->
            erlang:erase({?MODULE, group, Key}),
            none;
        _ ->
            try guarded(fun() -> aggregate_result(Agg, group_value(Agg, Key)) end, ignore)
            after erlang:erase({?MODULE, group, Key})
            end
    end.

group_value(Agg, Key) ->
    case erlang:get({?MODULE, group, Key}) of
        {Value, _} -> Value;
        undefined ->
            Start = maps:get(start, Agg),
            Value = case buoy_heap:is_callable(Start) of
                true -> buoy_heap:call(Start, null, []);
                false -> Start
            end,
            erlang:put({?MODULE, group, Key}, {Value, false}),
            Value
    end.

aggregate_result(Agg, Value) ->
    case maps:get(result, Agg) of
        none -> result(Value);
        Fn -> result(buoy_heap:call(Fn, null, [Value]))
    end.

%% DatabaseSync::AuthorizerCallback.
authorize(Db, Action, Params) ->
    #{authorizer := Fn} = db_state(Db),
    R = buoy_heap:call(Fn, undefined, [Action | [js_nullable(P) || P <- Params]]),
    is_int32(R) orelse
        erlang:error({'$throw', buoy_heap:error_object('TypeError',
                                                       <<"Authorizer callback must return an integer authorization code">>,
                                                       <<"TypeError: Authorizer callback must return an integer authorization code">>)}),
    lists:member(R, [?SQLITE_OK, ?SQLITE_DENY, ?SQLITE_IGNORE]) orelse
        erlang:error({'$throw', buoy_heap:error_object('RangeError',
                                                       <<"Authorizer callback returned a invalid authorization code">>,
                                                       <<"RangeError: Authorizer callback returned a invalid authorization code">>)}),
    R.

%% JSValueToSQLiteResult.
result(V) when V =:= null; V =:= undefined -> {value, null};
result(V) when ?IS_NUMBER(V) -> {value, bind_value(V, 0)};
result(V) when ?IS_STRING(V) -> {value, utf8(V)};
result({'$bigint', I}) when I >= -16#8000000000000000, I =< 16#7FFFFFFFFFFFFFFF -> {value, I};
result({'$bigint', _}) -> {error, <<"BigInt value is too large for SQLite">>};
result(V) when ?IS_OBJECT(V) ->
    case is_view(V) of
        true -> {value, {blob, buoy_node_encoding:view_bytes(V)}};
        false ->
            case buoy_heap:class_of(V) of
                promise -> {error, <<"Asynchronous user-defined functions are not supported">>};
                _ -> {error, <<"Returned JavaScript value cannot be converted to a SQLite value">>}
            end
    end;
result(_) -> {error, <<"Returned JavaScript value cannot be converted to a SQLite value">>}.

%% SQLITE_VALUE_TO_JS.
to_js(null, _) -> null;
to_js(I, true) when is_integer(I) -> {'$bigint', I};
to_js(I, false) when is_integer(I), abs(I) =< ?MAX_SAFE -> I;
to_js(I, false) when is_integer(I) ->
    out_of_range(<<"Value is too large to be represented as a JavaScript number: ", (integer_to_binary(I))/binary>>);
to_js(F, _) when is_float(F) -> buoy_ref_number:canonical(F);
to_js(A, _) when A =:= 'NaN'; A =:= 'Infinity'; A =:= '-Infinity' -> A;
to_js(B, _) when is_binary(B) -> js(B);
to_js({blob, B}, _) -> uint8_array(B).

%% A reply, or the error that it names.
check({sqlite_error, _, _, _} = Failure) -> throw_sqlite(Failure);
check({sqlite_code, _, _} = Failure) -> throw_sqlite(Failure);
check({sqlite_message, _} = Failure) -> throw_sqlite(Failure);
check(finalized) -> invalid_state(<<"statement has been finalized">>);
check(not_open) -> invalid_state(<<"database is not open">>);
check(gone) -> invalid_state(<<"database is not open">>);
check(busy) -> invalid_state(<<"database is busy">>);
check(Reply) -> Reply.

-spec throw_sqlite(tuple()) -> no_return().
throw_sqlite(Failure) -> erlang:error({'$throw', sqlite_error(Failure)}).

%% CreateSQLiteError: an Error with the code ERR_SQLITE_ERROR, and the
%% errcode and errstr of SQLite.
sqlite_error({sqlite_error, Code, Message, ErrStr}) ->
    E = error_with_code('Error', <<"ERR_SQLITE_ERROR">>, js(Message)),
    set(E, <<"errcode">>, Code),
    set(E, <<"errstr">>, js(ErrStr)),
    E;
sqlite_error({sqlite_code, Code, ErrStr}) ->
    E = error_with_code('Error', <<"ERR_SQLITE_ERROR">>, js(ErrStr)),
    set(E, <<"errcode">>, Code),
    E;
sqlite_error({sqlite_message, Message}) ->
    error_with_code('Error', <<"ERR_SQLITE_ERROR">>, js(Message));
sqlite_error(_) ->
    error_with_code('Error', <<"ERR_INVALID_STATE">>, <<"database is not open">>).

error_with_code(Name, Code, Message) ->
    E = buoy_heap:error_object(Name, Message, buoy_ref_string:concat([atom_to_binary(Name), <<": ">>, Message])),
    set(E, <<"code">>, Code),
    E.

set(O, Key, Value) ->
    buoy_heap:define(O, Key, #{value => Value, writable => true, enumerable => true, configurable => true}).

%%% Values

is_int32(V) -> is_integer(V) andalso V >= -2147483648 andalso V =< ?INT32_MAX.

to_int32(V) -> buoy_ref_number:to_int32(buoy_ref:to_number(V)).

is_view(V) -> lists:member(buoy_heap:class_of(V), [typed_array, data_view]).

is_uint8_array(V) ->
    ?IS_OBJECT(V) andalso buoy_heap:class_of(V) =:= typed_array andalso element(1, buoy_heap:slots(V)) =:= uint8.

is_symbol({'$sym', _, _}) -> true;
is_symbol(_) -> false.

string_arg(V, _Name) when ?IS_STRING(V) -> utf8(V);
string_arg(_, Name) -> type_error(<<"The \"", Name/binary, "\" argument must be a string.">>).

uint8_array(Bytes) ->
    View = buoy_node:typed_array(<<"Uint8Array">>, byte_size(Bytes)),
    buoy_node_encoding:view_write(View, 0, Bytes),
    View.

utf8(S) -> buoy_ref_string:to_utf8(S).

js(Bytes) -> buoy_ref_string:from_utf8(Bytes).

js_nullable(null) -> null;
js_nullable(Bytes) -> js(Bytes).

%%% Errors

-spec type_error(binary()) -> no_return().
type_error(Message) -> buoy_node:throw_code('TypeError', <<"ERR_INVALID_ARG_TYPE">>, js(Message)).

-spec invalid_state(binary()) -> no_return().
invalid_state(Message) -> buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>, js(Message)).

-spec out_of_range(binary()) -> no_return().
out_of_range(Message) -> buoy_node:throw_code('RangeError', <<"ERR_OUT_OF_RANGE">>, js(Message)).

-spec illegal_invocation() -> no_return().
illegal_invocation() -> buoy_ref:type_error(<<"Illegal invocation">>).

-spec illegal_constructor() -> no_return().
illegal_constructor() -> buoy_node:throw_code('Error', <<"ERR_ILLEGAL_CONSTRUCTOR">>, <<"Illegal constructor">>).

-spec construct_call_required() -> no_return().
construct_call_required() ->
    buoy_node:throw_code('TypeError', <<"ERR_CONSTRUCT_CALL_REQUIRED">>, <<"Cannot call constructor without `new`">>).
