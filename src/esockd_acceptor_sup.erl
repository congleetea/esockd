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
%%% eSockd TCP/SSL Acceptor Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_acceptor_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-export([start_link/4, start_acceptor/3, count_acceptors/1]).

-export([init/1]).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec(start_link(ConnSup, AcceptStatsFun, BufferTuneFun, Logger) -> {ok, pid()} when
      ConnSup        :: pid(),
      AcceptStatsFun :: fun(),
      BufferTuneFun  :: esockd:tune_fun(),
      Logger         :: gen_logger:logmod()).
start_link(ConnSup, AcceptStatsFun, BufferTuneFun, Logger) ->
    supervisor:start_link(?MODULE, [ConnSup, AcceptStatsFun, BufferTuneFun, Logger]).

%% @doc Start a acceptor.
-spec(start_acceptor(AcceptorSup, LSock, SockFun) -> {ok, pid()} | {error, any()} | ignore when
      AcceptorSup :: pid(),
      LSock       :: inet:socket(),
      SockFun     :: esockd:sock_fun()).
start_acceptor(AcceptorSup, LSock, SockFun) ->
    %% conglistener3: 这里携带了两个参数, 根据init中的ChildSpec启动, 两边的参数会合并。
    %% 这里在init中有4个参数，本初有带了2个参数，合并之后就是6个参数，jump to esockd_acceptor:start_link/6
    supervisor:start_child(AcceptorSup, [LSock, SockFun]).

%% @doc Count Acceptors.
-spec count_acceptors(AcceptorSup :: pid()) -> pos_integer().
count_acceptors(AcceptorSup) ->
    length(supervisor:which_children(AcceptorSup)).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------
%% simple_one_for_one类型的supervisor，在启动supervisor的时候不会启动子进程。
init([ConnSup, AcceptStatsFun, BufferTuneFun, Logger]) ->
    {ok, {{simple_one_for_one, 1000, 3600},
          [{acceptor, {esockd_acceptor, start_link, [ConnSup, AcceptStatsFun, BufferTuneFun, Logger]},
            transient, 5000, worker, [esockd_acceptor]}]}}.
