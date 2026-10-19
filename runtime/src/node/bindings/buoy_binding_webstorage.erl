%% internalBinding('webstorage') (src/node_webstorage.cc): Storage, the class of
%% localStorage and sessionStorage, on a SQLite database of buoy_native.
%%
%% Node gives a Storage named and indexed property interceptors. Buoy makes
%% each Storage a proxy whose traps run the same interceptors: a property that
%% the prototype does not have reads, writes, and deletes an item. The keys and
%% the values are UTF-16LE blobs, as Node stores them, so a file of Node's
%% --localstorage-file opens in Buoy.
-module(buoy_binding_webstorage).

-include("buoy_ref.hrl").

-export([binding/0]).

%% The constructor of Storage only throws.
-dialyzer({no_return, [binding/0]}).

-define(IN_MEMORY, <<":memory:">>).
-define(SQLITE_CONSTRAINT, 19).
-define(SCHEMA_VERSION, 1).

-define(INIT_SQL, <<
    "PRAGMA encoding = 'UTF-16le';"
    "PRAGMA busy_timeout = 3000;"
    "PRAGMA journal_mode = WAL;"
    "PRAGMA synchronous = NORMAL;"
    "PRAGMA temp_store = memory;"
    "PRAGMA optimize;"
    "CREATE TABLE IF NOT EXISTS nodejs_webstorage("
    "  key BLOB NOT NULL,"
    "  value BLOB NOT NULL,"
    "  PRIMARY KEY(key)"
    ") STRICT;"
    "CREATE TABLE IF NOT EXISTS nodejs_webstorage_state("
    "  max_size INTEGER NOT NULL DEFAULT 10485760,"
    "  total_size INTEGER NOT NULL,"
    "  schema_version INTEGER NOT NULL DEFAULT 0,"
    "  single_row_ INTEGER NOT NULL DEFAULT 1 CHECK(single_row_ = 1),"
    "  PRIMARY KEY(single_row_)"
    ") STRICT;"
    "CREATE TRIGGER IF NOT EXISTS nodejs_quota_insert "
    "AFTER INSERT ON nodejs_webstorage "
    "FOR EACH ROW "
    "BEGIN "
    "  UPDATE nodejs_webstorage_state"
    "    SET total_size = total_size + OCTET_LENGTH(NEW.key) +"
    "      OCTET_LENGTH(NEW.value);"
    "  SELECT RAISE(ABORT, 'QuotaExceeded') WHERE EXISTS ("
    "    SELECT 1 FROM nodejs_webstorage_state WHERE total_size > max_size"
    "  );"
    "END;"
    "CREATE TRIGGER IF NOT EXISTS nodejs_quota_update "
    "AFTER UPDATE ON nodejs_webstorage "
    "FOR EACH ROW "
    "BEGIN "
    "  UPDATE nodejs_webstorage_state"
    "    SET total_size = total_size + "
    "      ((OCTET_LENGTH(NEW.key) + OCTET_LENGTH(NEW.value)) -"
    "      (OCTET_LENGTH(OLD.key) + OCTET_LENGTH(OLD.value)));"
    "  SELECT RAISE(ABORT, 'QuotaExceeded') WHERE EXISTS ("
    "    SELECT 1 FROM nodejs_webstorage_state WHERE total_size > max_size"
    "  );"
    "END;"
    "CREATE TRIGGER IF NOT EXISTS nodejs_quota_delete "
    "AFTER DELETE ON nodejs_webstorage "
    "FOR EACH ROW "
    "BEGIN "
    "  UPDATE nodejs_webstorage_state"
    "    SET total_size = total_size - (OCTET_LENGTH(OLD.key) +"
    "      OCTET_LENGTH(OLD.value));"
    "END;"
    "INSERT OR IGNORE INTO nodejs_webstorage_state (total_size) VALUES (0);">>).

