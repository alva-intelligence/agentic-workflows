{
  description = "frndOS workspace — all dev dependencies for the frnd platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "frndos";

          buildInputs = with pkgs; [
            # PHP + Composer (Laravel 13)
            php85
            php85Packages.composer

            # JavaScript / TypeScript
            bun
            nodejs_22

            # Python + uv
            python312
            uv

            # Databases
            (postgresql_18.withPackages (ps: [ ps.pgvector ]))
            redis

            # ClickHouse — the data-service warehouse (frnd_agg_marts,
            # frnd_os_master, frnd_ai_database). Provisioned here for the same
            # reason postgresql and redis are: it is a backing service every
            # developer needs, and while it was missing from this file the only
            # answer to "where is my ClickHouse?" was the shared staging
            # cluster. Ending that is the point.
            #
            # nixpkgs attr `clickhouse` (pkgs/by-name/cl/clickhouse), 26.7.5.10
            # on nixos-unstable. `meta.platforms` covers 64-bit darwin as well
            # as linux, so both systems this flake targets are supported, and
            # Hydra's `clickhouse.aarch64-darwin` / `.x86_64-darwin` jobs are
            # green — the binary comes from cache.nixos.org, not a local build.
            #
            # ⚠️ It IS a source-built package (`requiredSystemFeatures =
            # [ "big-parallel" ]`; the package notes "7+h with 2 cores, ~20m
            # with a big-parallel builder"). That never bites while flake.lock
            # points at a revision Hydra has already built for your system. It
            # CAN bite whoever runs `nix flake update` inside the window between
            # a version bump and Hydra finishing the darwin job — the darwin
            # jobs lag trunk (aarch64 was on 26.7.4.58 when this landed). If a
            # `nix develop` ever starts compiling ClickHouse, that is why: roll
            # flake.lock back, or use the standalone binary path below, which is
            # a prebuilt download and takes seconds.
            #
            # This provides the BINARY (server + client) on PATH. It does not
            # start a server, create databases, or apply migrations — that stays
            # `data-service/scripts/setup-local-demo.sh`, which is the one place
            # that owns the local ClickHouse lifecycle and which now prefers
            # this binary over downloading its own. Ledger W13a: the standalone
            # binary is the single provisioning path.
            clickhouse

            # Email testing
            mailhog

            # VCS
            jujutsu

            # Tools
            curl
            gh
            git
            jq
          ];

          shellHook = ''
            echo ""
            echo "========================================"
            echo "  frndOS Dev Environment"
            echo "  Nix flake loaded successfully"
            echo "========================================"
            echo ""
            echo "Available tools:"
            echo "  PHP:        $(php --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  Composer:   $(composer --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  Bun:        $(bun --version 2>/dev/null || echo 'not found')"
            echo "  Node:       $(node --version 2>/dev/null || echo 'not found')"
            echo "  Python:     $(python3 --version 2>/dev/null || echo 'not found')"
            echo "  uv:         $(uv --version 2>/dev/null || echo 'not found')"
            echo "  PostgreSQL: $(pg_isready --version 2>/dev/null || echo 'not found')"

            echo "  Redis:      $(redis-server --version 2>/dev/null || echo 'not found')"
            # `clickhouse` is a multi-call binary; `clickhouse --version` is the
            # entrypoint that always exists, whether or not the package also
            # installs clickhouse-server/clickhouse-client symlinks.
            echo "  ClickHouse: $(clickhouse --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  gh:         $(gh --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  git:        $(git --version 2>/dev/null || echo 'not found')"
            echo "  jj:         $(jj --version 2>/dev/null || echo 'not found')"
            echo ""

            echo "Service health checks:"

            if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
              echo "  PostgreSQL:  RUNNING"
            else
              echo "  PostgreSQL:  NOT RUNNING"
            fi

            if redis-cli ping > /dev/null 2>&1; then
              echo "  Redis:       RUNNING"
            else
              echo "  Redis:       NOT RUNNING"
            fi

            # ClickHouse speaks HTTP on 8123, not a wire protocol with its own
            # readiness probe, so the check is a trivial query over curl. This
            # is the same probe data-service/scripts/setup-local-demo.sh waits
            # on, kept identical on purpose.
            if curl -s --max-time 2 http://localhost:8123/ --data-binary "SELECT 1" > /dev/null 2>&1; then
              echo "  ClickHouse:  RUNNING"
            else
              echo "  ClickHouse:  NOT RUNNING (run data-service/scripts/setup-local-demo.sh)"
            fi

            if curl -sf http://localhost:9191/health > /dev/null 2>&1; then
              echo "  API:         RUNNING"
            else
              echo "  API:         NOT RUNNING"
            fi

            if curl -sf http://localhost:3000 > /dev/null 2>&1; then
              echo "  Frontend:    RUNNING"
            else
              echo "  Frontend:    NOT RUNNING"
            fi

            if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
              echo "  AI Service:  RUNNING"
            else
              echo "  AI Service:  NOT RUNNING"
            fi

            if curl -sf http://localhost:9999/health > /dev/null 2>&1; then
              echo "  Data Service: RUNNING"
            else
              echo "  Data Service: NOT RUNNING"
            fi

            echo ""
            echo "Run './run-all.sh' to start all services."
            echo "========================================"
            echo ""
          '';
        };
      }
    );
}
