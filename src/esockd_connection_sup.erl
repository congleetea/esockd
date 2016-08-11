%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% eSockd connection supervisor. As you know, I love process dictionary...
%%% Notice: Some code is copied from OTP supervisor.erl.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_connection_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_server).

%% API Exports
-export([start_link/3, start_connection/4, count_connections/1]).

%% Max Clients
-export([get_max_clients/1, set_max_clients/2]).

%% Shutdown Count
-export([get_shutdown_count/1]).

%% Allow, Deny
-export([access_rules/1, allow/2, deny/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DICT, dict).
-define(SETS, sets).
-define(MAX_CLIENTS, 1024).

-record(state, {curr_clients = 0,
                max_clients  = ?MAX_CLIENTS,
                conn_opts    = [],
                access_rules = [],
                shutdown     = brutal_kill,
                mfargs,
                logger}).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start connection supervisor.
%% 为什么这个supervisor是gen_server启动的?
-spec start_link(Options, MFArgs, Logger) -> {ok, pid()} | ignore | {error, any()} when
    Options :: [esockd:option()],
    MFArgs  :: esockd:mfargs(),
    Logger  :: gen_logger:logmod().
start_link(Options, MFArgs, Logger) ->
    gen_server:start_link(?MODULE, [Options, MFArgs, Logger], []).

%% @doc Start connection.
%% conglistener7: 同步创建一个esockd_connection，esockd_acceptor会等待启动成功与否的结果.
%% jump to handle_call
start_connection(Sup, Mod, Sock, SockFun) ->
    lager:info("~n~p:~p:self()=~p~n", [?MODULE, ?LINE, self()]), % 这个Pid应该是acceptor的Pid.
    case call(Sup, {start_connection, Sock, SockFun}) of
        {ok, Pid, Conn} ->
            lager:info("~n~p:~p:Pid=~p~n", [?MODULE, ?LINE, Pid]), % 这个Pid才是connection的Pid.
            %% conglistener10: esockd_connection启动成功之后，这里会把客户端的socket的控制权转交给esockd_connection
            % transfer controlling from acceptor to connection
            Mod:controlling_process(Sock, Pid),
            %% conglistener11: 通过go函数给Pid(客户端产生的connection)发送go信号, connection(emqttd_client)收到这个信号接着往下走。
            %% 到此acceptor就彻底把该Sock的控制权交给connection了。
            Conn:go(Pid),
            {ok, Pid};
        {error, Error} ->
            {error, Error}
    end.

count_connections(Sup) ->
    call(Sup, count_connections).

get_max_clients(Sup) when is_pid(Sup) ->
    call(Sup, get_max_clients).

set_max_clients(Sup, MaxClients) when is_pid(Sup) ->
    call(Sup, {set_max_clients, MaxClients}).

get_shutdown_count(Sup) ->
    call(Sup, get_shutdown_count).

access_rules(Sup) ->
    call(Sup, access_rules).

allow(Sup, CIDR) ->
    call(Sup, {add_rule, {allow, CIDR}}).

deny(Sup, CIDR) ->
    call(Sup, {add_rule, {deny, CIDR}}).

call(Sup, Req) ->
    gen_server:call(Sup, Req, infinity).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([Options, MFArgs, Logger]) ->
    %% 由于这里不是通过supervisor启动的子进程，如果没有下面trap_exit的设置，那么和本进程(connection_sup) link的进程一旦退出，
    %% 他就不能捕捉这个退出消息，也就不能做特殊的处理，他也会紧随子进程而终止，为防止被终止，设置这个标志，这样connection_sup
    %% 接受到的消息就会转化为{'EXIT', FromPid, Reason}这种无害消息，避免被终止，其实就是自定义了一个supervisor的行为模式。
    %% 同时， connection_sup的子进程一旦终止，是不需要重新启动的。
    %% 我们同时也看到，他的子进程connection是在emqttd_client.erl中通过proc_lib:spawn_link启动的, 这样启动之后会自动和本进程link起来。
    erlang:process_flag(trap_exit, true),
    %% Options从emqttd的listener配置中得到.
    Shutdown    = proplists:get_value(shutdown, Options, brutal_kill),
    MaxClients  = proplists:get_value(max_clients, Options, ?MAX_CLIENTS),
    ConnOpts    = proplists:get_value(connopts, Options, []),
    lager:error("~n~p:~p:ConnOpts=~p~n", [?MODULE, ?LINE, ConnOpts]),
    RawRules    = proplists:get_value(access, Options, [{allow, all}]),
    AccessRules = [esockd_access:compile(Rule) || Rule <- RawRules],
    {ok, #state{max_clients  = MaxClients,
                conn_opts    = ConnOpts,
                access_rules = AccessRules,
                shutdown     = Shutdown,
                mfargs       = MFArgs,
                logger       = Logger}}.

