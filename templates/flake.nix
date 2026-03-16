{
  description = "nops Fleet Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    
    # nops flake input — provides nixosModules.default (the service module) and the nops-install CLI.
    nops.url = "git+https://github.com/nixgitops/nops.git";
    nops.inputs.nixpkgs.follows = "nixpkgs";
    nops.inputs.sops-nix.follows = "sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix, nops, ... }: {
    
    # nops-install appends nixosConfigurations.<hostname> entries below this line via sed.
    # NODES_MARKER

  };
}