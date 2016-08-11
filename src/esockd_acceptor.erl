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
%%% eSockd TCP/SSL Socket Acceptor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_acceptor).

-author("Feng Lee <feng@emqtt.io>").

-include("../include/esockd.hrl").

-behaviour(gen_server).

-export([start_link/6]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {lsock       :: inet:socket(),
                sockfun     :: esockd:sock_fun(),
                tunefun     :: esockd:tune_fun(),
                sockname    :: iolist(),
                conn_sup    :: pid(),
                statsfun    :: fun(),
                logger      :: gen_logger:logmod(),
                ref         :: reference(),
                emfile_count = 0}).

%% @doc Start Acceptor
-spec(start_link(ConnSup, AcceptStatsFun, BufferTuneFun, Logger, LSock, SockFun) -> {ok, pid()} | {error, any()} when
      ConnSup        :: pid(),
      AcceptStatsFun :: fun(),
      BufferTuneFun  :: esockd:tune_fun(),
      Logger         :: gen_logger:logmod(),
      LSock          :: inet:socket(),
      SockFun        :: esockd:sock_fun()).
start_link(ConnSup, AcceptStatsFun, BufTuneFun, Logger, LSock, SockFun) ->
    gen_server:start_link(?MODULE, {ConnSup, AcceptStatsFun, BufTuneFun, Logger, LSock, SockFun}, []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------
%% conglistener4: 由于生成accept是一个耗时操作，所以通过gen_server:cast发送出去，让耗时操作在handle_cast中去执行.
%% 这个操作类似在init返回中加入第三个参数0，立刻发送一个timeout的带外消息，把费时操作放到handle_info(timeout,..)
%% 中去执行是一样的原理.
init({ConnSup, AcceptStatsFun, BufferTuneFun, Logger, LSock, SockFun}) ->
    %% 解析出socket的ip和port.
    {ok, SockName} = inet:sockname(LSock),
    %% 向自己发送一个accept的异步信息(调用prim_inet:async_accept异步accept), 然后执行后面的步骤返回.
    %% 至此，acceptor就启动完成了, 启动emqttd之后，会启动多个acceptor来接收端口来的消息, 同时esockd_listener的
    %% 工作也完成了, 接下来端口如果有消息到的话，就会有handle_info({})来处理.
    %% accept(State)调用prim_inet:async_accept(LSock,-1)这个过程其实就相当于这个acceptor进程(emqttd是设置了启动多个)
    %% 去从监听socket(LSock)那里抢客户端连接一样(众多的acceptor去从端口抢)。
    gen_server:cast(self(), accept),
    {ok, #state{lsock    = LSock,
                sockfun  = SockFun,
                tunefun  = BufferTuneFun,
                sockname = esockd_net:format(sockname, SockName),
                conn_sup = ConnSup,
                statsfun = AcceptStatsFun,
                logger   = Logger}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(accept, State) ->
    accept(State);

handle_cast(_Msg, State) ->
    {noreply, State}.

%% conglistener5: accept到客户端的socket连接, 然后启动一个esockd_connection子进程(受监督于esockd_connnection_sup)，
%% 最后会把这个socket的控制权从acceptor转走，这样这个acceptor就腾出来处理其他的客户端连接了.
handle_info({inet_async, LSock, Ref, {ok, Sock}}, State = #state{lsock    = LSock,
                                                                 sockfun  = SockFun,
                                                                 tunefun  = BufferTuneFun,
                                                                 sockname = SockName,
                                                                 conn_sup = ConnSup,
                                                                 statsfun = AcceptStatsFun,
                                                                 logger   = Logger,
                                                                 ref      = Ref}) ->

    %% patch up the socket so it looks like one we got from gen_tcp:accept/1
    %% 修补socket，使其看起来像是从gen_tcp:accept/1得到的一样.
    {ok, Mod} = inet_db:lookup_socket(LSock),   % {ok, inet_tcp}
    inet_db:register_socket(Sock, Mod),

    %% accepted stats.
    %% AcceptStatsFun is esockd_server:stats_fun({Protocol, ListenOn}, accepted), 统计socket数量+1
    AcceptStatsFun({inc, 1}),

    %% Fix issues#9: enotconn error occured...
    %% {ok, Peername} = inet:peername(Sock),
    %% Logger:info("~s - Accept from ~s", [SockName, esockd_net:format(peername, Peername)]),
    case BufferTuneFun(Sock) of                 % 调整客户端socket的buffer大小.
        ok ->
            %% conglistener6: 该acceptor抢到连接之后，启动一个esockd_connection进程，把socket控制权交给它,
            %% acceptor完成之后就去从端口抢.
            %% 注意，esockd_connection_sup:start_connection启动connection是使用同步启动的，也就是一定要得到
            %% 启动的结果成功与否才会返回. 如果启动失败就把相应的Sock关闭.
            %% jump.....
            %% TODO: Mod=inet_tcp,
            %% Sock 是连接socket
            %% SockFun处理ssl相关信息。
            case esockd_connection_sup:start_connection(ConnSup, Mod, Sock, SockFun) of
                {ok, _Pid}        -> ok;
                {error, enotconn} -> catch port_close(Sock); %% quiet...issue #10
                {error, Reason}   -> catch port_close(Sock),
                                     Logger:error("Failed to start connection on ~s - ~p", [SockName, Reason])
            end;
        {error, enotconn} ->
            catch port_close(Sock);
        {error, Err} ->
            Logger:error("failed to tune buffer size of connection accepted on ~s - ~s", [SockName, Err]),
            catch port_close(Sock)
    end,
    %% accept more
    %% 这个进程抢到了一个客户端的连接，启动一个connection，交给它处理，然后又去LSock哪里抢了, acceptor负责的其实
    %% 就是从LSock抢过来启动一个connection，把控制权交给它就完成任务了。
    accept(State);

