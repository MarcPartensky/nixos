# kimi-aichat.nix
# Module Home Manager — importez-le dans votre home.nix
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.programs.aichat-moonshot;
in {
  options.programs.aichat-moonshot = {
    enable = mkEnableOption "aichat CLI configuré pour Moonshot/Kimi via sops-nix";

    sopsSecretKey = mkOption {
      type = types.str;
      default = "kimi/api_key";
      description = ''
        Nom de la clé dans votre fichier de secrets sops.
        Exemple: <literal>kimi/api_key</literal> ou <literal>aichat/moonshot_api_key</literal>.
        La valeur déchiffrée doit être la clé brute (ex: <literal>sk-xxx</literal>).
      '';
    };

    model = mkOption {
      type = types.str;
      default = "moonshot:kimi-latest";
      example = "moonshot:kimi-k1";
      description = "Modèle par défaut utilisé par aichat.";
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      example = literalExpression ''
        {
          save = true;
          keybindings = "vi";
          highlight = true;
        }
      '';
      description = ''
        Attributs Nix supplémentaires mergés dans <filename>~/.config/aichat/config.yaml</filename>.
        Ne mettez JAMAIS de secrets ici.
      '';
    };
  };

  config = mkIf cfg.enable {
    # 1. Déclare le secret pour sops-nix
    # (suppose que vous avez déjà importé le module sops-nix dans votre config HM)
    sops.secrets.${cfg.sopsSecretKey} = {};

    # 2. Fichier de config publique (sans clé API)
    home.file.".config/aichat/config.yaml".text = lib.generators.toYAML {} ({
        model = cfg.model;
      }
      // cfg.extraConfig);

    # 3. Wrapper "kimi" qui lit le secret à l'exécution
    home.packages = [
      (pkgs.writeShellApplication {
        name = "kimi";
        runtimeInputs = [pkgs.aichat];
        text = ''
          export AICHAT_MOONSHOT_API_KEY=$(cat "${config.sops.secrets.${cfg.sopsSecretKey}.path}")
          exec aichat "$@"
        '';
      })
    ];
  };
}