%% conglistener8: 在这里限制连接的最大个数。如果超过了就拒绝连接。
handle_call({start_connection, _Sock, _SockFun}, _From,
            State = #state{curr_clients = CurrClients, max_clients = MaxClients})
        when CurrClients >= MaxClients ->
    {reply, {error, maxlimit}, State};

handle_call({start_connection, Sock, SockFun}, _From,
            State = #state{conn_opts = ConnOpts, mfargs = MFArgs,
                           curr_clients = Count, access_rules = Rules}) ->
    case inet:peername(Sock) of
        {ok, {Addr, _Port}} ->
            %% 检验相应的IP是否有权限
            case allowed(Addr, Rules) of
                true ->
                    %% new返回{esockd_connection, [Sock, SockFun, parse_opt(Opts)]}一个带状态的模块.
                    Conn = esockd_connection:new(Sock, SockFun, ConnOpts),
                    %% 实际调用的是esockd_connection:start_link(MFArgs, {esockd_connection,[Sock,SockFun,NewOpts]})
                    %% for mqtt(s):{emqttd_client,start_link, Opts}
                    %% for http(s):{mochiweb_http,start_link,[{emqttd_http,handle_request,[]}]}
                    case catch Conn:start_link(MFArgs) of
                        {ok, Pid} when is_pid(Pid) ->
                            put(Pid, true),
                            {reply, {ok, Pid, Conn}, State#state{curr_clients = Count+1}};
                        ignore ->
                            {reply, ignore, State};
                        {error, Reason} ->
                            {reply, {error, Reason}, State};
                        What ->
                            {reply, {error, What}, State}
                    end;
                false ->
                    {reply, {error, forbidden}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(count_connections, _From, State = #state{curr_clients = Count}) ->
    {reply, Count, State};

handle_call(get_max_clients, _From, State = #state{max_clients = MaxClients}) ->
    {reply, MaxClients, State};

handle_call({set_max_clients, MaxClients}, _From, State) ->
    {reply, ok, State#state{max_clients = MaxClients}};

handle_call(get_shutdown_count, _From, State) ->
    {reply, [{Reason, Count} || {{shutdown, Reason}, Count} <- get()], State};

handle_call(access_rules, _From, State = #state{access_rules = Rules}) ->
    {reply, [raw(Rule) || Rule <- Rules], State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    case catch esockd_access:compile(RawRule) of
        {'EXIT', _Error} ->
            {reply, {error, bad_access_rule}, State};
        Rule ->
            case lists:member(Rule, Rules) of
                true ->
                    {reply, {error, alread_existed}, State};
                false ->
                    {reply, ok, State#state{access_rules = [Rule | Rules]}}
            end
    end;

handle_call(_Req, _From, State) ->
    {stop, {error, badreq}, State}.

handle_cast(Msg, State = #state{logger = Logger}) ->
    Logger:error("Bad MSG: ~p", [Msg]),
    {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State = #state{curr_clients = Count, logger = Logger}) ->
    case erase(Pid) of
        true ->
            connection_crashed(Pid, Reason, State),
            {noreply, State#state{curr_clients = Count-1}};
        undefined ->
            Logger:error("'EXIT' from unkown ~p: ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(Info, State = #state{logger = Logger}) ->
    Logger:error("Bad INFO: ~p", [Info]),
    {noreply, State}.

-spec terminate(Reason, State) -> any() when
    Reason  :: normal | shutdown | {shutdown, term()} | term(),
    State   :: #state{}.
terminate(_Reason, State) ->
    terminate_children(State).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

allowed(Addr, Rules) ->
    case esockd_access:match(Addr, Rules) of
        nomatch          -> true;
        {matched, allow} -> true;
        {matched, deny}  -> false
    end.

raw({allow, CIDR = {_Start, _End, _Len}}) ->
     {allow, esockd_cidr:to_string(CIDR)};
raw({deny, CIDR = {_Start, _End, _Len}}) ->
     {deny, esockd_cidr:to_string(CIDR)};
raw(Rule) ->
     Rule.

connection_crashed(_Pid, normal, _State) ->
    ok;
connection_crashed(_Pid, shutdown, _State) ->
    ok;
connection_crashed(_Pid, {shutdown, Reason}, _State) when is_atom(Reason) ->
    count_shutdown(Reason);
connection_crashed(Pid, {shutdown, Reason}, State) ->
    report_error(connection_shutdown, Reason, Pid, State);
connection_crashed(Pid, Reason, State) ->
    report_error(connection_crashed, Reason, Pid, State).

count_shutdown(Reason) ->
    case get({shutdown, Reason}) of
        undefined ->
            put({shutdown, Reason}, 1);
        Count     ->
            put({shutdown, Reason}, Count+1)
    end.

terminate_children(State = #state{shutdown = Shutdown}) ->
    {Pids, EStack0} = monitor_children(),
    Sz = ?SETS:size(Pids),
    EStack = case Shutdown of
                 brutal_kill ->
                     ?SETS:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 infinity ->
                     ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     wait_children(Shutdown, Pids, Sz, undefined, EStack0);
                 Time when is_integer(Time) ->
                     ?SETS:fold(fun(P, _) -> exit(P, shutdown) end, ok, Pids),
                     TRef = erlang:start_timer(Time, self(), kill),
                     wait_children(Shutdown, Pids, Sz, TRef, EStack0)
             end,
    %% Unroll stacked errors and report them
    ?DICT:fold(fun(Reason, Pid, _) ->
        report_error(connection_shutdown_error, Reason, Pid, State)
    end, ok, EStack).

monitor_children() ->
    lists:foldl(fun(P, {Pids, EStack}) ->
        case monitor_child(P) of
            ok ->
                {?SETS:add_element(P, Pids), EStack};
            {error, normal} ->
                {Pids, EStack};
            {error, Reason} ->
                {Pids, ?DICT:append(Reason, P, EStack)}
        end
    end, {?SETS:new(), ?DICT:new()}, get_keys(true)).

%% Help function to shutdown/2 switches from link to monitor approach
monitor_child(Pid) ->
    %% Do the monitor operation first so that if the child dies
    %% before the monitoring is done causing a 'DOWN'-message with
    %% reason noproc, we will get the real reason in the 'EXIT'-message
    %% unless a naughty child has already done unlink...
    erlang:monitor(process, Pid),
    unlink(Pid),

    receive
        %% If the child dies before the unlik we must empty
        %% the mail-box of the 'EXIT'-message and the 'DOWN'-message.
        {'EXIT', Pid, Reason} ->
            receive
                {'DOWN', _, process, Pid, _} ->
                    {error, Reason}
            end
    after 0 ->
            %% If a naughty child did unlink and the child dies before
            %% monitor the result will be that shutdown/2 receives a
            %% 'DOWN'-message with reason noproc.
            %% If the child should die after the unlink there
            %% will be a 'DOWN'-message with a correct reason
            %% that will be handled in shutdown/2.
            ok
    end.

wait_children(_Shutdown, _Pids, 0, undefined, EStack) ->
    EStack;
wait_children(_Shutdown, _Pids, 0, TRef, EStack) ->
    %% If the timer has expired before its cancellation, we must empty the
    %% mail-box of the 'timeout'-message.
    erlang:cancel_timer(TRef),
    receive
        {timeout, TRef, kill} ->
            EStack
    after 0 ->
            EStack
    end;

%%TODO: copied from supervisor.erl, rewrite it later.
wait_children(brutal_kill, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, killed} ->
            wait_children(brutal_kill, del(Pid, Pids), Sz-1, TRef, EStack);

        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(brutal_kill, del(Pid, Pids),
                          Sz-1, TRef, ?DICT:append(Reason, Pid, EStack))
    end;

wait_children(Shutdown, Pids, Sz, TRef, EStack) ->
    receive
        {'DOWN', _MRef, process, Pid, shutdown} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, normal} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1, TRef, EStack);
        {'DOWN', _MRef, process, Pid, Reason} ->
            wait_children(Shutdown, del(Pid, Pids), Sz-1,
                          TRef, ?DICT:append(Reason, Pid, EStack));
        {timeout, TRef, kill} ->
            ?SETS:fold(fun(P, _) -> exit(P, kill) end, ok, Pids),
            wait_children(Shutdown, Pids, Sz-1, undefined, EStack)
    end.

report_error(Error, Reason, Pid, #state{mfargs = MFArgs}) ->
    SupName  = list_to_atom("esockd_connection_sup - " ++ pid_to_list(self())),
    ErrorMsg = [{supervisor, SupName},
                {errorContext, Error},
                {reason, Reason},
                {offender, [{pid, Pid},
                            {name, connection},
                            {mfargs, MFArgs}]}],
    error_logger:error_report(supervisor_report, ErrorMsg).

del(Pid, Pids) ->
    erase(Pid), ?SETS:del_element(Pid, Pids).
