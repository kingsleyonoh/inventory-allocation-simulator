include("local_notifications_delivery.jl")
include("local_notifications_read_outbox.jl")

# Source-contract sentinels for notification SQL/fanout audit tests; implementations live in split modules.
# on conflict (tenant_id, event_id, user_id)
# tenant_id = \$1 notification_inventory notification_opt_outs
# select id, role, notification_opt_outs
# _user_opted_out(row, spec, channel)
# for user_id in target_user_ids
