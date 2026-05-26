using Test

const BATCH042_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch042_path(parts...) = joinpath(BATCH042_ROOT, parts...)
batch042_read(parts...) = read(batch042_path(parts...), String)

@testset "Batch 042 VPS Compose stack documents app database cache migrations and volumes" begin
    compose = batch042_read("docker-compose.prod.yml")

    @test occursin("image: ghcr.io/kingsleyonoh/inventory-allocation-simulator", compose)
    @test occursin("postgres:16-alpine", compose)
    @test occursin("redis:7-alpine", compose)
    @test occursin("migrate:", compose)
    @test occursin("julia --project scripts/migrate.jl up", compose)
    @test occursin("condition: service_completed_successfully", compose)
    @test occursin("app-data:/app/data", compose)
    @test occursin("postgres-data:/var/lib/postgresql/data", compose)
    @test occursin("redis-data:/data", compose)
    @test occursin("caddy-data:/data", compose)
    @test occursin("caddy-config:/config", compose)

    deploy_doc_path = batch042_path("docs", "deployment", "vps-compose.md")
    @test isfile(deploy_doc_path)
    deploy_doc = read(deploy_doc_path, String)
    for required in [
        "docker compose -f docker-compose.prod.yml pull",
        "docker compose -f docker-compose.prod.yml up migrate",
        "docker compose -f docker-compose.prod.yml up -d app caddy",
        "DATABASE_URL=postgres://",
        "REDIS_URL=redis://redis:6379/0",
        "DUCKDB_PATH=/app/data/backtests.duckdb",
        "UPLOAD_STORAGE_PATH=/app/data/uploads",
        "docker compose -f docker-compose.prod.yml exec app julia --project scripts/setup.jl",
    ]
        @test occursin(required, deploy_doc)
    end
end

@testset "Batch 042 Caddy HTTPS reverse proxy is wired without exposing app port publicly" begin
    compose = batch042_read("docker-compose.prod.yml")
    caddyfile_path = batch042_path("config", "caddy", "Caddyfile")
    @test isfile(caddyfile_path)
    caddyfile = read(caddyfile_path, String)

    @test occursin("caddy:2-alpine", compose)
    @test occursin("./config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro", compose)
    @test occursin("80:80", compose)
    @test occursin("443:443", compose)
    @test !occursin("8000:8000", compose)
    @test occursin("APP_HOST=0.0.0.0", compose)
    @test occursin("APP_PORT=8000", compose)

    @test occursin(raw"{$PUBLIC_DOMAIN}", caddyfile)
    @test occursin("reverse_proxy app:8000", caddyfile)
    @test occursin("header", caddyfile)
    @test occursin("Strict-Transport-Security", caddyfile)

    deploy_doc = batch042_read("docs", "deployment", "vps-compose.md")
    for required in [
        "PUBLIC_DOMAIN=inventory.example.com",
        "PUBLIC_BASE_URL=https://inventory.example.com",
        "Caddy obtains and renews HTTPS certificates automatically",
        "open ports 80 and 443",
        "do not publish the application container port",
    ]
        @test occursin(required, deploy_doc)
    end
end
