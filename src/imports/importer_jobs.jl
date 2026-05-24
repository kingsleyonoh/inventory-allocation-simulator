function create_import_job!(
    store::AbstractTenantAdminStore,
    config::AppConfig,
    ctx::TenantContext,
    import_type,
    original_filename,
    content::AbstractString,
)::NamedTuple
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    parsed_type = _validate_import_type(import_type)
    _enforce_import_size!(config, content)
    headers, rows = _csv_rows(content)
    _validate_import_headers(parsed_type, headers)
    id = uuid4()
    tenant_dir = joinpath(config.imports.upload_storage_path, string(ctx.tenant_id))
    mkpath(tenant_dir)
    file_path = joinpath(tenant_dir, string(id, "-", _safe_filename(original_filename)))
    write(file_path, content)
    row = Dict{Symbol,Any}(
        :id => id,
        :tenant_id => ctx.tenant_id,
        :import_type => parsed_type,
        :status => "queued",
        :original_filename => _safe_filename(original_filename),
        :file_path => file_path,
        :row_count => length(rows),
        :error_report => NamedTuple[],
        :committed_rows => 0,
    )
    persist_import_job_create!(store, row)
    return _import_job_response(row)
end

function persist_import_job_create!(store::MemoryTenantAdminStore, row)
    store.import_jobs[row[:id]] = row
    return row
end

function persist_import_job_create!(store::SqlTenantAdminStore, row)
    LibPQ.execute(store.connection, """
        INSERT INTO import_jobs (id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report)
        VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8::jsonb)
    """, [string(row[:id]), string(row[:tenant_id]), row[:import_type], row[:status], row[:original_filename], row[:file_path], row[:row_count], JSON3.write(row[:error_report])])
    return row
end

function fetch_import_job(store::MemoryTenantAdminStore, tenant_id::UUID, job_id::UUID)
    row = get(store.import_jobs, job_id, nothing)
    row === nothing && return nothing
    return row[:tenant_id] == tenant_id ? row : nothing
end

function _sql_import_job_row(row)::Dict{Symbol,Any}
    return Dict{Symbol,Any}(
        :id => UUID(String(row[1])),
        :tenant_id => UUID(String(row[2])),
        :import_type => row[3],
        :status => row[4],
        :original_filename => row[5],
        :file_path => row[6],
        :row_count => Int(row[7]),
        :error_report => JSON3.read(String(row[8])),
        :committed_rows => 0,
    )
end

function fetch_import_job(store::SqlTenantAdminStore, tenant_id::UUID, job_id::UUID)
    result = LibPQ.execute(store.connection, """
        SELECT id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
        FROM import_jobs
        WHERE tenant_id = \$1 AND id = \$2
        LIMIT 1
    """, [string(tenant_id), string(job_id)])
    isempty(result) && return nothing
    return _sql_import_job_row(first(result))
end

function get_import_result(store::AbstractTenantAdminStore, ctx::TenantContext, job_id)::NamedTuple
    authorize!(ctx, PLANNING_READ_ACTION, PLANNING_RESOURCE)
    row = fetch_import_job(store, ctx.tenant_id, _uuid_value(job_id))
    row === nothing && throw(ApiError("NOT_FOUND", "Import job not found"; status = 404))
    return _import_job_response(row)
end

function claim_next_import_job!(store::MemoryTenantAdminStore, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    queued = sort([row for row in values(store.import_jobs) if row[:tenant_id] == ctx.tenant_id && row[:status] == "queued"]; by = row -> row[:id])
    isempty(queued) && return nothing
    row = first(queued)
    row[:status] = "running"
    row[:worker_id] = String(worker_id)
    return _import_job_response(row)
end

function claim_next_import_job!(store::SqlTenantAdminStore, ctx::TenantContext; worker_id::AbstractString = "import-worker")
    authorize!(ctx, PLANNING_WRITE_ACTION, PLANNING_RESOURCE)
    result = LibPQ.execute(store.connection, """
        UPDATE import_jobs
        SET status = 'running', updated_at = now()
        WHERE id = (
            SELECT id FROM import_jobs
            WHERE tenant_id = \$1 AND status = 'queued'
            ORDER BY created_at
            LIMIT 1
        )
        RETURNING id, tenant_id, import_type, status, original_filename, file_path, row_count, error_report
    """, [string(ctx.tenant_id)])
    isempty(result) && return nothing
    return _import_job_response(_sql_import_job_row(first(result)))
end

function claim_next_import_job_for_system!(store::SqlTenantAdminStore; worker_id::AbstractString = "import-worker")
    result = LibPQ.execute(store.connection, """
        UPDATE import_jobs
        SET status = 'running', updated_at = now()
        WHERE id = (
            SELECT id FROM import_jobs
            WHERE status = 'queued'
            ORDER BY created_at
            LIMIT 1
        )
        RETURNING id, tenant_id
    """)
    isempty(result) && return nothing
    row = first(result)
    return (id = UUID(String(row[1])), tenant_id = UUID(String(row[2])))
end