%% TODO: Ref是干什么用的？
handle_info({inet_async, LSock, Ref, {error, closed}},
            State=#state{lsock=LSock, ref=Ref}) ->
    %% It would be wrong to attempt to restart the acceptor when we
    %% know this will fail.
    {stop, normal, State};

%% {error, econnaborted} -> accept
handle_info({inet_async, LSock, Ref, {error, econnaborted}},
            State=#state{lsock = LSock, ref = Ref}) ->
    accept(State);

%% {error, esslaccept} -> accept
handle_info({inet_async, LSock, Ref, {error, esslaccept}},
            State=#state{lsock = LSock, ref = Ref}) ->
    accept(State);

%% async accept errors...
%% {error, timeout} ->
%% {error, e{n,m}file} -> suspend 100??
handle_info({inet_async, LSock, Ref, {error, Error}},
            State=#state{lsock = LSock, ref = Ref}) ->
    sockerr(Error, State);

handle_info(resume, State) ->
    accept(State);

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% accept...
%%--------------------------------------------------------------------

accept(State = #state{lsock = LSock}) ->
    %% 这里使用异步accept，如果使用gen_tcp:accept则是阻塞，会在sock哪里等待消息，如果没有消息就汇等待，
    %% 不得到消息就不返回，这样性能就查了。
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {noreply, State#state{ref = Ref}};
        {error, Error} ->
            sockerr(Error, State)
    end.

%%--------------------------------------------------------------------
%% error happened...
%%--------------------------------------------------------------------
%% emfile: The per-process limit of open file descriptors has been reached.
sockerr(emfile, State = #state{sockname = SockName, emfile_count = Count, logger = Logger}) ->
    %%avoid too many error log.. stupid??
    case Count rem 100 of
        0 -> Logger:error("acceptor on ~s suspend 100(ms) for ~p emfile errors!!!", [SockName, Count]);
        _ -> ignore
    end,
    suspend(100, State#state{emfile_count = Count+1});

%% enfile: The system limit on the total number of open files has been reached. usually OS's limit.
sockerr(enfile, State = #state{sockname = SockName, logger = Logger}) ->
    Logger:error("accept error on ~s - !!!enfile!!!", [SockName]),
    suspend(100, State);

sockerr(Error, State = #state{sockname = SockName, logger = Logger}) ->
    Logger:error("accept error on ~s - ~s", [SockName, Error]),
    {stop, {accept_error, Error}, State}.

%%--------------------------------------------------------------------
%% suspend for a while...
%%--------------------------------------------------------------------
suspend(Time, State) ->
    erlang:send_after(Time, self(), resume),
    {noreply, State#state{ref=undefined}, hibernate}.
