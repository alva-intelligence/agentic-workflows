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
            echo "  gh:         $(gh --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  git:        $(git --version 2>/dev/null || echo 'not found')"
            echo "  jj:         $(jj --version 2>/dev/null || echo 'not found')"
            # ClickHouse client — needed by orchestration + data-service. NOT a buildInput:
            # nixpkgs' `clickhouse` is the full server and its darwin build is unreliable, so
            # adding it here would risk breaking `nix develop` for everyone. Install it out of
            # band instead: `brew install --cask clickhouse` (a CASK, not a formula) or the
            # official one-liner `curl https://clickhouse.com/ | sh`.
            echo "  clickhouse: $(clickhouse client --version 2>/dev/null || echo 'not found — brew install --cask clickhouse')"
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

            # NOTE: the API has no /health route. Its check is `/api`, and ANY HTTP
            # response means it is up (see skills/onboard/references/service-registry.md).
            if [ "$(curl -so /dev/null -w '%{http_code}' http://localhost:9191/api 2>/dev/null || echo 000)" != "000" ]; then
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

            # NOTE: data-service's health route is /api/v1/health/ and it is auth-protected.
            # A 401 means the service IS running — treat it as healthy.
            dscode=$(curl -so /dev/null -w '%{http_code}' http://localhost:9999/api/v1/health/ 2>/dev/null || echo 000)
            if [ "$dscode" = "200" ] || [ "$dscode" = "401" ]; then
              echo "  Data Service: RUNNING"
            else
              echo "  Data Service: NOT RUNNING"
            fi

            # Orchestration has NO server and NO health endpoint by design — nothing to curl.
            # The only thing it can bind is an opt-in local Prefect server on :4200.
            if curl -sf http://localhost:4200/api/health > /dev/null 2>&1; then
              echo "  Prefect (local, opt-in): RUNNING"
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
