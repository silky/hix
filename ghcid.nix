{
  inputs,
  pkgs,
  packages,
  main,
  ghci,
  ghc,
  compiler,
  base,
  nixpkgs,
  commands ? _: {},
  prelude ? true,
  shellConfig ? {},
  testConfig ? {},
  easy-hls ? false,
  ...
}:
with pkgs.lib;
let
  inherit (builtins) attrNames elem;
  inherit (pkgs) system;
  inherit (pkgs.haskell.lib) disableCabalFlag overrideCabal;

  vanillaGhc = (import inputs.nixpkgs { inherit system; }).haskell.packages.${compiler};
  cmds = commands { inherit pkgs ghc; };
  hlib = import ./lib.nix { inherit (pkgs) lib; };
  hls =
    if easy-hls
    then inputs.easy-hls.defaultPackage.${system}
    else vanillaGhc.haskell-language-server;
  vms = import ./vm.nix { inherit nixpkgs pkgs; };

  configEmpty = {
    env = {};
    buildInputs = [];
    haskellPackages = _: [];
    search = [];
    restarts = [];
    preCommand = [];
    preStartCommand = [];
    exitCommand = [];
    vm = null;
  };

  unlines = concatStringsSep "\n";

  checkDeprecated = old: new: conf:
  if hasAttr old conf
  then throw "hix shell config: '${old}' is deprecated; use '${new}' in:\n${builtins.toJSON conf}"
  else {};

  mergeConfig = left: right:
  let
    l = configEmpty // left;
    r = configEmpty // right;
    concat = attr: toList l.${attr} ++ toList r.${attr};
  in
  checkDeprecated "extraBuildInputs" "buildInputs" right //
  checkDeprecated "extraSearch" "search" right //
  checkDeprecated "extraHaskellPackages" "haskellPackages" right //
  checkDeprecated "extraRestarts" "restarts" right //
  {
    env = l.env // r.env;
    search = concat "search";
    restarts = concat "restarts";
    buildInputs = concat "buildInputs";
    haskellPackages = g: l.haskellPackages g ++ r.haskellPackages g;
    preCommand = concat "preCommand";
    preStartCommand = concat "preStartCommand";
    exitCommand = concat "exitCommand";
    vm = if r.vm == null then l.vm else r.vm;
  };

  fullConfig = user: mergeConfig (mergeConfig configEmpty shellConfig) user;

  restart = f: ''--restart="${f}"'';

  pkgRestarts = attrsets.mapAttrsToList (n: pkg: restart "$PWD/${pkg}/${n}.cabal");

  ghcidCmd =
    command: test: restarts:
    let
      allRestarts = (pkgRestarts packages) ++ (map restart restarts);
    in
      ''ghcid -W ${toString allRestarts} --command="${command}" --test='${test}' '';

  startVm = vm: if vm == null then "" else vms.ensure vm;

  stopVm = vm: if vm == null then "" else vms.kill vm;

  ghcidCmdFile = {
    command,
    test,
    restarts,
    preStartCommand,
    exitCommand,
    vm,
    ...
  }:
  let
    vmData = if vm == null then null else
    let
      type = vm.type or "create";
      vmCreate = vm.create or vms.${type};
    in vmCreate vm;

  in pkgs.writeScript "ghcid-cmd" ''
    #!${pkgs.zsh}/bin/zsh
    quitting=0
    quit() {
      if [[ $quitting == 0 ]]
      then
        quitting=1
        print ">>> quitting due to signal $1"
        ${stopVm vmData}
        ${unlines exitCommand}
        # kill zombie GHCs
        ${pkgs.procps}/bin/pkill -9 -x -P 1 ghc
      fi
      return 1
    }
    TRAPINT() { quit $* }
    TRAPTERM() { quit $* }
    TRAPKILL() { quit $* }
    TRAPEXIT() { quit $* }
    ${unlines preStartCommand}
    ${startVm vmData}
    ${ghcidCmd command test restarts}
  '';

  shellFor = {
    packageNames,
    hook ? "",
    config ? {},
  }:
  let
    conf = fullConfig config;
    isNotTarget = p: !(p ? pname && elem p.pname packageNames);
    bInputs = p: p.buildInputs ++ p.propagatedBuildInputs;
    targetDeps = g: builtins.filter isNotTarget (concatMap bInputs (map (p: g.${p}) packageNames));
    hsPkgs = g: targetDeps g ++ conf.haskellPackages g;
    devInputs = [
      (ghc.ghcWithPackages hsPkgs)
      vanillaGhc.ghcid
      vanillaGhc.cabal-install
      hls
    ];
    args = {
      name = "ghci-shell";
      buildInputs = devInputs ++ conf.buildInputs;
      shellHook = hook;
    };
  in
    pkgs.stdenv.mkDerivation (args // conf.env);

  ghcidShellCmd = {
    script,
    test,
    config ? {},
    cwd ? null,
  }:
  let
    conf = fullConfig config;
    mainCommand = ghci.command {
      packages = packages;
      inherit script prelude cwd;
      inherit (conf) search;
    };
    command = ''
      ${unlines conf.preCommand}
      ${mainCommand}
    '';
  in ghcidCmdFile (conf // { inherit command test; });

  ghciShellFor = name: {
    script,
    test,
    config ? {},
    cwd ? null,
  }:
  shellFor {
    packageNames = attrNames packages;
    hook = ghcidShellCmd { inherit script test config cwd; };
    inherit config;
  };

  shells = builtins.mapAttrs ghciShellFor cmds;

  shellWith = args: shellFor ({ packageNames = attrNames packages; } // args);

  ghcidTestWith = args: import ./ghcid-test.nix ({ inherit pkgs; } // args);

  ghcidTest = ghcidTestWith {};

  shellAppCmd = name: config: pkgs.writeScript "shell-${name}" "nix develop -c ${ghcidShellCmd config}";

  shellApp = name: config: {
    type = "app";
    program = "${shellAppCmd name config}";
  };

  run = {
    pkg,
    module,
    name,
    type,
    runner,
    config ? {},
  }@args:
  ghciShellFor "run" {
    cwd = pkg;
    config = mergeConfig (mergeConfig config { search = ["$PWD/${pkg}/${type}"]; }) (hlib.asFunction testConfig args);
    script = ghci.script runner module;
    test = ghci.runner runner name;
  };

in shells // {
  inherit shells shellFor shellWith ghcidCmdFile ghciShellFor haskell-language-server ghcidTestWith ghcidTest;
  run = makeOverridable run {
    pkg = main;
    module = "Main";
    name = "main";
    type = "test";
    runner = "generic";
  };
  hls = haskell-language-server;
  hlsApp = pkgs.writeScript "hls" "nix develop -c haskell-language-server";
  cmd = ghcidCmd;
  shell = shellWith {};
  commands = cmds;
  shellApps = builtins.mapAttrs shellApp cmds;
}
