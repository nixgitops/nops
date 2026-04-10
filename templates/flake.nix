{
  description = "nops Fleet Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Keep nops remote-only. Pin or roll back versions through flake.lock, not by copying or path-linking nops into the fleet repo.
    nops.url = "git+https://github.com/nixgitops/nops.git";
    nops.inputs.nixpkgs.follows = "nixpkgs";
    nops.inputs.sops-nix.follows = "sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix, nops, ... }: {

    # nops-install appends nixosConfigurations.<hostname> entries below this line via sed.
    # NODES_MARKER

  };
}
