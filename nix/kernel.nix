{
  lib,
  self,
  fetchFromGitHub,
  swiftPackages,
  stdenvNoLibc,
}:

let
  inherit (swiftPackages) fetchSwiftPMDeps swift swiftpmHook;
in
stdenvNoLibc.mkDerivation (finalAttrs: {
  pname = "kernel";
  version = "0.1.0";

  src = self;

  nativeBuildInputs = [
    swift
    swiftpmHook
  ];
})
