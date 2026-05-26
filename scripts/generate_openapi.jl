#!/usr/bin/env julia

using YAML

const ROOT = normpath(joinpath(@__DIR__, ".."))
const ROUTES_PATH = joinpath(ROOT, "config", "routes_definitions.jl")
const OPENAPI_PATH = joinpath(ROOT, "openapi.yaml")

const METHOD_RESPONSE = Dict(
    "GET" => "200",
    "PATCH" => "200",
    "PUT" => "200",
    "DELETE" => "200",
    "POST" => "202",
)

const CREATED_POST_PATHS = Set(["/api/warehouses", "/api/skus", "/api/lanes", "/api/policies", "/api/users"])
const OK_POST_PATHS = Set(["/api/tenants/register", "/api/settings/api-key/rotate"])

function _documented_route(path::AbstractString)::Bool
    startswith(path, "/api/") && return true
    startswith(path, "/health") && return true
    path == "/metrics" && return true
    path == "/tenants/me" && return true
    return false
end

function _openapi_path(path::AbstractString)::String
    return replace(String(path), r":([A-Za-z_][A-Za-z0-9_]*)" => s"{\1}")
end

function route_definitions(; routes_path::AbstractString = ROUTES_PATH)::Vector{NamedTuple}
    source = read(routes_path, String)
    matches = eachmatch(r"RouteDefinition\(:([A-Z]+), \"([^\"]+)\", \"([^\"]+)\"\)", source)
    return [(method = String(m.captures[1]), path = String(m.captures[2]), name = String(m.captures[3])) for m in matches]
end

function _response_code(method::AbstractString, path::AbstractString)::String
    method == "POST" && path in CREATED_POST_PATHS && return "201"
    method == "POST" && path in OK_POST_PATHS && return "200"
    return get(METHOD_RESPONSE, String(method), "200")
end

function _summary(route)::String
    words = split(replace(route.name, "_" => " "))
    return isempty(words) ? route.path : uppercasefirst(join(words, " "))
end

function generate_openapi_contract(; routes = route_definitions())::Dict{String,Any}
    paths = Dict{String,Any}()
    for route in routes
        _documented_route(route.path) || continue
        path_key = _openapi_path(route.path)
        method_key = lowercase(route.method)
        path_item = get!(paths, path_key, Dict{String,Any}())
        response_code = _response_code(route.method, route.path)
        path_item[method_key] = Dict{String,Any}(
            "summary" => _summary(route),
            "responses" => Dict{String,Any}(response_code => Dict{String,Any}("description" => response_code == "201" ? "Created" : response_code == "202" ? "Accepted" : "OK")),
        )
    end
    return Dict{String,Any}(
        "openapi" => "3.1.0",
        "info" => Dict{String,Any}("title" => "Inventory Allocation Simulator API", "version" => "0.1.0"),
        "paths" => paths,
    )
end

function validate_openapi_contract(; openapi_path::AbstractString = OPENAPI_PATH, routes = route_definitions())::NamedTuple
    actual = YAML.load_file(openapi_path)
    expected = generate_openapi_contract(; routes = routes)
    missing = String[]
    for (path, path_item) in expected["paths"]
        if !haskey(actual["paths"], path)
            push!(missing, "$(path) (all methods)")
            continue
        end
        for method in keys(path_item)
            haskey(actual["paths"][path], method) || push!(missing, "$(uppercase(method)) $(path)")
        end
    end
    return (valid = isempty(missing), missing = missing, documented_paths = length(expected["paths"]))
end

function main(args = ARGS)
    if "--check" in args
        result = validate_openapi_contract()
        result.valid || error("OpenAPI contract missing documented endpoints: $(join(result.missing, ", "))")
        println("OpenAPI contract valid for $(result.documented_paths) documented paths")
        return nothing
    end
    YAML.write_file(OPENAPI_PATH, generate_openapi_contract())
    println("Wrote $(OPENAPI_PATH)")
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
