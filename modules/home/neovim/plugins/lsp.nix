{...}: {
  programs.nixvim.plugins.lsp = {
    enable = true;
    inlayHints = true;
    servers = {
      pyright.enable = true;
      pylsp.enable = true;
      # basedpyright.enable = true;
      jsonls.enable = true;
      marksman.enable = true;
      nil_ls.enable = true;
      nixd.enable = true;
      yamlls.enable = true;
      taplo.enable = true;
    };
    keymaps = {
      diagnostic = {
        "<leader>E" = "open_float";
        "[" = "goto_prev";
        "]" = "goto_next";
      };
      lspBuf = {
        "K" = "hover";
        "gd" = "definition";
        "gr" = "references";
        "<leader>ca" = "code_action";
        "<leader>cr" = "rename";
      };
    };
    preConfig = ''
      vim.diagnostic.config({
        virtual_text = false,
        severity_sort = true,
        float = { border = 'rounded', source = 'always' },
      })
    '';
    postConfig = ''
      local signs = { Error = " ", Warn = " ", Hint = " ", Info = " " }
      for type, icon in pairs(signs) do
        local hl = "DiagnosticSign" .. type
        vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
      end
    '';
  };
}
