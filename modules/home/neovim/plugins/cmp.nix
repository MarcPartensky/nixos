{...}: let
  selectOpts = "{ behavior = cmp.SelectBehavior.Insert }";
in {
  programs.nixvim.plugins = {
    luasnip.enable = true;
    lspkind = {
      enable = true;
      cmp.enable = true;
    };

    cmp-nvim-lsp.enable = true;
    cmp-buffer.enable = true;
    cmp-path.enable = true;
    cmp-treesitter.enable = true;

    cmp = {
      enable = true;
      settings = {
        autoEnableSources = true;
        performance.debounce = 150;
        sources = [
          {name = "path";}
          {
            name = "nvim_lsp";
            keywordLength = 1;
          }
          {
            name = "buffer";
            keywordLength = 3;
          }
          {name = "luasnip";}
        ];
        snippet.expand = "function(args) require('luasnip').lsp_expand(args.body) end";
        mapping = {
          "<Up>" = "cmp.mapping.select_prev_item(${selectOpts})";
          "<Down>" = "cmp.mapping.select_next_item(${selectOpts})";
          "<C-p>" = "cmp.mapping.select_prev_item(${selectOpts})";
          "<C-n>" = "cmp.mapping.select_next_item(${selectOpts})";
          "<C-u>" = "cmp.mapping.scroll_docs(-4)";
          "<C-d>" = "cmp.mapping.scroll_docs(4)";
          "<C-e>" = "cmp.mapping.abort()";
          "<C-y>" = "cmp.mapping.confirm({select = true})";
          "<CR>" = "cmp.mapping.confirm({select = false})";
        };
        window = {
          completion.border = "rounded";
          documentation.border = "rounded";
        };
      };
    };
  };
}
