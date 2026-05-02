{ ... }: {
  programs.nixvim.plugins.avante = {
    enable = true;
    settings = {
      # Utilise le CLI claude code au lieu de l'API directe
      provider = "claude_code";

      input = {
        provider = "dressing";
      };
      
      select = {
        provider = "native";  # évite le bug dressing select avec tables non-list
      };

      providers = {
        claude_code = {
          model = "claude-sonnet-4-5";
          timeout = 30000;
          extra_request_body = {
            max_tokens = 8096;
          };
        };
      };

      behaviour = {
        auto_suggestions = false;
        support_paste_from_clipboard = true;
        # Désactive la suggestion auto qui lit tout le projet
        enable_cursor_planning_mode = false;
      };

      # Désactive la repo map (le truc qui scanne tout le codebase)
      repo_map = {
        ignore_patterns = [
          "*.lock"
          "node_modules"
          ".git"
          "dist"
          "build"
          "__pycache__"
          "*.min.js"
        ];
      };

      window = {
        position = "right";
        width = 30;
      };
    };
  };
}
