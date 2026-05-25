using InventoryAllocationSimulator
using JSON3
using LibPQ
using UUIDs

function _store()
    InventoryAllocationSimulator.load_env_file!()
    config = InventoryAllocationSimulator.load_config(ENV)
    return config, InventoryAllocationSimulator.SqlTenantAdminStore(LibPQ.Connection(config.database.url))
end

function _ctx(store, config, api_key::AbstractString)
    return InventoryAllocationSimulator.resolve_tenant_context(
        store,
        InventoryAllocationSimulator.AuthRequest(String(api_key), nothing);
        session_secret = config.tenant.session_secret,
    )
end

function _json_print(value)
    println(JSON3.write(value))
end

function _run_setup(run_id::AbstractString)
    tenant_name = "E2E Smoke $(run_id)"
    email = "admin+$(run_id)@e2e.inventory.test"
    setup_env = copy(ENV)
    setup_env["SELF_REGISTRATION_ENABLED"] = "true"
    setup_env["DEFAULT_TENANT_NAME"] = tenant_name
    setup_env["DEFAULT_ADMIN_EMAIL"] = email
    setup_env["API_KEY_PREFIX"] = get(setup_env, "API_KEY_PREFIX", "ias_e2e")
    output = read(setenv(`julia --project scripts/setup.jl`, setup_env), String)
    api_key_match = match(r"Your API Key:\s*(\S+)", output)
    api_key_match === nothing && error("scripts/setup.jl did not emit a one-time API key. Output:\n$(output)")
    api_key = api_key_match.captures[1]

    config, store = _store()
    try
        ctx = _ctx(store, config, api_key)
        _json_print((tenant_id = string(ctx.tenant_id), apiKey = api_key, email = email))
        return 0
    finally
        close(store.connection)
    end
end

function _process_import(api_key::AbstractString, job_id::AbstractString)
    config, store = _store()
    try
        ctx = _ctx(store, config, api_key)
        result = InventoryAllocationSimulator.process_import_job!(store, config, ctx, UUID(job_id))
        _json_print(result)
        return result.status == "completed" ? 0 : 2
    finally
        close(store.connection)
    end
end

function _run_simulation(api_key::AbstractString)
    config, store = _store()
    try
        ctx = _ctx(store, config, api_key)
        result = InventoryAllocationSimulator.simulation_worker!(store, ctx; worker_id = "batch031-e2e-worker", seed = 31)
        result === nothing && (_json_print((status = "no_queued_run", id = nothing)); return 2)
        _json_print(result)
        return result.status == "completed" ? 0 : 3
    finally
        close(store.connection)
    end
end

function main(args)
    isempty(args) && error("usage: setup_to_approval_fixture.jl run-setup <run_id> | process-import <api_key> <job_id> | run-simulation <api_key>")
    command = first(args)
    if command == "run-setup"
        length(args) == 2 || error("run-setup requires run_id")
        return _run_setup(args[2])
    elseif command == "process-import"
        length(args) == 3 || error("process-import requires api_key and job_id")
        return _process_import(args[2], args[3])
    elseif command == "run-simulation"
        length(args) == 2 || error("run-simulation requires api_key")
        return _run_simulation(args[2])
    end
    error("unknown command $(command)")
end

exit(main(ARGS))
