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
%%% eSockd Listener Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_listener_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-export([start_link/4, connection_sup/1, acceptor_sup/1]).

-export([init/1]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start Listener Supervisor
-spec start_link(Protocol, ListenOn, Options, MFArgs) -> {ok, pid()} when
    Protocol  :: atom(),
    ListenOn  :: esockd:listen_on(),
    Options   :: [esockd:option()],
    MFArgs    :: esockd:mfargs().
start_link(Protocol, ListenOn, Options, MFArgs) ->
    Logger = logger(Options),
    %% 启动supervisor的时候可以是三个参数第一个是supervisor的注册名，第二个是module，第三个是参数，
    %% 这里使用的是两个参数，没有supervisor的注册名，这样supervisor就不会被注册, 在observer中显示的就只有Pid。
    %% 什么时候会使用不注册supervisor名字呢？ 如果supervisor是动态产生的时候就不必注册名字了，当然也可以选择一个名字注册。
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    %% 0) Sup下面的三类子进程的启动顺序有讲究，他是按使用顺序相反启动的，因为启动listener，就会监听，端口的信息需要acceptor处理，
    %%    所以acceptor要在listener先启动等待使用，connection_sup也是一样的。
    %% 1) connect_sup为什么启动的是gen_server类型的。
    %% 原因是他的子进程是动态通过proc_lib:spawn_link在emqttd_client.erl中启动的，不好设置子进程规范，
    %% 但是又要实现supervisor的功能，所以在使用spawn_link把子进程和supervisor 链接起来，同时要让supervisor(connection_sup)捕捉EXIT
    %% 消息，于是在启动connection_sup的时候设置了process_flag(trap_exit, true), 这样connection_sup接受到子进程发送的exit退出消息的时候
    %% 会自动转化为{'EXIT', FromPid, Reason}的无害信号，否则没有trap_exit的设置，父进程也会跟着子进程挂掉。
    %% 2) 在参数中带了MFArgs参数，这个是用来启动connection_sup下的子进程的, 注意MFArgs是在这个启动connection_sup的时候放在connection_sup
    %% 的状态#state里面的。
    {ok, ConnSup} = supervisor:start_child(Sup,
                                           {connection_sup,
                                            {esockd_connection_sup, start_link, [Options, MFArgs, Logger]},
                                            transient, infinity, supervisor, [esockd_connection_sup]}),
    %% AcceptStatsFun是干什么的?
    %% AcceptStatsFun执行该函数会让esockd_server进程新建一个ets的统计表，统计各类连接的状况，返回一个增减状态量的函数。
    %% BufferTuneFun执行该函数可以更改Sock的buffer大小。
    AcceptStatsFun = esockd_server:stats_fun({Protocol, ListenOn}, accepted),
    BufferTuneFun = buffer_tune_fun(proplists:get_value(buffer, Options),
                                    proplists:get_value(tune_buffer, Options, false)),
    %% 1) 为什么下下面启动的时候都会带上上一次启动的ConnSup和AcceptorSup?
    %% 因为子进程规范里面的第一个元素ConnSup就是上面启动的connection_sup进程, 放在这里是因为在acceptor接受到连接请求之
    %% 后会调用ConnSup进程，让ConnSup进程来启动ClientPid， 同理，启动listener的之后，会让AcceptorSup启动几个Acceptor
    %% 来处理连接。
    {ok, AcceptorSup} = supervisor:start_child(Sup,
                                               {acceptor_sup,
                                                {esockd_acceptor_sup, start_link, [ConnSup, AcceptStatsFun, BufferTuneFun, Logger]},
                                                transient, infinity, supervisor, [esockd_acceptor_sup]}),
    %% 这里的参数也带了AcceptorSup, 作用是来让他动态启动acceptor。
    {ok, _Listener} = supervisor:start_child(Sup,
                                             {listener,
                                              {esockd_listener, start_link, [Protocol, ListenOn, Options, AcceptorSup, Logger]},
                                              transient, 16#ffffffff, worker, [esockd_listener]}),
    %% 总结一些上面的启动顺序：connection_sup --> acceptor_sup --> listener --->+
    %%                         |(#state{mfa})          |                        |
    %%                         |                       +<--call acceptor_sup----+
    %%                         |                       |
    %%               ClientPid <--call connection_sup--+acceptor
    {ok, Sup}.

%% @doc Get connection supervisor.
connection_sup(Sup) ->
    child_pid(Sup, connection_sup).

%% @doc Get acceptor supervisor.
acceptor_sup(Sup) ->
    child_pid(Sup, acceptor_sup).

%% @doc Get child pid with id.
%% @private
child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _} <- supervisor:which_children(Sup), Id =:= ChildId]).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {{rest_for_one, 10, 100}, []}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

%% when 'buffer' is undefined, and 'tune_buffer' is true...
buffer_tune_fun(undefined, true) ->
    fun(Sock) ->
        case inet:getopts(Sock, [sndbuf, recbuf, buffer]) of
            {ok, BufSizes} ->
                BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
                inet:setopts(Sock, [{buffer, BufSz}]);
            Error ->
                Error
        end
    end;

buffer_tune_fun(_, _) ->
    fun(_Sock) -> ok end.

logger(Options) ->
    {ok, Default} = application:get_env(esockd, logger),
    gen_logger:new(proplists:get_value(logger, Options, Default)).
