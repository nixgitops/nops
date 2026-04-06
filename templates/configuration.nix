{ config, pkgs, ... }:

{
  imports = [ 
    ./hardware-configuration.nix 
    ./imports.nix
  ];

  # nops daemon config — repoPath and afterPush are set by the installer; override trigger mode per node.
  services.nops = {
    enable = true;
    repoPath = "/home/nops/";
    matrix.enable = MATRIX_ENABLE_PLACEHOLDER;
    webhook.enable = WEBHOOK_ENABLE_PLACEHOLDER;
    webhook.port = 8080;
    
    afterPush = [
      "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --no-block --working-directory=${config.services.nops.repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services.nops.repoPath}#${config.networking.hostName} --impure"
    ];
  };
  
  networking.hostName = "nops-node";
  time.timeZone = "UTC";

  # GRUB targeting /dev/sda — adjust device to match the hardware.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda"; 

  # Opens ports for SSH, node-exporter (9100), process-exporter (9256), and the nops webhook.
  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 9100 9256 8080 ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
  };

  # Primary admin user — username and initialPassword are substituted by the installer.
  users.users.tdavis = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "password"; 
  };

  security.sudo.extraRules = [
    {
      users = [ "nops" ];
      commands = [
        { command = "ALL"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # Enables flakes and nix-command; installs the tools needed for fleet operations.
  nix.settings.experimental-features = [ "flakes" "nix-command" ];
  environment.systemPackages = with pkgs; [ 
    git 
    vim 
    sops 
    age 
  ];

  # SOPS uses the age key at /var/lib/sops-nix/key.txt to decrypt fleet secrets at activation.
  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets = {
    matrix_bot_token = { owner = "nops"; };
    matrix_room_id = { owner = "nops"; };
    matrix_homeserver = { owner = "nops"; };
    git_username = { owner = "nops"; };
    git_password = { owner = "nops"; };
  };

  # Shell credential helper reads SOPS-decrypted git credentials at clone/push time. safe.directory allows root rebuilds on the nops-owned repo.
  environment.etc."git-credential-nops" = {
    mode = "0555";
    text = builtins.replaceStrings [ "\r" ] [ "" ] ''
      #!${pkgs.runtimeShell}
      echo username=$(cat ${config.sops.secrets.git_username.path})
      echo password=$(cat ${config.sops.secrets.git_password.path})
    '';
  };

  programs.git = {
    enable = true;
    config = {
      credential.helper = "/etc/git-credential-nops";
      safe.directory = "*";
    };
  };

  system.stateVersion = "25.11";
}