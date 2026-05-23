FROM julia:1.11-bookworm AS deps
WORKDIR /app
COPY Project.toml Manifest.toml* ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

FROM julia:1.11-bookworm AS runtime
WORKDIR /app
ENV JULIA_PROJECT=/app \
    APP_ENV=production \
    APP_HOST=0.0.0.0 \
    APP_PORT=8000
COPY --from=deps /root/.julia /root/.julia
COPY Project.toml Manifest.toml* ./
COPY config ./config
COPY migrations ./migrations
COPY scripts ./scripts
COPY src ./src
EXPOSE 8000
CMD ["bash", "-lc", "julia --project scripts/migrate.jl up && julia --project src/Main.jl"]
