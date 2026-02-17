{
  description = "Dev shell for mcp-logging-pgsql-server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          shell = "${pkgs.zsh}/bin/zsh";

          packages = with pkgs; [
            nodejs_24
            pnpm
            postgresql
            git
            curl
            jq
            zsh
          ];

          shellHook = ''
            export SHELL="${pkgs.zsh}/bin/zsh"
            export PGHOST="127.0.0.1"
            export PGPORT="5432"
            export PGDATABASE="app_logs"
            export PGUSER="postgres"
            export PAGER="less -FRX"

            echo "Entered dev shell: node=$(node --version) pnpm=$(pnpm --version)"
            echo "PostgreSQL client: $(psql --version | awk '{ print $3 }')"
          '';
        };
      }
    );
}
