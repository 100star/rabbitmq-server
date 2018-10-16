%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2018 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_quorum_queue).

-export([init_state/2, handle_event/2]).
-export([declare/1, recover/1, stop/1, delete/4, delete_immediately/1]).
-export([info/1, info/2, stat/1, infos/1]).
-export([ack/3, reject/4, basic_get/4, basic_consume/9, basic_cancel/4]).
-export([credit/4]).
-export([purge/1]).
-export([stateless_deliver/2, deliver/3]).
-export([dead_letter_publish/4]).
-export([queue_name/1]).
-export([cluster_state/1, status/2]).
-export([cancel_consumer_handler/3, cancel_consumer/3]).
-export([become_leader/2, update_metrics/2]).
-export([rpc_delete_metrics/1]).
-export([format/1]).
-export([open_files/1]).
-export([add_member/3]).
-export([delete_member/3]).
-export([requeue/3]).
-export([cleanup_data_dir/0]).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").
-include("amqqueue.hrl").

-type ra_server_id() :: {Name :: atom(), Node :: node()}.
-type msg_id() :: non_neg_integer().
-type qmsg() :: {rabbit_types:r('queue'), pid(), msg_id(), boolean(), rabbit_types:message()}.

-spec handle_event({'ra_event', ra_server_id(), any()}, rabbit_fifo_client:state()) ->
                          {'internal', Correlators :: [term()], rabbit_fifo_client:state()} |
                          {rabbit_fifo:client_msg(), rabbit_fifo_client:state()}.
-spec declare(rabbit_types:amqqueue()) -> {'new', rabbit_types:amqqueue(), rabbit_fifo_client:state()}.
-spec recover([rabbit_types:amqqueue()]) -> [rabbit_types:amqqueue() |
                                             {'absent', rabbit_types:amqqueue(), atom()}].
-spec stop(rabbit_types:vhost()) -> 'ok'.
-spec delete(rabbit_types:amqqueue(), boolean(), boolean(), rabbit_types:username()) ->
                    {'ok', QLen :: non_neg_integer()}.
-spec ack(rabbit_types:ctag(), [msg_id()], rabbit_fifo_client:state()) ->
                 {'ok', rabbit_fifo_client:state()}.
-spec reject(Confirm :: boolean(), rabbit_types:ctag(), [msg_id()], rabbit_fifo_client:state()) ->
                    {'ok', rabbit_fifo_client:state()}.
-spec basic_get(rabbit_types:amqqueue(), NoAck :: boolean(), rabbit_types:ctag(),
                rabbit_fifo_client:state()) ->
                       {'ok', 'empty', rabbit_fifo_client:state()} |
                       {'ok', QLen :: non_neg_integer(), qmsg(), rabbit_fifo_client:state()}.
-spec basic_consume(rabbit_types:amqqueue(), NoAck :: boolean(), ChPid :: pid(),
                    ConsumerPrefetchCount :: non_neg_integer(), rabbit_types:ctag(),
                    ExclusiveConsume :: boolean(), Args :: rabbit_framing:amqp_table(),
                    any(), rabbit_fifo_client:state()) -> {'ok', rabbit_fifo_client:state()}.
-spec basic_cancel(rabbit_types:ctag(), ChPid :: pid(), any(), rabbit_fifo_client:state()) ->
                          {'ok', rabbit_fifo_client:state()}.
-spec stateless_deliver(ra_server_id(), rabbit_types:delivery()) -> 'ok'.
-spec deliver(Confirm :: boolean(), rabbit_types:delivery(), rabbit_fifo_client:state()) ->
                     rabbit_fifo_client:state().
-spec info(rabbit_types:amqqueue()) -> rabbit_types:infos().
-spec info(rabbit_types:amqqueue(), rabbit_types:info_keys()) -> rabbit_types:infos().
-spec infos(rabbit_types:r('queue')) -> rabbit_types:infos().
-spec stat(rabbit_types:amqqueue()) -> {'ok', non_neg_integer(), non_neg_integer()}.
-spec cluster_state(Name :: atom()) -> 'down' | 'recovering' | 'running'.
-spec status(rabbit_types:vhost(), Name :: atom()) -> rabbit_types:infos() | {error, term()}.

-define(STATISTICS_KEYS,
        [policy,
         operator_policy,
         effective_policy_definition,
         consumers,
         memory,
         state,
         garbage_collection,
         leader,
         online,
         members,
         open_files
        ]).

