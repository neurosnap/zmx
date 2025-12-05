{
  description = "zmx - session persistence for terminal processes";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    { zig2nix, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig-0_15_2;
        };
      in
      with builtins;
      with env.pkgs.lib;
      let
        zmx-package = env.package {
          src = cleanSource ./.;
          zigBuildFlags = [ "-Doptimize=ReleaseSafe" ];
          zigPreferMusl = true;
        };
      in
      {
        packages = {
          zmx = zmx-package;
          default = zmx-package;
        };

        apps = {
          zmx = {
            type = "app";
            program = "${zmx-package}/bin/zmx";
          };
          default = {
            type = "app";
            program = "${zmx-package}/bin/zmx";
          };

          build = env.app [ ] "zig build \"$@\"";

          test = env.app [ ] "zig build test -- \"$@\"";
        };

        devShells.default = env.mkShell {
        };
      }
    ));
}
