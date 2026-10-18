%% internalBinding('permission') (src/permission/permission.cc). The
%% permission model is off, so every scope is granted.
-module(buoy_binding_permission).

-export([binding/0]).

-spec binding() -> term().
binding() -> buoy_node:object([{<<"has">>, buoy_node:fn(<<"has">>, 2, fun(_, _) -> true end)}]).
