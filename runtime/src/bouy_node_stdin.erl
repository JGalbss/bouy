%% The standard input of the VM as bytes. The VM starts with -noinput, so OTP's
%% terminal driver reads no input; a process of the VM owns a port on fd 0
%% instead, and read/1 takes up to Count bytes, waiting for them as a read(2)
%% of fd 0 would.
-module(bouy_node_stdin).

-export([read/1, read_async/2]).

%% Up to Count bytes of stdin, or <<>> at its end.
-spec read(non_neg_integer()) -> binary().
read(Count) ->
    Reader = reader(),
    Ref = erlang:monitor(process, Reader),
    Reader ! {read, self(), Ref, Count},
    receive
        {Ref, Bytes} -> erlang:demonitor(Ref, [flush]), Bytes;
        {'DOWN', Ref, process, _, _} -> <<>>
    end.

%% Up to Count bytes of stdin, without waiting: Done(Bytes) runs in the realm
%% as a callback of the loop once they come, as libuv completes a read.
-spec read_async(non_neg_integer(), fun((binary()) -> term())) -> ok.
read_async(Count, Done) ->
    bouy_node_loop:ref_handle(),
    reader() ! {read_async, self(), Count, Done},
    ok.

reader() ->
    case whereis(?MODULE) of
        undefined ->
            Pid = spawn(fun start/0),
            try register(?MODULE, Pid) of
                true -> Pid ! go, Pid
            catch error:badarg ->
                exit(Pid, kill),
                whereis(?MODULE)
            end;
        Pid ->
            Pid
    end.

start() ->
    receive go -> ok end,
    Port = open_port({fd, 0, 0}, [in, binary, stream, eof]),
    loop(Port, <<>>, open).

%% Buffer holds bytes that no read took yet; State is open or eof.
loop(Port, Buffer, State) ->
    receive
        {Port, {data, Data}} ->
            loop(Port, <<Buffer/binary, Data/binary>>, State);
        {Port, eof} ->
            loop(Port, Buffer, eof);
        {read, From, Ref, Count} when Buffer =/= <<>> ->
            Take = min(Count, byte_size(Buffer)),
            <<Bytes:Take/binary, Rest/binary>> = Buffer,
            From ! {Ref, Bytes},
            loop(Port, Rest, State);
        {read, From, Ref, _Count} when State =:= eof ->
            From ! {Ref, <<>>},
            loop(Port, Buffer, State);
        {read_async, Realm, Count, Done} when Buffer =/= <<>>; State =:= eof ->
            Take = min(Count, byte_size(Buffer)),
            <<Bytes:Take/binary, Rest/binary>> = Buffer,
            Realm ! {'$bouy_node_call', fun() -> bouy_node_loop:unref_handle(), Done(Bytes) end},
            loop(Port, Rest, State)
    end.
