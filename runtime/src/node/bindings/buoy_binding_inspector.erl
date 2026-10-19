%% internalBinding('inspector') (src/inspector_js_api.cc): V8's console and
%% consoleCall, which Node's internal/util/inspector wraps into the global
%% console. With no inspector session, V8's console methods report to nobody,
%% so each returns undefined, and consoleCall calls only the method of Node.
%% The other members of the binding stay stubs (buoy_node:complete/2), and
%% config.hasInspector stays false.
-module(buoy_binding_inspector).

-export([binding/0]).

%% The members of V8's console object, in V8's order.
-define(METHODS, [<<"debug">>, <<"error">>, <<"info">>, <<"log">>, <<"warn">>, <<"dir">>, <<"dirxml">>,
                  <<"table">>, <<"trace">>, <<"group">>, <<"groupCollapsed">>, <<"groupEnd">>, <<"clear">>,
                  <<"count">>, <<"countReset">>, <<"assert">>, <<"profile">>, <<"profileEnd">>, <<"time">>,
                  <<"timeLog">>, <<"timeEnd">>, <<"timeStamp">>]).

-spec binding() -> term().
binding() ->
    F = fun buoy_node:fn/3,
    Console = buoy_node:object([{Name, silent(Name)} || Name <- ?METHODS]
        ++ [{<<"context">>, F(<<"context">>, 1, fun(_, _) -> context() end)},
            {<<"createTask">>, F(<<"createTask">>, 0, fun(_, Args) -> create_task(buoy_node:arg(1, Args)) end)}]),
    buoy_node:object([
        {<<"console">>, Console},
        %% consoleCall(inspectorMethod, nodeMethod, ...args), bound to Node's
        %% console: the inspector method runs only while a session listens.
        {<<"consoleCall">>, F(<<"consoleCall">>, 0, fun(This, Args) ->
            buoy_node:call(buoy_node:arg(2, Args), This, lists:nthtail(min(2, length(Args)), Args))
        end)}
    ]).

silent(Name) -> buoy_node:fn(Name, 0, fun(_, _) -> undefined end).

%% console.context(): a console of its own, as silent as V8's console.
context() ->
    Names = [<<"dir">>, <<"dirXml">>, <<"table">>, <<"groupEnd">>, <<"clear">>, <<"count">>, <<"countReset">>,
             <<"profile">>, <<"profileEnd">>, <<"debug">>, <<"error">>, <<"info">>, <<"log">>, <<"warn">>,
             <<"trace">>, <<"group">>, <<"groupCollapsed">>, <<"assert">>, <<"time">>, <<"timeLog">>,
             <<"timeEnd">>, <<"timeStamp">>],
    buoy_heap:object(null, [{Name, buoy_node:fn(Name, 1, fun(_, _) -> undefined end)} || Name <- Names]).

%% console.createTask(name): a task whose run(f) calls f, as V8 does with no
%% async stack tagging listener.
create_task(Name) ->
    case buoy_ref:typeof(Name) =:= <<"string">> andalso buoy_ref_string:to_utf8(Name) =/= <<>> of
        true -> ok;
        false -> buoy_heap:throw_error('Error', <<"First argument must be a non-empty string.">>)
    end,
    buoy_node:object([{<<"run">>, buoy_node:fn(<<"run">>, 0, fun(_, Args) ->
        Callback = buoy_node:arg(1, Args),
        case buoy_heap:is_callable(Callback) of
            true -> buoy_node:call(Callback, undefined, []);
            false -> buoy_heap:throw_error('Error', <<"First argument must be a function.">>)
        end
    end)}]).
