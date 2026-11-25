# kimi-aichat.nix
# Home Manager module - import it in your home.nix
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
    enable = mkEnableOption "aichat CLI configured for Moonshot/Kimi via sops-nix";

    sopsSecretKey = mkOption {
      type = types.str;
      default = "kimi/api_key";
      description = ''
        Name of the key in your sops secrets file.
        Example: <literal>kimi/api_key</literal> or <literal>aichat/moonshot_api_key</literal>.
        The decrypted value must be the raw key (e.g. <literal>sk-xxx</literal>).
      '';
    };

    model = mkOption {
      type = types.str;
      default = "moonshot:kimi-latest";
      example = "moonshot:kimi-k1";
      description = "Default model used by aichat.";
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
        Additional Nix attributes merged into <filename>~/.config/aichat/config.yaml</filename>.
        NEVER put secrets here.
      '';
    };
  };

  config = mkIf cfg.enable {
    # 1. Declare the secret for sops-nix
    # (assumes you have already imported the sops-nix module in your HM config)
    sops.secrets.${cfg.sopsSecretKey} = {};

    # 2. Public config file (without API key)
    home.file.".config/aichat/config.yaml".text = lib.generators.toYAML {} ({
        model = cfg.model;
      }
      // cfg.extraConfig);

    # 3. "kimi" wrapper that reads the secret at runtime
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