%%----------------------------------------------------------------------------

-spec init_state(ra_server_id(), rabbit_types:r('queue')) ->
    rabbit_fifo_client:state().
init_state({Name, _}, QName) ->
    {ok, SoftLimit} = application:get_env(rabbit, quorum_commands_soft_limit),
    {ok, Q} = rabbit_amqqueue:lookup(QName),
    Leader = amqqueue:get_pid(Q),
    Nodes0 = amqqueue:get_quorum_nodes(Q),
    %% Ensure the leader is listed first
    Nodes = [Leader | lists:delete(Leader, Nodes0)],
    rabbit_fifo_client:init(QName, Nodes, SoftLimit,
                            fun() -> credit_flow:block(Name), ok end,
                            fun() -> credit_flow:unblock(Name), ok end).

handle_event({ra_event, From, Evt}, QState) ->
    rabbit_fifo_client:handle_ra_event(From, Evt, QState).

declare(Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    Durable = amqqueue:is_durable(Q),
    AutoDelete = amqqueue:is_auto_delete(Q),
    Arguments = amqqueue:get_arguments(Q),
    Opts = amqqueue:get_options(Q),
    ActingUser = maps:get(user, Opts, ?UNKNOWN_USER),
    check_invalid_arguments(QName, Arguments),
    check_auto_delete(Q),
    check_exclusive(Q),
    check_non_durable(Q),
    QuorumSize = get_default_quorum_initial_group_size(Arguments),
    RaName = qname_to_rname(QName),
    Id = {RaName, node()},
    Nodes = select_quorum_nodes(QuorumSize, rabbit_mnesia:cluster_nodes(all)),
    NewQ0 = amqqueue:set_pid(Q, Id),
    NewQ1 = amqqueue:set_quorum_nodes(NewQ0, Nodes),
    case rabbit_amqqueue:internal_declare(NewQ1, false) of
        {created, NewQ} ->
            RaMachine = ra_machine(NewQ),
            case ra:start_cluster(RaName, RaMachine,
                                  [{RaName, Node} || Node <- Nodes]) of
                {ok, _, _} ->
                    rabbit_event:notify(queue_created,
                                        [{name, QName},
                                         {durable, Durable},
                                         {auto_delete, AutoDelete},
                                         {arguments, Arguments},
                                         {user_who_performed_action, ActingUser}]),
                    {new, NewQ};
                {error, Error} ->
                    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
                    rabbit_misc:protocol_error(internal_error,
                                               "Cannot declare a queue '~s' on node '~s': ~255p",
                                               [rabbit_misc:rs(QName), node(), Error])
            end;
        {existing, _} = Ex ->
            Ex
    end.

ra_machine(Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    {module, rabbit_fifo,
     #{dead_letter_handler => dlx_mfa(Q),
       cancel_consumer_handler => {?MODULE, cancel_consumer, [QName]},
       become_leader_handler => {?MODULE, become_leader, [QName]},
       metrics_handler => {?MODULE, update_metrics, [QName]}}}.

cancel_consumer_handler(QName, {ConsumerTag, ChPid}, _Name) ->
    Node = node(ChPid),
    % QName = queue_name(Name),
    case Node == node() of
        true -> cancel_consumer(QName, ChPid, ConsumerTag);
        false ->
            rpc:cast(Node, rabbit_quorum_queue,
                     cancel_consumer,
                     [QName, ChPid, ConsumerTag])
    end.

cancel_consumer(QName, ChPid, ConsumerTag) ->
    rabbit_core_metrics:consumer_deleted(ChPid, ConsumerTag, QName),
    rabbit_event:notify(consumer_deleted,
                        [{consumer_tag, ConsumerTag},
                         {channel,      ChPid},
                         {queue,        QName},
                         {user_who_performed_action, ?INTERNAL_USER}]).

become_leader(QName, Name) ->
    Fun = fun (Q1) ->
                  amqqueue:set_state(
                    amqqueue:set_pid(Q1, {Name, node()}),
                    live)
          end,
    %% as this function is called synchronously when a ra node becomes leader
    %% we need to ensure there is no chance of blocking as else the ra node
    %% may not be able to establish it's leadership
    spawn(fun() ->
                  rabbit_misc:execute_mnesia_transaction(
                    fun() ->
                            rabbit_amqqueue:update(QName, Fun)
                    end),
                  case rabbit_amqqueue:lookup(QName) of
                      {ok, Q0} when ?is_amqqueue(Q0) ->
                          Nodes = amqqueue:get_quorum_nodes(Q0),
                          [rpc:call(Node, ?MODULE, rpc_delete_metrics, [QName])
                           || Node <- Nodes, Node =/= node()];
                      _ ->
                          ok
                  end
          end).

rpc_delete_metrics(QName) ->
    ets:delete(queue_coarse_metrics, QName),
    ets:delete(queue_metrics, QName),
    ok.

update_metrics(QName, {Name, MR, MU, M, C}) ->
    R = reductions(Name),
    rabbit_core_metrics:queue_stats(QName, MR, MU, M, R),
    Util = case C of
               0 -> 0;
               _ -> rabbit_fifo:usage(Name)
           end,
    Infos = [{consumers, C}, {consumer_utilisation, Util} | infos(QName)],
    rabbit_core_metrics:queue_stats(QName, Infos),
    rabbit_event:notify(queue_stats, Infos ++ [{name, QName},
                                               {messages, M},
                                               {messages_ready, MR},
                                               {messages_unacknowledged, MU},
                                               {reductions, R}]).

reductions(Name) ->
    try
        {reductions, R} = process_info(whereis(Name), reductions),
        R
    catch
        error:badarg ->
            0
    end.

recover(Queues) ->
    [begin
         {Name, _} = amqqueue:get_pid(Q0),
         Nodes = amqqueue:get_quorum_nodes(Q0),
         case ra:restart_server({Name, node()}) of
             ok ->
                 % queue was restarted, good
                 ok;
             {error, Err}
               when Err == not_started orelse
                    Err == name_not_registered ->
                 % queue was never started on this node
                 % so needs to be started from scratch.
                 Machine = ra_machine(Q0),
                 RaNodes = [{Name, Node} || Node <- Nodes],
                 case ra:start_server(Name, {Name, node()}, Machine, RaNodes) of
                     ok -> ok;
                     Err ->
                         rabbit_log:warning("recover: quorum queue ~w could not"
                                            " be started ~w", [Name, Err]),
                         ok
                 end;
             {error, {already_started, _}} ->
                 %% this is fine and can happen if a vhost crashes and performs
                 %% recovery whilst the ra application and servers are still
                 %% running
                 ok;
             Err ->
                 %% catch all clause to avoid causing the vhost not to start
                 rabbit_log:warning("recover: quorum queue ~w could not be "
                                    "restarted ~w", [Name, Err]),
                 ok
         end,
         %% we have to ensure the  quorum queue is
         %% present in the rabbit_queue table and not just in rabbit_durable_queue
         %% So many code paths are dependent on this.
         {ok, Q} = rabbit_amqqueue:ensure_rabbit_queue_record_is_initialized(Q0),
         Q
     end || Q0 <- Queues].

stop(VHost) ->
    _ = [begin
             Pid = amqqueue:get_pid(Q),
             ra:stop_server(Pid)
         end || Q <- find_quorum_queues(VHost)],
    ok.

delete(Q, _IfUnused, _IfEmpty, ActingUser) when ?amqqueue_is_quorum(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    QName = amqqueue:get_name(Q),
    QNodes = amqqueue:get_quorum_nodes(Q),
    %% TODO Quorum queue needs to support consumer tracking for IfUnused
    Msgs = quorum_messages(Name),
    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
    case ra:delete_cluster([{Name, Node} || Node <- QNodes], 120000) of
        {ok, {_, LeaderNode} = Leader} ->
            MRef = erlang:monitor(process, Leader),
            receive
                {'DOWN', MRef, process, _, _} ->
                    ok
            end,
            rpc:call(LeaderNode, rabbit_core_metrics, queue_deleted, [QName]),
            {ok, Msgs};
        {error, {no_more_servers_to_try, Errs}} ->
            case lists:all(fun({{error, noproc}, _}) -> true;
                              (_) -> false
                           end, Errs) of
                true ->
                    %% If all ra nodes were already down, the delete
                    %% has succeed
                    rabbit_core_metrics:queue_deleted(QName),
                    {ok, Msgs};
                false ->
                    rabbit_misc:protocol_error(
                      internal_error,
                      "Cannot delete quorum queue '~s', not enough nodes online to reach a quorum: ~255p",
                      [rabbit_misc:rs(QName), Errs])
            end
    end.

delete_immediately({Name, _} = QPid) ->
    QName = queue_name(Name),
    _ = rabbit_amqqueue:internal_delete(QName, ?INTERNAL_USER),
    ok = ra:delete_cluster([QPid]),
    rabbit_core_metrics:queue_deleted(QName),
    ok.

ack(CTag, MsgIds, QState) ->
    rabbit_fifo_client:settle(quorum_ctag(CTag), MsgIds, QState).

reject(true, CTag, MsgIds, QState) ->
    rabbit_fifo_client:return(quorum_ctag(CTag), MsgIds, QState);
reject(false, CTag, MsgIds, QState) ->
    rabbit_fifo_client:discard(quorum_ctag(CTag), MsgIds, QState).

credit(CTag, Credit, Drain, QState) ->
    rabbit_fifo_client:credit(quorum_ctag(CTag), Credit, Drain, QState).

basic_get(Q, NoAck, CTag0, QState0) when ?amqqueue_is_quorum(Q) ->
    QName = amqqueue:get_name(Q),
    {Name, _} = Id = amqqueue:get_pid(Q),
    CTag = quorum_ctag(CTag0),
    Settlement = case NoAck of
                     true ->
                         settled;
                     false ->
                         unsettled
                 end,
    case rabbit_fifo_client:dequeue(CTag, Settlement, QState0) of
        {ok, empty, QState} ->
            {ok, empty, QState};
        {ok, {MsgId, {MsgHeader, Msg}}, QState} ->
            IsDelivered = maps:is_key(delivery_count, MsgHeader),
            {ok, quorum_messages(Name), {QName, Id, MsgId, IsDelivered, Msg}, QState};
        {timeout, _} ->
            {error, timeout}
    end.

basic_consume(Q, NoAck, ChPid,
              ConsumerPrefetchCount, ConsumerTag, ExclusiveConsume, Args, OkMsg,
              QState0) when ?amqqueue_is_quorum(Q) ->
    QName = amqqueue:get_name(Q),
    maybe_send_reply(ChPid, OkMsg),
    %% A prefetch count of 0 means no limitation, let's make it into something large for ra
    Prefetch = case ConsumerPrefetchCount of
                   0 -> 2000;
                   Other -> Other
               end,
    {ok, QState} = rabbit_fifo_client:checkout(quorum_ctag(ConsumerTag),
                                               Prefetch, QState0),
    rabbit_core_metrics:consumer_created(ChPid, ConsumerTag, ExclusiveConsume,
                                         not NoAck, QName,
                                         ConsumerPrefetchCount, Args),
    {ok, QState}.

basic_cancel(ConsumerTag, ChPid, OkMsg, QState0) ->
    maybe_send_reply(ChPid, OkMsg),
    rabbit_fifo_client:cancel_checkout(quorum_ctag(ConsumerTag), QState0).

stateless_deliver(ServerId, Delivery) ->
    ok = rabbit_fifo_client:untracked_enqueue([ServerId],
                                              Delivery#delivery.message).

deliver(false, Delivery, QState0) ->
    rabbit_fifo_client:enqueue(Delivery#delivery.message, QState0);
deliver(true, Delivery, QState0) ->
    rabbit_fifo_client:enqueue(Delivery#delivery.msg_seq_no,
                               Delivery#delivery.message, QState0).

info(Q) ->
    info(Q, [name, durable, auto_delete, arguments, pid, state, messages,
             messages_ready, messages_unacknowledged]).

infos(QName) ->
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} ->
            info(Q, ?STATISTICS_KEYS);
        {error, not_found} ->
            []
    end.

info(Q, Items) ->
    [{Item, i(Item, Q)} || Item <- Items].

stat(_Q) ->
    {ok, 0, 0}.  %% TODO length, consumers count

purge(Node) ->
    rabbit_fifo_client:purge(Node).

requeue(ConsumerTag, MsgIds, QState) ->
    rabbit_fifo_client:return(quorum_ctag(ConsumerTag), MsgIds, QState).

cleanup_data_dir() ->
    Names = [Name || #amqqueue{pid = {Name, _}, quorum_nodes = Nodes}
                         <- rabbit_amqqueue:list_by_type(quorum),
                     lists:member(node(), Nodes)],
    Registered = ra_directory:list_registered(),
    [maybe_delete_data_dir(UId) || {Name, UId} <- Registered,
                                   not lists:member(Name, Names)],
    ok.

maybe_delete_data_dir(UId) ->
    Dir = ra_env:server_data_dir(UId),
    {ok, Config} = ra_log:read_config(Dir),
    case maps:get(machine, Config) of
        {module, rabbit_fifo, _} ->
            ra_lib:recursive_delete(Dir),
            ra_directory:unregister_name(UId);
        _ ->
            ok
    end.

cluster_state(Name) ->
    case whereis(Name) of
        undefined -> down;
        _ ->
            case ets:lookup(ra_state, Name) of
                [{_, recover}] -> recovering;
                _ -> running
            end
    end.

status(Vhost, QueueName) ->
    %% Handle not found queues
    QName = #resource{virtual_host = Vhost, name = QueueName, kind = queue},
    RName = qname_to_rname(QName),
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            {_, Leader} = amqqueue:get_pid(Q),
            Nodes = amqqueue:get_quorum_nodes(Q),
            Info = [{leader, Leader}, {members, Nodes}],
            case ets:lookup(ra_state, RName) of
                [{_, State}] ->
                    [{local_state, State} | Info];
                [] ->
                    Info
            end;
        {error, not_found} = E ->
            E
    end.

add_member(VHost, Name, Node) ->
    QName = #resource{virtual_host = VHost, name = Name, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            QNodes = amqqueue:get_quorum_nodes(Q),
            case lists:member(Node, rabbit_mnesia:cluster_nodes(running)) of
                false ->
                    {error, node_not_running};
                true ->
                    case lists:member(Node, QNodes) of
                        true ->
                            {error, already_a_member};
                        false ->
                            add_member(Q, Node)
                    end
            end;
        {error, not_found} = E ->
                    E
    end.

add_member(Q, Node) when ?amqqueue_is_quorum(Q) ->
    {RaName, _} = ServerRef = amqqueue:get_pid(Q),
    QName = amqqueue:get_name(Q),
    QNodes = amqqueue:get_quorum_nodes(Q),
    %% TODO parallel calls might crash this, or add a duplicate in quorum_nodes
    ServerId = {RaName, Node},
    case ra:start_server(RaName, ServerId, ra_machine(Q),
                       [{RaName, N} || N <- QNodes]) of
        ok ->
            case ra:add_member(ServerRef, ServerId) of
                {ok, _, Leader} ->
                    Fun = fun(Q1) ->
                                  Q2 = amqqueue:set_quorum_nodes(
                                         Q1,
                                         [Node | amqqueue:get_quorum_nodes(Q1)]),
                                  amqqueue:set_pid(Q2, Leader)
                          end,
                    rabbit_misc:execute_mnesia_transaction(
                      fun() -> rabbit_amqqueue:update(QName, Fun) end),
                    ok;
                E ->
                    %% TODO should we stop the ra process here?
                    E
            end;
        {error, _} = E ->
            E
    end.

delete_member(VHost, Name, Node) ->
    QName = #resource{virtual_host = VHost, name = Name, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            QNodes = amqqueue:get_quorum_nodes(Q),
            case lists:member(Node, rabbit_mnesia:cluster_nodes(running)) of
                false ->
                    {error, node_not_running};
                true ->
                    case lists:member(Node, QNodes) of
                        false ->
                            {error, not_a_member};
                        true ->
                            delete_member(Q, Node)
                    end
            end;
        {error, not_found} = E ->
                    E
    end.

delete_member(Q, Node) when ?amqqueue_is_quorum(Q) ->
    QName = amqqueue:get_name(Q),
    {RaName, _} = amqqueue:get_pid(Q),
    ServerId = {RaName, Node},
    case ra:leave_and_delete_server(ServerId) of
        ok ->
            Fun = fun(Q1) ->
                          amqqueue:set_quorum_nodes(
                            Q1,
                            lists:delete(Node, amqqueue:get_quorum_nodes(Q1)))
                  end,
            rabbit_misc:execute_mnesia_transaction(
              fun() -> rabbit_amqqueue:update(QName, Fun) end),
            ok;
        E ->
            E
    end.

%%----------------------------------------------------------------------------
dlx_mfa(Q) ->
    DLX = init_dlx(args_policy_lookup(<<"dead-letter-exchange">>, fun res_arg/2, Q), Q),
    DLXRKey = args_policy_lookup(<<"dead-letter-routing-key">>, fun res_arg/2, Q),
    {?MODULE, dead_letter_publish, [DLX, DLXRKey, amqqueue:get_name(Q)]}.

init_dlx(undefined, _Q) ->
    undefined;
init_dlx(DLX, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    rabbit_misc:r(QName, exchange, DLX).

res_arg(_PolVal, ArgVal) -> ArgVal.

args_policy_lookup(Name, Resolve, Q) when ?is_amqqueue(Q) ->
    Args = amqqueue:get_arguments(Q),
    AName = <<"x-", Name/binary>>,
    case {rabbit_policy:get(Name, Q), rabbit_misc:table_lookup(Args, AName)} of
        {undefined, undefined}       -> undefined;
        {undefined, {_Type, Val}}    -> Val;
        {Val,       undefined}       -> Val;
        {PolVal,    {_Type, ArgVal}} -> Resolve(PolVal, ArgVal)
    end.

dead_letter_publish(undefined, _, _, _) ->
    ok;
dead_letter_publish(X, RK, QName, ReasonMsgs) ->
    {ok, Exchange} = rabbit_exchange:lookup(X),
    [rabbit_dead_letter:publish(Msg, Reason, Exchange, RK, QName)
     || {Reason, Msg} <- ReasonMsgs].

%% TODO escape hack
qname_to_rname(#resource{virtual_host = <<"/">>, name = Name}) ->
    erlang:binary_to_atom(<<"%2F_", Name/binary>>, utf8);
qname_to_rname(#resource{virtual_host = VHost, name = Name}) ->
    erlang:binary_to_atom(<<VHost/binary, "_", Name/binary>>, utf8).

find_quorum_queues(VHost) ->
    Node = node(),
    mnesia:async_dirty(
      fun () ->
              qlc:e(qlc:q([Q || Q <- mnesia:table(rabbit_durable_queue),
                                ?amqqueue_is_quorum(Q),
                                amqqueue:get_vhost(Q) =:= VHost,
                                amqqueue:qnode(Q) == Node]))
      end).

i(name,        Q) when ?is_amqqueue(Q) -> amqqueue:get_name(Q);
i(durable,     Q) when ?is_amqqueue(Q) -> amqqueue:is_durable(Q);
i(auto_delete, Q) when ?is_amqqueue(Q) -> amqqueue:is_auto_delete(Q);
i(arguments,   Q) when ?is_amqqueue(Q) -> amqqueue:get_arguments(Q);
i(pid, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    whereis(Name);
i(messages, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    quorum_messages(Name);
i(messages_ready, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, MR, _, _, _}] ->
            MR;
        [] ->
            0
    end;
i(messages_unacknowledged, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, _, MU, _, _}] ->
            MU;
        [] ->
            0
    end;
i(policy, Q) ->
    case rabbit_policy:name(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(operator_policy, Q) ->
    case rabbit_policy:name_op(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(effective_policy_definition, Q) ->
    case rabbit_policy:effective_definition(Q) of
        undefined -> [];
        Def       -> Def
    end;
i(consumers, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    case ets:lookup(queue_metrics, QName) of
        [{_, M, _}] ->
            proplists:get_value(consumers, M, 0);
        [] ->
            0
    end;
i(memory, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    try
        {memory, M} = process_info(whereis(Name), memory),
        M
    catch
        error:badarg ->
            0
    end;
i(state, Q) when ?is_amqqueue(Q) ->
    {Name, Node} = amqqueue:get_pid(Q),
    %% Check against the leader or last known leader
    case rpc:call(Node, ?MODULE, cluster_state, [Name]) of
        {badrpc, _} -> down;
        State -> State
    end;
i(local_state, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    case ets:lookup(ra_state, Name) of
        [{_, State}] -> State;
        _ -> not_member
    end;
i(garbage_collection, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    try
        rabbit_misc:get_gc_info(whereis(Name))
    catch
        error:badarg ->
            []
    end;
i(members, Q) when ?is_amqqueue(Q) ->
    amqqueue:get_quorum_nodes(Q);
i(online, Q) -> online(Q);
i(leader, Q) -> leader(Q);
i(open_files, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    Nodes = amqqueue:get_quorum_nodes(Q),
    {Data, _} = rpc:multicall(Nodes, rabbit_quorum_queue, open_files, [Name]),
    lists:flatten(Data);
i(_K, _Q) -> ''.

open_files(Name) ->
    case whereis(Name) of
        undefined -> {node(), 0};
        Pid -> case ets:lookup(ra_open_file_metrics, Pid) of
                   [] -> {node(), 0};
                   [{_, Count}] -> {node(), Count}
               end
    end.

leader(Q) when ?is_amqqueue(Q) ->
    {Name, Leader} = amqqueue:get_pid(Q),
    case is_process_alive(Name, Leader) of
        true -> Leader;
        false -> ''
    end.

online(Q) when ?is_amqqueue(Q) ->
    Nodes = amqqueue:get_quorum_nodes(Q),
    {Name, _} = amqqueue:get_pid(Q),
    [Node || Node <- Nodes, is_process_alive(Name, Node)].

format(Q) when ?is_amqqueue(Q) ->
    Nodes = amqqueue:get_quorum_nodes(Q),
    [{members, Nodes}, {online, online(Q)}, {leader, leader(Q)}].

is_process_alive(Name, Node) ->
    erlang:is_pid(rpc:call(Node, erlang, whereis, [Name])).

quorum_messages(QName) ->
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, _, _, M, _}] ->
            M;
        [] ->
            0
    end.

quorum_ctag(Int) when is_integer(Int) ->
    integer_to_binary(Int);
quorum_ctag(Other) ->
    Other.

maybe_send_reply(_ChPid, undefined) -> ok;
maybe_send_reply(ChPid, Msg) -> ok = rabbit_channel:send_command(ChPid, Msg).

check_invalid_arguments(QueueName, Args) ->
    Keys = [<<"x-expires">>, <<"x-message-ttl">>, <<"x-max-length">>,
            <<"x-max-length-bytes">>, <<"x-max-priority">>, <<"x-overflow">>,
            <<"x-queue-mode">>],
    [case rabbit_misc:table_lookup(Args, Key) of
         undefined -> ok;
         _TypeVal   -> rabbit_misc:protocol_error(
                         precondition_failed,
                         "invalid arg '~s' for ~s",
                         [Key, rabbit_misc:rs(QueueName)])
     end || Key <- Keys],
    ok.

check_auto_delete(Q) when ?amqqueue_is_auto_delete(Q) ->
    Name = amqqueue:get_name(Q),
    rabbit_misc:protocol_error(
      precondition_failed,
      "invalid property 'auto-delete' for ~s",
      [rabbit_misc:rs(Name)]);
check_auto_delete(_) ->
    ok.

check_exclusive(Q) when ?amqqueue_exclusive_owner_is(Q, none) ->
    ok;
check_exclusive(Q) when ?is_amqqueue(Q) ->
    Name = amqqueue:get_name(Q),
    rabbit_misc:protocol_error(
      precondition_failed,
      "invalid property 'exclusive-owner' for ~s",
      [rabbit_misc:rs(Name)]).

check_non_durable(Q) when ?amqqueue_is_durable(Q) ->
    ok;
check_non_durable(Q) when not ?amqqueue_is_durable(Q) ->
    Name = amqqueue:get_name(Q),
    rabbit_misc:protocol_error(
      precondition_failed,
      "invalid property 'non-durable' for ~s",
      [rabbit_misc:rs(Name)]).

queue_name(RaFifoState) ->
    rabbit_fifo_client:cluster_name(RaFifoState).

get_default_quorum_initial_group_size(Arguments) ->
    case rabbit_misc:table_lookup(Arguments, <<"x-quorum-initial-group-size">>) of
        undefined -> application:get_env(rabbit, default_quorum_initial_group_size);
        {_Type, Val} -> Val
    end.

select_quorum_nodes(Size, All) when length(All) =< Size ->
    All;
select_quorum_nodes(Size, All) ->
    Node = node(),
    case lists:member(Node, All) of
        true ->
            select_quorum_nodes(Size - 1, lists:delete(Node, All), [Node]);
        false ->
            select_quorum_nodes(Size, All, [])
    end.

select_quorum_nodes(0, _, Selected) ->
    Selected;
select_quorum_nodes(Size, Rest, Selected) ->
    S = lists:nth(rand:uniform(length(Rest)), Rest),
    select_quorum_nodes(Size - 1, lists:delete(S, Rest), [S | Selected]).