-spec binding() -> term().
binding() ->
    Key = buoy_heap:symbol(<<"constructor_key_symbol">>),
    Proto = buoy_node:object([]),
    Storage = buoy_heap:function(fun(_, _) -> illegal_constructor() end, <<"Storage">>, 0,
                                 #{construct => fun(NewTarget, Args) -> construct(Key, NewTarget, Proto, Args) end}),
    buoy_heap:define(Proto, <<"constructor">>, #{value => Storage, writable => true, enumerable => false, configurable => true}),
    buoy_heap:define(Storage, <<"prototype">>, #{value => Proto, writable => false, enumerable => false, configurable => false}),
    buoy_heap:define(Proto, <<"length">>,
                     #{get => buoy_node:fn(<<"length">>, 0, fun(This, _) -> length_of(storage(This)) end),
                       enumerable => true, configurable => false}),
    [buoy_heap:define(Proto, Name, #{value => buoy_node:fn(Name, 0, Fun), writable => true,
                                     enumerable => false, configurable => true})
     || {Name, Fun} <- [{<<"clear">>, fun(This, _) -> clear(storage(This)), undefined end},
                        {<<"getItem">>, fun get_item/2},
                        {<<"key">>, fun key/2},
                        {<<"removeItem">>, fun remove_item/2},
                        {<<"setItem">>, fun set_item/2}]],
    Binding = buoy_node:object([{<<"Storage">>, Storage}]),
    buoy_heap:define(Binding, <<"kConstructorKey">>, #{value => Key, writable => false, enumerable => true, configurable => true}),
    Binding.

%% Storage::New: only the binding's key constructs one.
construct(Key, NewTarget, Fallback, Args) ->
    buoy_node:arg(1, Args) =:= Key orelse illegal_constructor(),
    Location = buoy_ref_string:to_utf8(buoy_node:arg(2, Args)),
    Proto = case buoy_heap:get(NewTarget, <<"prototype">>) of
        P when ?IS_OBJECT(P) -> P;
        _ -> Fallback
    end,
    Target = buoy_heap:new_object(Proto),
    Storage = buoy_heap:proxy(Target, handler(Proto)),
    %% A storage lives as long as the realm, as localStorage and sessionStorage do.
    erlang:put({?MODULE, Storage}, #{location => Location, conn => none, symbols => #{}}),
    erlang:put({?MODULE, target, Target}, Storage),
    Storage.

storage(This) ->
    case erlang:get({?MODULE, This}) of
        undefined -> buoy_ref:type_error(<<"Illegal invocation">>);
        _ -> This
    end.

state(Storage) -> erlang:get({?MODULE, Storage}).

save(Storage, State) -> erlang:put({?MODULE, Storage}, State).

%%% The interceptors

handler(Proto) ->
    F = fun buoy_node:fn/3,
    buoy_node:object([
        {<<"get">>, F(<<"get">>, 3, fun(_, [Target, Prop, Receiver | _]) ->
            case intercepts(Proto, Prop) of
                false -> buoy_heap:get(Target, buoy_heap:to_key(Prop), Receiver);
                true ->
                    case load(storage_of(Target), Prop) of
                        null -> undefined;
                        V -> V
                    end
            end
        end)},
        {<<"set">>, F(<<"set">>, 4, fun(_, [Target, Prop, Value | _]) ->
            store(storage_of(Target), Prop, Value),
            true
        end)},
        {<<"has">>, F(<<"has">>, 2, fun(_, [Target, Prop | _]) ->
            intercepts(Proto, Prop) andalso load(storage_of(Target), Prop) =/= null
                orelse buoy_heap:has(Target, buoy_heap:to_key(Prop))
        end)},
        {<<"deleteProperty">>, F(<<"deleteProperty">>, 2, fun(_, [Target, Prop | _]) ->
            remove(storage_of(Target), Prop),
            true
        end)},
        {<<"ownKeys">>, F(<<"ownKeys">>, 1, fun(_, [Target | _]) ->
            buoy_heap:new_array(enumerate(storage_of(Target)))
        end)},
        {<<"getOwnPropertyDescriptor">>, F(<<"getOwnPropertyDescriptor">>, 2, fun(_, [Target, Prop | _]) ->
            case intercepts(Proto, Prop) andalso load(storage_of(Target), Prop) of
                V when V =:= false; V =:= null -> undefined;
                V -> buoy_node:object([{<<"value">>, V}, {<<"writable">>, true}, {<<"enumerable">>, true},
                                       {<<"configurable">>, true}])
            end
        end)},
        {<<"defineProperty">>, F(<<"defineProperty">>, 3, fun(_, [Target, Prop, Descriptor | _]) ->
            case buoy_heap:has(Descriptor, <<"value">>) of
                true -> store(storage_of(Target), Prop, buoy_heap:get(Descriptor, <<"value">>));
                false -> ok
            end,
            true
        end)}]).

%% ShouldIntercept: a property that the prototype has keeps its own meaning.
intercepts(Proto, Prop) -> not buoy_heap:has(Proto, buoy_heap:to_key(Prop)).

%% The storage whose proxy has Target.
storage_of(Target) -> erlang:get({?MODULE, target, Target}).

%%% The methods

get_item(This, Args) ->
    Storage = storage(This),
    Args =/= [] orelse missing_args(<<"Failed to execute 'getItem' on 'Storage': 1 argument required">>),
    load(Storage, buoy_ref:to_string(hd(Args))).

key(This, Args) ->
    Storage = storage(This),
    Args =/= [] orelse missing_args(<<"Failed to execute 'key' on 'Storage': 1 argument required">>),
    case buoy_ref_number:to_int32(buoy_ref:to_number(hd(Args))) of
        Index when Index < 0 -> null;
        Index ->
            case query(Storage, <<"SELECT key FROM nodejs_webstorage LIMIT 1 OFFSET ?">>, [{1, Index}]) of
                none -> null;
                [{blob, Key}] -> from_utf16(Key)
            end
    end.

remove_item(This, Args) ->
    Storage = storage(This),
    Args =/= [] orelse missing_args(<<"Failed to execute 'removeItem' on 'Storage': 1 argument required">>),
    remove(Storage, buoy_ref:to_string(hd(Args))),
    undefined.

set_item(This, Args) ->
    Storage = storage(This),
    length(Args) >= 2 orelse missing_args(<<"Failed to execute 'setItem' on 'Storage': 2 arguments required">>),
    [Key, Value | _] = Args,
    store(Storage, buoy_ref:to_string(Key), Value),
    undefined.

%%% Storage::Load, Store, Remove, Enumerate, Length, and Clear

load(Storage, {'$sym', _, _} = Symbol) ->
    maps:get(Symbol, maps:get(symbols, state(Storage)), undefined);
load(Storage, Key) ->
    case query(Storage, <<"SELECT value FROM nodejs_webstorage WHERE key = ? LIMIT 1">>,
               [{1, {blob, to_utf16(Key)}}]) of
        none -> null;
        [{blob, Value}] -> from_utf16(Value)
    end.

store(Storage, {'$sym', _, _} = Symbol, Value) ->
    #{symbols := Symbols} = State = state(Storage),
    save(Storage, State#{symbols => Symbols#{Symbol => Value}});
store(Storage, Key, Value) ->
    Text = buoy_ref:to_string(Value),
    Sql = <<"INSERT INTO nodejs_webstorage (key, value) VALUES (?, ?)"
            "  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value"
            "  WHERE EXCLUDED.key = key">>,
    case run(Storage, Sql, [{1, {blob, to_utf16(buoy_ref:to_string(Key))}}, {2, {blob, to_utf16(Text)}}]) of
        {sqlite_error, Code, _, _} when Code band 16#FF =:= ?SQLITE_CONSTRAINT ->
            DOMException = buoy_heap:get(buoy_node:context(), <<"DOMException">>),
            erlang:error({'$throw', buoy_heap:construct(DOMException,
                                                        [<<"Setting the value exceeded the quota">>,
                                                         <<"QuotaExceededError">>], DOMException)});
        Reply ->
            checked(Reply)
    end.

remove(Storage, {'$sym', _, _} = Symbol) ->
    #{symbols := Symbols} = State = state(Storage),
    save(Storage, State#{symbols => maps:remove(Symbol, Symbols)});
remove(Storage, Key) ->
    checked(run(Storage, <<"DELETE FROM nodejs_webstorage WHERE key = ?">>,
                [{1, {blob, to_utf16(buoy_ref:to_string(Key))}}])).

enumerate(Storage) ->
    {rows, _, Rows} = checked(command(Storage, all, <<"SELECT key FROM nodejs_webstorage">>, [])),
    [from_utf16(Key) || [{blob, Key}] <- Rows].

length_of(Storage) ->
    [Count] = query(Storage, <<"SELECT count(*) FROM nodejs_webstorage">>, []),
    Count.

clear(Storage) ->
    checked(run(Storage, <<"DELETE FROM nodejs_webstorage">>, [])).

%%% The database

%% Storage::Open: the database opens at its first use, so a storage that a
%% program never uses leaves no file.
conn(Storage) ->
    case state(Storage) of
        #{conn := none, location := Location} = State ->
            Conn = buoy_native:sqlite_connection(),
            Call = fun(Command) -> checked(buoy_binding_sqlite:command(Conn, Command)) end,
            case buoy_binding_sqlite:command(Conn, {open, Location, false, false, true, false, 0, [], false}) of
                ok -> ok;
                {failed, _, Failure} -> checked(Failure)
            end,
            Call({exec, ?INIT_SQL}),
            Call({exec, ?INIT_SQL}),
            {ok, Version} = Call({prepare, <<"SELECT schema_version FROM nodejs_webstorage_state">>}),
            {row, _, [Schema]} = Call({get, Version, {true, []}}),
            Schema > ?SCHEMA_VERSION andalso
                buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>,
                                     <<"localStorage was created with a newer version of Node.js">>),
            Schema < ?SCHEMA_VERSION andalso
                Call({exec, <<"UPDATE nodejs_webstorage_state SET schema_version = ",
                              (integer_to_binary(?SCHEMA_VERSION))/binary, ";">>}),
            save(Storage, State#{conn => Conn, statements => #{}}),
            %% ~Storage closes the database when the environment ends, which checkpoints
            %% the WAL and removes its -wal and -shm files.
            buoy_node_loop:add_cleanup_hook(fun() -> buoy_binding_sqlite:command(Conn, close) end),
            Conn;
        #{conn := Conn} ->
            Conn
    end.

%% The statement of Sql, prepared once for the storage.
statement(Storage, Sql) ->
    Conn = conn(Storage),
    #{statements := Statements} = State = state(Storage),
    case Statements of
        #{Sql := Statement} -> {Conn, Statement};
        _ ->
            {ok, Statement} = checked(buoy_binding_sqlite:command(Conn, {prepare, Sql})),
            save(Storage, State#{statements => Statements#{Sql => Statement}}),
            {Conn, Statement}
    end.

command(Storage, Kind, Sql, Values) ->
    {Conn, Statement} = statement(Storage, Sql),
    buoy_binding_sqlite:command(Conn, {Kind, Statement, {true, Values}}).

run(Storage, Sql, Values) -> command(Storage, run, Sql, Values).

%% The values of the first row, or none.
query(Storage, Sql, Values) ->
    case checked(command(Storage, get, Sql, Values)) of
        none -> none;
        {row, _, Row} -> Row
    end.

%% THROW_SQLITE_ERROR: ERR_INVALID_STATE with the text of the code.
checked({sqlite_error, _, _, ErrStr}) ->
    buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>, buoy_ref_string:from_utf8(ErrStr));
checked(Reply) when is_atom(Reply), Reply =/= ok, Reply =/= none ->
    buoy_node:throw_code('Error', <<"ERR_INVALID_STATE">>, <<"database is not open">>);
checked(Reply) ->
    Reply.

%%% Values

to_utf16(String) -> << <<U:16/little>> || U <- buoy_ref_string:units(String) >>.

from_utf16(Bytes) -> buoy_ref_string:from_units([U || <<U:16/little>> <= Bytes]).

-spec illegal_constructor() -> no_return().
illegal_constructor() -> buoy_node:throw_code('Error', <<"ERR_ILLEGAL_CONSTRUCTOR">>, <<"Illegal constructor">>).

-spec missing_args(binary()) -> no_return().
missing_args(Message) -> buoy_node:throw_code('TypeError', <<"ERR_MISSING_ARGS">>, Message).
