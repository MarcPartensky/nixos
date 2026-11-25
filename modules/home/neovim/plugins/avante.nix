{...}: {
  programs.nixvim.plugins.avante = {
    enable = true;
    settings = {
      # Use the claude code CLI instead of the direct API
      # provider = "claude";
      provider = "claude";

      input = {
        provider = "dressing";
      };

      select = {
        provider = "native"; # avoids the dressing select bug with non-list tables
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
        # Disables the auto suggestion that reads the whole project
        enable_cursor_planning_mode = false;
      };

      # Disables the repo map (the thing that scans the whole codebase)
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
