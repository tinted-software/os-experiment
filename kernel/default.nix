{
  lib,
  swiftPackages,
  stdenvNoLibc,
}:

let
  inherit (swiftPackages) fetchSwiftPMDeps swift swiftpmHook;
in
stdenvNoLibc.mkDerivation (finalAttrs: {
  pname = "kernel";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [
    swift
    swiftpmHook
  ];
})
