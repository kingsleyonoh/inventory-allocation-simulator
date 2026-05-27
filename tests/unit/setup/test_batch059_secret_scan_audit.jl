using Test

const BATCH059_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
batch059_readroot(path...) = read(joinpath(BATCH059_ROOT, path...), String)

@testset "Batch 059 PRD secret scan audit contract" begin
    progress = batch059_readroot("docs", "progress.md")
    ci_workflow = batch059_readroot(".github", "workflows", "ci.yml")
    shell_scanner = joinpath(BATCH059_ROOT, "scripts", "scan-secrets.sh")
    pwsh_scanner = joinpath(BATCH059_ROOT, "scripts", "scan-secrets.ps1")
    gate_script = joinpath(BATCH059_ROOT, ".yolo", "scripts", "validate-batch-059-secret-scan.sh")

    @test occursin("- [x] [AUDIT] Verify secret scan passes with no hardcoded credentials — PRD §15", progress)
    @test isfile(shell_scanner)
    @test isfile(pwsh_scanner)
    @test isfile(gate_script)

    shell_source = read(shell_scanner, String)
    pwsh_source = read(pwsh_scanner, String)
    gate_source = isfile(gate_script) ? read(gate_script, String) : ""

    for pattern in ["PostgreSQL-URL", "OpenAI-key", "Anthropic-key", "Generic-bearer-token", "Long-value-near-secret-keyword"]
        @test occursin(pattern, shell_source)
        @test occursin(pattern, pwsh_source)
    end

    @test occursin("scan-secrets", ci_workflow)
    @test occursin("--mode tracked", ci_workflow)
    @test occursin("--mode all", gate_source)
    @test occursin("--mode tracked", gate_source)
    @test occursin("status=clean", gate_source)

    @test occursin("perl", shell_source)
    @test occursin("File::Temp", shell_source)
    @test !occursin("while IFS= read -r LINE", shell_source)
end
