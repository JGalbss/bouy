%% internalBinding('permission') (src/permission/permission.cc). The
%% permission model is off, so every scope is granted.
-module(bouy_binding_permission).

-export([binding/0]).

-spec binding() -> term().
binding() -> bouy_node:object([{<<"has">>, bouy_node:fn(<<"has">>, 2, fun(_, _) -> true end)}]).
