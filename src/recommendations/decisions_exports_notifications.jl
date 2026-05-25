function _canonical_recommendation_net_value(row)::NamedTuple
    explanation = get(row, :explanation, Dict{String,Any}())
    if explanation isa AbstractDict && haskey(explanation, "net_value")
        net = explanation["net_value"]
        return recommendation_net_value(
            expected_benefit_cents = Int(net["expected_benefit_cents"]),
            expected_margin_gain_cents = Int(get(net, "expected_margin_gain_cents", row[:expected_margin_gain_cents])),
            transfer_cost_cents = Int(net["transfer_cost_cents"]),
            holding_cost_cents = Int(get(net, "holding_cost_cents", 0)),
        )
    end
    return recommendation_net_value(
        expected_benefit_cents = Int(row[:net_value_cents]) - Int(row[:expected_margin_gain_cents]) + Int(row[:transfer_cost_cents]),
        expected_margin_gain_cents = Int(row[:expected_margin_gain_cents]),
        transfer_cost_cents = Int(row[:transfer_cost_cents]),
        holding_cost_cents = 0,
    )
end

function recommendation_view_model(row)::NamedTuple
    rec = _recommendation_response(row)
    net = _canonical_recommendation_net_value(row)
    return merge(rec, (net_value_cents = net.net_value_cents, net_value = net))
end

function list_recommendations(store::AbstractTenantAdminStore, ctx::TenantContext; params = Dict{String,String}())::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    page = parse_cursor_params(params; allowed_filters = Set(["simulation_run_id", "status"]))
    rows = fetch_recommendations(store, ctx.tenant_id, page)
    return _page_response(:recommendations, [recommendation_view_model(row) for row in rows], page)
end

function get_recommendation(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = _fetch_recommendation_by_id(store, ctx.tenant_id, _uuid_value(recommendation_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    return recommendation_view_model(row)
end

function fetch_recommendations(store::MemoryTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    rows = [row for row in values(store.allocation_recommendations) if row[:tenant_id] == tenant_id]
    if haskey(page.filters, "simulation_run_id")
        run_id = _uuid_value(page.filters["simulation_run_id"])
        rows = [row for row in rows if row[:simulation_run_id] == run_id]
    end
    if haskey(page.filters, "status")
        status = _validate_choice("status", page.filters["status"], RECOMMENDATION_STATUSES)
        rows = [row for row in rows if row[:status] == status]
    end
    return first(sort(rows; by = row -> row[:created_at]), min(page.limit, length(rows)))
end

function fetch_recommendations(store::SqlTenantAdminStore, tenant_id::UUID, page::CursorPageRequest)
    run_filter = haskey(page.filters, "simulation_run_id") ? string(_uuid_value(page.filters["simulation_run_id"])) : nothing
    status_filter = haskey(page.filters, "status") ? _validate_choice("status", page.filters["status"], RECOMMENDATION_STATUSES) : nothing
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, simulation_run_id, from_warehouse_id, to_warehouse_id, sku_id, transfer_units, expected_stockout_reduction_units, expected_margin_gain_cents, transfer_cost_cents, net_value_cents, confidence_score, explanation, status, created_at, updated_at
        FROM allocation_recommendations
        WHERE tenant_id = \$1
          AND simulation_run_id = COALESCE(\$2::uuid, simulation_run_id)
          AND status = COALESCE(\$3::text, status)
        ORDER BY created_at
        LIMIT \$4
    """, [string(tenant_id), _sql_null(run_filter), _sql_null(status_filter), page.limit])
    return [_sql_recommendation_row(row) for row in result]
end

function _csv_escape(value)::String
    text = string(value)
    if occursin(',', text) || occursin('"', text) || occursin('\n', text)
        return string('"', replace(text, "\"" => "\"\""), '"')
    end
    return text
end

function export_recommendation_csv(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id)::NamedTuple
    authorize!(ctx, RECOMMENDATION_DECIDE_EXPORT_ACTION, RECOMMENDATION_RESOURCE)
    row = _fetch_recommendation_by_id(store, ctx.tenant_id, _uuid_value(recommendation_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    net = _canonical_recommendation_net_value(row)
    headers = ["recommendation_id", "simulation_run_id", "from_warehouse_id", "to_warehouse_id", "sku_id", "transfer_units", "expected_stockout_reduction_units", "expected_benefit_cents", "expected_margin_gain_cents", "transfer_cost_cents", "holding_cost_cents", "net_value_cents", "confidence_score", "status"]
    values = [row[:id], row[:simulation_run_id], row[:from_warehouse_id], row[:to_warehouse_id], row[:sku_id], row[:transfer_units], row[:expected_stockout_reduction_units], net.expected_benefit_cents, net.expected_margin_gain_cents, net.transfer_cost_cents, net.holding_cost_cents, net.net_value_cents, row[:confidence_score], row[:status]]
    body = join(headers, ",") * "\n" * join(_csv_escape.(values), ",") * "\n"
    return (filename = string("recommendation-", row[:id], ".csv"), content_type = "text/csv; charset=utf-8", body = body, net_value_cents = net.net_value_cents)
end

function build_recommendation_high_value_notification_event(store::AbstractTenantAdminStore, ctx::TenantContext, recommendation_id, event_id::AbstractString)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = _fetch_recommendation_by_id(store, ctx.tenant_id, _uuid_value(recommendation_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Recommendation not found"; status = 404))
    net = _canonical_recommendation_net_value(row)
    return build_local_notification_event(
        "allocation.high_value_found",
        ctx.tenant_id,
        event_id;
        source_record_type = "allocation_recommendation",
        source_record_id = row[:id],
        title = "High-value allocation found",
        body = string("Recommendation net value ", net.net_value_cents, "¢ requires review"),
        payload = Dict{String,Any}(
            "recommendation_id" => string(row[:id]),
            "net_value_cents" => net.net_value_cents,
            "net_value" => Dict{String,Any}(String(name) => getproperty(net, name) for name in propertynames(net)),
        ),
    )
end
