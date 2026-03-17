{
  description = "frndOS workspace — all dev dependencies for the frnd platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
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
            # PHP + Composer
            php82
            php82Packages.composer

            # JavaScript / TypeScript
            bun
            nodejs_20

            # Python + uv
            python311
            uv

            # Databases
            postgresql_16
            clickhouse

            # Cache
            redis

            # Tools
            gh
            git
            ngrok
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
            echo "  ClickHouse: $(clickhouse --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  Redis:      $(redis-server --version 2>/dev/null || echo 'not found')"
            echo "  gh:         $(gh --version 2>/dev/null | head -1 || echo 'not found')"
            echo "  git:        $(git --version 2>/dev/null || echo 'not found')"
            echo ""

            echo "Service health checks:"

            if pg_isready -h localhost -p 5432 > /dev/null 2>&1; then
              echo "  PostgreSQL:  RUNNING"
            else
              echo "  PostgreSQL:  NOT RUNNING"
            fi

            if curl -sf http://localhost:8123/ping > /dev/null 2>&1; then
              echo "  ClickHouse:  RUNNING"
            else
              echo "  ClickHouse:  NOT RUNNING"
            fi

            if redis-cli ping > /dev/null 2>&1; then
              echo "  Redis:       RUNNING"
            else
              echo "  Redis:       NOT RUNNING"
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
