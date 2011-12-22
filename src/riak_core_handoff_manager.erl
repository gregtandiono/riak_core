%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
-module(riak_core_handoff_manager).
-behaviour(gen_server).

%% gen_server api
-export([start_link/0,
         init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% exclusion api
-export([add_exclusion/2,
         get_exclusions/1,
         remove_exclusion/2
        ]).

%% handoff api
-export([add_outbound/4,
         add_inbound/1,
         handoff_status/0,
         set_concurrency/1,
         kill_handoffs/0
        ]).

-include_lib("riak_core/include/riak_core_handoff.hrl").
-include_lib("eunit/include/eunit.hrl").

-type mod()   :: atom().
-type index() :: integer().
-type node_() :: atom().

-record(handoff_status,
        { handoff       :: {mod(),index(),node_()},
          direction     :: inbound | outbound,
          transport_pid :: pid(),
          timestamp     :: tuple(),
          status        :: any(),
          vnode_pid     :: pid() | undefined
        }).

-record(state,
        { excl,
          handoffs :: [#handoff_status{}]
        }).

%% this can be overridden with riak_core handoff_concurrency
-define(HANDOFF_CONCURRENCY,1).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{excl=ordsets:new(), handoffs=[]}}.

%% handoff_manager API

add_outbound(Module,Idx,Node,VnodePid) ->
    gen_server:call(?MODULE,{add_outbound,Module,Idx,Node,VnodePid}).

add_inbound(SSLOpts) ->
    gen_server:call(?MODULE,{add_inbound,SSLOpts}).

handoff_status() ->
    gen_server:call(?MODULE,handoff_status).

set_concurrency(Limit) ->
    gen_server:call(?MODULE,{set_concurrency,Limit}).

kill_handoffs() ->
    set_concurrency(0).

add_exclusion(Module, Index) ->
    gen_server:cast(?MODULE, {add_exclusion, {Module, Index}}).

remove_exclusion(Module, Index) ->
    gen_server:cast(?MODULE, {del_exclusion, {Module, Index}}).

get_exclusions(Module) ->
    gen_server:call(?MODULE, {get_exclusions, Module}, infinity).

%% gen_server API

handle_call({get_exclusions, Module}, _From, State=#state{excl=Excl}) ->
    Reply =  [I || {M, I} <- ordsets:to_list(Excl), M =:= Module],
    {reply, {ok, Reply}, State};
handle_call({add_outbound,Mod,Idx,Node,Pid},_From,State=#state{handoffs=HS}) ->
    case send_handoff(Mod,Idx,Node,Pid) of
        {ok,Handoff=#handoff_status{transport_pid=Sender}} ->
            {reply,{ok,Sender},State#state{handoffs=HS ++ [Handoff]}};
        Error ->
            {reply,Error,State}
    end;
handle_call({add_inbound,SSLOpts},_From,State=#state{handoffs=HS}) ->
    case receive_handoff(SSLOpts) of
        {ok,Handoff=#handoff_status{transport_pid=Receiver}} ->
            {reply,{ok,Receiver},State#state{handoffs=HS ++ [Handoff]}};
        Error ->
            {reply,Error,State}
    end;
handle_call(handoff_status,_From,State=#state{handoffs=HS}) ->
    Handoffs=[{H,D,active,S} || #handoff_status{ handoff=H,direction=D,status=S } <- HS],
    {reply, {ok, Handoffs}, State};
handle_call({set_concurrency,Limit},_From,State=#state{handoffs=HS}) ->
    application:set_env(riak_core,handoff_concurrency,Limit),
    case Limit < erlang:length(HS) of
        true ->
            %% Note: we don't update the state with the handoffs that we're
            %% keeping because we'll still get the 'DOWN' messages with
            %% a reason of 'max_concurrency' and we want to be able to do
            %% something with that if necessary.
            {_Keep,Discard}=lists:split(Limit,HS),
            [erlang:exit(Pid,max_concurrency) ||
                #handoff_status{transport_pid=Pid} <- Discard],
            {reply, ok, State};
        false ->
            {reply, ok, State}
    end.


handle_cast({del_exclusion, {Mod, Idx}}, State=#state{excl=Excl}) ->
    {noreply, State#state{excl=ordsets:del_element({Mod, Idx}, Excl)}};
handle_cast({add_exclusion, {Mod, Idx}}, State=#state{excl=Excl}) ->
    {ok, Ring} = riak_core_ring_manager:get_raw_ring(),
    riak_core_ring_events:ring_update(Ring),
    {noreply, State#state{excl=ordsets:add_element({Mod, Idx}, Excl)}}.


handle_info({'DOWN',_Ref,process,Pid,Reason},State=#state{handoffs=HS}) ->
    case lists:keytake(Pid,#handoff_status.transport_pid,HS) of
        {value,H=#handoff_status{handoff={Mod,Index,_},direction=Dir},NewHS} ->
            if
                %% if the reason the handoff process died was anything other
                %% than 'normal' we should log the reason why as an error
                Reason =/= normal ->
                    lager:error("An ~w handoff of partition ~w ~w was terminated for reason: ~w~n", [Dir,Mod,Index,Reason]);
                true ->
                    ok
            end,

            %% if we have the vnode process pid, tell the vnode why the
            %% handoff stopped so it can clean up its state
            case H#handoff_status.vnode_pid of
                VnodePid when is_pid(VnodePid) ->
                    VnodePid ! {handoff_exit,Reason};
                _ ->
                    ok
            end,

            %% removed the handoff from the list of active handoffs
            {noreply, State#state{handoffs=NewHS}};
        false ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% @private functions
%%

get_concurrency_limit () ->
    app_helper:get_env(riak_core,handoff_concurrency,?HANDOFF_CONCURRENCY).

%% true if handoff_concurrency (inbound + outbound) hasn't yet been reached
handoff_concurrency_limit_reached () ->
    Receivers=supervisor:count_children(riak_core_handoff_receiver_sup),
    Senders=supervisor:count_children(riak_core_handoff_sender_sup),
    ActiveReceivers=proplists:get_value(active,Receivers),
    ActiveSenders=proplists:get_value(active,Senders),
    get_concurrency_limit() =< (ActiveReceivers + ActiveSenders).

%% spawn a sender process
send_handoff (Module,Index,TargetNode,VnodePid) ->
    case handoff_concurrency_limit_reached() of
        true ->
            {error, max_concurrency};
        false ->
            {ok,Pid}=riak_core_handoff_sender_sup:start_sender(TargetNode,
                                                               Module,
                                                               Index,
                                                               VnodePid),
            erlang:monitor(process,Pid),

            %% successfully started up a new sender handoff
            {ok, #handoff_status{ transport_pid=Pid,
                                  direction=outbound,
                                  timestamp=now(),
                                  handoff={Module,Index,TargetNode},
                                  vnode_pid=VnodePid
                                }
            }
    end.

%% spawn a receiver process
receive_handoff (SSLOpts) ->
    case handoff_concurrency_limit_reached() of
        true ->
            {error, max_concurrency};
        false ->
            {ok,Pid}=riak_core_handoff_receiver_sup:start_receiver(SSLOpts),
            erlang:monitor(process,Pid),

            %% successfully started up a new receiver
            {ok, #handoff_status{ transport_pid=Pid,
                                  direction=inbound,
                                  timestamp=now(),
                                  handoff={undefined,undefined,undefined}
                                }
            }
    end.

%%
%% EUNIT tests...
%%

-ifdef (TEST).

handoff_test_ () ->
    {spawn,
     {setup,

      %% called when the tests start and complete...
      fun () -> {ok,Pid}=start_link(), Pid end,
      fun (Pid) -> exit(Pid,kill) end,

      %% actual list of test
      [?_test(simple_handoff())
      ]}}.

simple_handoff () ->
    ?assertEqual({ok,[{senders,[]},{receivers,[]}]},handoff_status()),

    %% clear handoff_concurrency and make sure a handoff fails
    ?assertEqual(ok,set_concurrency(0)),
    ?assertEqual({error,max_concurrency},add_inbound([])),
    ?assertEqual({error,max_concurrency},add_outbound(riak_kv,0,node(),self())),

    %% allow for a single handoff
    ?assertEqual(ok,set_concurrency(1)),

    %% done
    ok.

-endif.
