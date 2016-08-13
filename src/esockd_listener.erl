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
%%% eSockd Listener.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_listener).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {protocol  :: atom(),
                listen_on :: esockd:listen_on(),
                lsock     :: inet:socket(),
                logger    :: gen_logger:logmod()}).

-define(ACCEPTOR_POOL, 16).

%% @doc Start Listener
-spec start_link(Protocol, ListenOn, Options, AcceptorSup, Logger) -> {ok, pid()} | {error, any()} | ignore when
    Protocol    :: atom(),
    ListenOn    :: esockd:listen_on(),
    Options     :: [esockd:option()],
    AcceptorSup :: pid(),
    Logger      :: gen_logger:logmod().
start_link(Protocol, ListenOn, Options, AcceptorSup, Logger) ->
    gen_server:start_link(?MODULE, {Protocol, ListenOn, Options, AcceptorSup, Logger}, []).
%% conglistener0: 现在开始启动listener
init({Protocol, ListenOn, Options, AcceptorSup, Logger}) ->
    Port = port(ListenOn),
    %% 为什么这里也要设置trap_exit?
    %% observer中看到该进程link了两个东西，一个是其父进程即listener_sup, 另一个是端口#Port<0.xxxx>
    %% 父进程和listener有监督关系，而本进程不是监督进程，Port出问题会到时该进程挂掉，添加这个标志，端口的信号也会发送到这里来，
    %% 并转化为无害消息被捕捉到, 这样，这个进程就不会被终止了。
    %% TODO: 但是为什么不让它终止，有父进程再启动他呢？
    process_flag(trap_exit, true),
    %%Don't active the socket...
    %% 设置端口的配置。
    %% {reuseaddr,true}表示多个实例可重用一个端口(比如关闭emqttd，端口会进入四次断开的流程，这个端口可能会稍晚一会才
    %% 关闭(socket状态会变为TIME_WAIT, 此时没有完全关闭)，如果此时重启emqttd，该参数若为false，就会提示端口被占用).
    %% 如果被设置为true，则当linux内核返回TIME_WAIT的时候就可以复用监听.
    SockOpts = merge_addr(ListenOn, proplists:get_value(sockopts, Options, [{reuseaddr, true}])),
    %% 注意这里使用的是{active, false}, 也不是{active,once}.
    %% {active,false}将socket设置为被动接收，这样不会出现大量连接一下子压过来，服务器处理速度分不上的情况.
    %% conglistener1: 设置好socket的配置，esockd_transport:listen调用gen_tcp:listen(Port, SockOpts)监听端口.
    case esockd_transport:listen(Port, [{active, false} | proplists:delete(active, SockOpts)]) of
        %% 返回监听Socket，这个socket是不能断开的，断开客户端就无法连接了。
        {ok, LSock} ->
            %% 带上ssl证书和秘钥,将tcp升级为ssl(如果ssl有配置).
            SockFun = esockd_transport:ssl_upgrade_fun(proplists:get_value(ssl, Options)),
            %% acceptor_pool有emqttdlistener中配置.
            AcceptorNum = proplists:get_value(acceptors, Options, ?ACCEPTOR_POOL),
            %% conglistener2 依次启动acceptors，受监督于esockd_acceptor_sup,
            %% (注意携带了两个参数，一个是LSock, 另一个是SockFun) jump...
            lists:foreach(fun (_) ->
                                  {ok, _APid} = esockd_acceptor_sup:start_acceptor(AcceptorSup, LSock, SockFun)
                          end, lists:seq(1, AcceptorNum)),
            {ok, {LIPAddress, LPort}} = inet:sockname(LSock),
            io:format("~s listen on ~s:~p with ~p acceptors.~n",
                      [Protocol, esockd_net:ntoab(LIPAddress), LPort, AcceptorNum]),
            {ok, #state{protocol = Protocol, listen_on = ListenOn, lsock = LSock, logger = Logger}};
        {error, Reason} ->
            Logger:error("~s failed to listen on ~p - ~p (~s)~n",
                         [Protocol, Port, Reason, inet:format_error(Reason)]),
            {stop, {cannot_listen, Port, Reason}}
    end.

port(Port) when is_integer(Port) -> Port;
port({_Addr, Port}) -> Port.

merge_addr(Port, SockOpts) when is_integer(Port) ->
    SockOpts;
merge_addr({Addr, _Port}, SockOpts) ->
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{protocol = Protocol, listen_on = ListenOn, lsock = LSock}) ->
    {ok, {IPAddress, Port}} = esockd_transport:sockname(LSock),
    esockd_transport:close(LSock),
    %% Print on console
    io:format("stopped ~s on ~s:~p~n",
              [Protocol, esockd_net:ntoab(IPAddress), Port]),
    %%TODO: depend on esockd_server?
    esockd_server:del_stats({Protocol, ListenOn}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
