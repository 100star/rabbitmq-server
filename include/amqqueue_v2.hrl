-define(is_amqqueue_v2(Q), is_record(Q, amqqueue, 22)).

-define(amqqueue_v2_field_name(Q), element(2, Q)).
-define(amqqueue_v2_field_durable(Q), element(3, Q)).
-define(amqqueue_v2_field_auto_delete(Q), element(4, Q)).
-define(amqqueue_v2_field_exclusive_owner(Q), element(5, Q)).
-define(amqqueue_v2_field_arguments(Q), element(6, Q)).
-define(amqqueue_v2_field_pid(Q), element(7, Q)).
-define(amqqueue_v2_field_slave_pids(Q), element(8, Q)).
-define(amqqueue_v2_field_sync_slave_pids(Q), element(9, Q)).
-define(amqqueue_v2_field_recoverable_slaves(Q), element(10, Q)).
-define(amqqueue_v2_field_policy(Q), element(11, Q)).
-define(amqqueue_v2_field_operator_policy(Q), element(12, Q)).
-define(amqqueue_v2_field_gm_pids(Q), element(13, Q)).
-define(amqqueue_v2_field_decorators(Q), element(14, Q)).
-define(amqqueue_v2_field_state(Q), element(15, Q)).
-define(amqqueue_v2_field_policy_version(Q), element(16, Q)).
-define(amqqueue_v2_field_slave_pids_pending_shutdown(Q), element(17, Q)).
-define(amqqueue_v2_field_vhost(Q), element(18, Q)).
-define(amqqueue_v2_field_options(Q), element(19, Q)).
-define(amqqueue_v2_field_type(Q), element(20, Q)).
-define(amqqueue_v2_field_created_at(Q), element(21, Q)).
-define(amqqueue_v2_field_quorum_nodes(Q), element(22, Q)).

% Note: see rabbit_common/include/resource.hrl

-define(amqqueue_v2_vhost(Q), element(2, ?amqqueue_v2_field_name(Q))).
