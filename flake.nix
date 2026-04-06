{
  description = "nops - Nix Operations Daemon";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs = { self, nixpkgs, sops-nix, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    version = "2.3.0";
    
    pythonDeps = ps: with ps; [ matrix-nio pyyaml aiohttp prometheus-client ];
    pythonEnv = pkgs.python3.withPackages pythonDeps;
  in {
    packages.${system} = {
      # Builds nops-daemon (Matrix listener) and nops-webhook (HTTP push listener) as wrapped Python executables.
      default = pkgs.stdenv.mkDerivation {
        pname = "nops";
        inherit version;
        src = ./.;
        
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        postPatch = ''
          dos2unix src/* templates/* flake.nix || true
        '';

        installPhase = ''
          mkdir -p $out/bin $out/lib $out/share/nops
          cp -r src/* $out/lib/
          cp -r templates $out/share/nops/templates
          
          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nops-daemon \
            --add-flags "$out/lib/listener.py" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash ]}

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nops-webhook \
            --add-flags "$out/lib/webhook.py" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.inetutils pkgs.nixos-rebuild pkgs.systemd pkgs.bash ]}

          makeWrapper ${pythonEnv}/bin/python3 $out/bin/nops-metrics \
            --add-flags "$out/lib/metrics_exporter.py" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.bash ]}
        '';
      };

      # Builds nops-install, an interactive CLI that scaffolds a new node's flake and SOPS secrets file.
      install = pkgs.stdenv.mkDerivation {
        name = "nops-install";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];
        
        postPatch = ''
          dos2unix src/* templates/* flake.nix || true
        '';

        installPhase = ''
          mkdir -p $out/share/nops/src $out/bin
          cp src/setup.sh $out/share/nops/src/setup.sh
          chmod +x $out/share/nops/src/setup.sh
          cp -r templates $out/share/nops/templates
       
          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nops-install \
            --add-flags "$out/share/nops/src/setup.sh" \
            --set NOPS_TEMPLATES_DIR "$out/share/nops/templates" \
            --set NOPS_SRC_DIR "$out/share/nops/src" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ 
              pkgs.git pkgs.sops pkgs.age pkgs.vim pkgs.nano 
              pkgs.util-linux pkgs.nixos-rebuild pkgs.inetutils 
              pkgs.systemd pkgs.jq 
            ]}
        '';
      };

      migrate-passwords = pkgs.stdenv.mkDerivation {
        name = "nops-migrate-passwords";
        src = ./.;
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.dos2unix ];

        postPatch = ''
          dos2unix src/* templates/* flake.nix || true
        '';

        installPhase = ''
          mkdir -p $out/share/nops/src $out/bin
          cp src/migrate-legacy-passwords.sh $out/share/nops/src/migrate-legacy-passwords.sh
          chmod +x $out/share/nops/src/migrate-legacy-passwords.sh

          makeWrapper ${pkgs.bash}/bin/bash $out/bin/nops-migrate-passwords \
            --add-flags "$out/share/nops/src/migrate-legacy-passwords.sh" \
            --prefix PATH : ${pkgs.lib.makeBinPath [ 
              pkgs.sops pkgs.age pkgs.jq pkgs.gawk pkgs.perl pkgs.openssl 
            ]}
        '';
      };
    };

    # NixOS module imported by fleet nodes via flake input. Declares the nops service user, systemd daemon(s),
    # firewall rules, and injects SOPS-decrypted Matrix and webhook secrets into the runtime environment.
    nixosModules.default = { config, lib, pkgs, ... }: 
    let 
      cfg = config.services.nops;
      # Serializes repo path and rebuild commands to a JSON file the Python daemon reads at startup.
      nopsConfig = pkgs.writeText "nops-config.json" (builtins.toJSON {
        is_controller = cfg.isController;
        controller_script = cfg.controllerScript;
        directories = {
          repo = cfg.repoPath;
          log = "/home/nops/log";
        };
        commands = {
          update = cfg.afterPush;
        };
      });
    in {
      imports = [ sops-nix.nixosModules.sops ];
      options.services.nops = {
        enable = lib.mkEnableOption "nops - Nix Operations Daemon";
        isController = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "If true, this node acts as the Controller for Terraform and Secrets.";
        };
        controllerScript = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Bash script to execute ONLY on the controller node before syncing and rebuilding.";
        };
        repoPath = lib.mkOption {
          type = lib.types.path;
          default = "/home/nops/";
        };
        afterPush = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "/run/wrappers/bin/sudo /run/current-system/sw/bin/systemd-run --working-directory=${config.services.nops.repoPath} --service-type=oneshot --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin -- /run/current-system/sw/bin/nixos-rebuild switch --flake ${config.services.nops.repoPath}#${config.networking.hostName} --impure"
          ];
          description = "Array of shell commands to execute after a push is received.";
        };
        matrix = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the Matrix bot listener.";
          };
        };
        metrics = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable the Prometheus metrics exporter for nops.";
          };
          port = lib.mkOption {
            type = lib.types.int;
            default = 9102;
            description = "Port for the nops Prometheus metrics exporter.";
          };
          listenAddress = lib.mkOption {
            type = lib.types.str;
            default = "0.0.0.0";
            description = "Address for the nops Prometheus metrics exporter to bind to.";
          };
          path = lib.mkOption {
            type = lib.types.str;
            default = "/metrics";
            description = "HTTP path served by the nops Prometheus metrics exporter.";
          };
        };
        webhook = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable the Webhook listener (Forgejo/GitLab/GitHub).";
          };
          port = lib.mkOption {
            type = lib.types.int;
            default = 8080;
            description = "Port for the Webhook listener to bind to.";
          };
          sslCert = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to the SSL certificate file for the webhook listener.";
          };
          sslKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to the SSL private key file for the webhook listener.";
          };
        };
      };

      config = lib.mkIf cfg.enable {
        networking.firewall.allowedTCPPorts =
          lib.optionals cfg.webhook.enable [ cfg.webhook.port ]
          ++ lib.optionals cfg.metrics.enable [ cfg.metrics.port ];

        users.users.nops = {
          isNormalUser = true;
          description = "nops Service Daemon Account";
          group = "nops";
          extraGroups = [ "wheel" "docker" ];
          home = "/home/nops";
          createHome = true;
          shell = pkgs.bash;
        };
        users.groups.nops = {};

        environment.systemPackages = [ 
          self.packages.${system}.default 
          pkgs.git 
          pkgs.sops 
          pkgs.inetutils
        ];

        systemd.tmpfiles.rules = [
          "d /home/nops/log 0755 nops nops -"
        ];

        # Runs the nops listener(s) as the nops user. Spawns the Matrix daemon and/or webhook server based on enabled options.
        systemd.services.nops = {
          description = "nops Operations Listener Daemon";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          path = [ pkgs.git pkgs.nixos-rebuild pkgs.inetutils pkgs.systemd pkgs.bash pkgs.openssl pkgs.sops pkgs.age ];
          serviceConfig = {
            User = "nops";
            Restart = "always";
            RestartSec = "10s";
            WorkingDirectory = cfg.repoPath;
            RuntimeDirectory = "nops-prometheus";
            RuntimeDirectoryMode = "0755";
          };
          
          environment = {
            NOPS_CONFIG_PATH = "${nopsConfig}";
            NOPS_LOG_PATH = "/home/nops/log/main.log";
            NOPS_VERSION = version;
            NOPS_METRICS_ADDRESS = cfg.metrics.listenAddress;
            NOPS_METRICS_PATH = cfg.metrics.path;
            NOPS_METRICS_PORT = builtins.toString cfg.metrics.port;
            MATRIX_BOT_TOKEN_FILE = config.sops.secrets.matrix_bot_token.path;
            MATRIX_ROOM_ID_FILE = config.sops.secrets.matrix_room_id.path;
            MATRIX_HOMESERVER_FILE = config.sops.secrets.matrix_homeserver.path;
            PROMETHEUS_MULTIPROC_DIR = "/run/nops-prometheus";
            WEBHOOK_PORT = builtins.toString cfg.webhook.port;
            WEBHOOK_SSL_CERT = if cfg.webhook.sslCert != null then cfg.webhook.sslCert else "";
            WEBHOOK_SSL_KEY = if cfg.webhook.sslKey != null then cfg.webhook.sslKey else "";
          };

          # Generates a self-signed TLS cert at the configured path if SSL is enabled and no cert exists yet.
          preStart = ''
            if [ "${builtins.toString cfg.webhook.enable}" = "1" ] && [ -n "${if cfg.webhook.sslCert != null then cfg.webhook.sslCert else ""}" ]; then
              CERT_PATH="${if cfg.webhook.sslCert != null then cfg.webhook.sslCert else ""}"
              KEY_PATH="${if cfg.webhook.sslKey != null then cfg.webhook.sslKey else ""}"
              CERT_DIR=$(dirname "$CERT_PATH")

              if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                echo "Generating self-signed SSL certificates at $CERT_DIR..."
                mkdir -p "$CERT_DIR"
                ${pkgs.openssl}/bin/openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                  -keyout "$KEY_PATH" -out "$CERT_PATH" \
                  -subj "/CN=$(hostname)"
                chmod 600 "$KEY_PATH"
                chmod 644 "$CERT_PATH"
              fi
            fi
          '';

          # Spawns enabled listeners as background processes and waits for either to exit, triggering a systemd restart.
          script = ''
             export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
             
             if [ "${builtins.toString cfg.matrix.enable}" = "1" ];
             then
               export MATRIX_BOT_TOKEN=$(cat $MATRIX_BOT_TOKEN_FILE)
               export MATRIX_ROOM_ID=$(cat $MATRIX_ROOM_ID_FILE)
               export MATRIX_HOMESERVER=$(cat $MATRIX_HOMESERVER_FILE)
               ${self.packages.${system}.default}/bin/nops-daemon &
             fi

             if [ "${builtins.toString cfg.webhook.enable}" = "1" ];
             then
               ${self.packages.${system}.default}/bin/nops-webhook &
             fi

             if [ "${builtins.toString cfg.metrics.enable}" = "1" ];
             then
               ${self.packages.${system}.default}/bin/nops-metrics &
             fi
             
             wait -n
          '';
        };
      };
    };

    apps.${system} = {
      # Exposes nops-install as a runnable Nix app: `nix run .#install`.
      install = {
        type = "app";
        program = "${self.packages.${system}.install}/bin/nops-install";
      };

      migrate-passwords = {
        type = "app";
        program = "${self.packages.${system}.migrate-passwords}/bin/nops-migrate-passwords";
      };
    };
  };
}