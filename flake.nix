{
  description = "Reverb development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            bash
            docker
            elixir
            erlang
            git
            inotify-tools
            postgresql
          ];

          shellHook = ''
            export MIX_ENV="''${MIX_ENV:-dev}"
            echo "Reverb dev shell ready. Use 'mix test' or 'docker compose -f docker-compose.demo.yml up --build'."
          '';
        };
      });
}
