{
  inputs = {
    nixpkgs.url = "github:tinted-software/nixpkgs/theoparis/swift";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      eachSystem = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "riscv64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    {
      packages = eachSystem (
        system: with nixpkgs.legacyPackages.${system}; {
          kernel = callPackage ./nix/kernel.nix { inherit self; };
        }
      );
    };
}
