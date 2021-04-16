{
  base,
  pkgs,
  compiler,
  overrides ? { ... }: _: _: {},
  packages ? {},
  cabal2nixOptions ? "",
  profiling ? false,
}:
let
  cabal = import ./cabal-dep.nix;
  pure = import ./pure.nix;
  tools = import ./tools.nix { inherit pkgs; };
  inherit (pkgs.haskell.lib) dontCheck dontHaddock dontBenchmark disableLibraryProfiling;

  finalOverrides =
    if builtins.isList overrides
    then tools.composeCabal overrides
    else overrides;

  reduceWork = d: disableLibraryProfiling (dontHaddock (dontBenchmark d));

  local = ghc: n: p: ghc.callCabal2nixWithOptions n (pure.packagePath base p) cabal2nixOptions {};

  projectPackages = self: _: builtins.mapAttrs (local self) packages;

  buildOverrides = self: super:
    pure.overrides finalOverrides { inherit pkgs compiler; cabal = cabal { inherit pkgs self super; }; } self super;
in
  pkgs.lib.composeExtensions projectPackages buildOverrides
