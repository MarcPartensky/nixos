[
  # ==============================
  # 1. GLOBAL AND SYSTEM MAPPINGS
  # ==============================

  # Save the file (Ctrl+s)
  {
    mode = "n";
    key = "<C-s>";
    action = ":w<cr>";
    options.desc = "Save File";
  }

  # Select all (Ctrl+a)
  {
    mode = "n";
    key = "<C-a>";
    action = "ggVG";
    options.desc = "Select All";
  }

  # Close all windows/buffers (Ctrl+w - remapped here for Neovim quit)
  {
    mode = "n";
    key = "<C-w>";
    action = ":qa<cr>";
    options.desc = "Quit All (Neovim)";
  }

  # Run 'make' (Ctrl+m)
  {
    mode = "n";
    key = "<C-m>";
    # Note: jobstart is better handled directly in Lua or by using ToggleTerm
    action = ":call jobstart(['alacritty', '-e', 'make'])<CR>";
    options.desc = "Run Make in Alacritty";
  }

  # Execute the current file (Ctrl+i)
  {
    mode = "n";
    key = "<C-i>";
    action = ":!$PWD/%<cr>";
    options.desc = "Execute Current File";
  }

  # ==============================
  # 2. WINDOW MANAGEMENT (SPLIT)
  # ==============================

  # Navigate between splits (Ctrl+h/j/k/l)
  {
    mode = "n";
    key = "<C-h>";
    action = "<C-w>h";
    options.desc = "Move Left Split";
  }
  {
    mode = "n";
    key = "<C-j>";
    action = "<C-w>j";
    options.desc = "Move Down Split";
  }
  {
    mode = "n";
    key = "<C-k>";
    action = "<C-w>k";
    options.desc = "Move Up Split";
  }
  {
    mode = "n";
    key = "<C-l>";
    action = "<C-w>l";
    options.desc = "Move Right Split";
  }


  # ==============================
  # 3. BASE PLUGIN MAPPINGS
  # ==============================

  # 3.1. Telescope (File search)
  {
    mode = "n";
    key = "<C-p>";
    action = "<cmd>Telescope find_files<cr>";
    options.desc = "Telescope Find Files (Ctrl+p)";
  }
  {
    mode = "n";
    key = "<C-g>";
    action = "<cmd>Telescope live_grep<cr>";
    options.desc = "Telescope Live Grep (Ctrl+g)";
  }

  # 3.2. Neo-tree (File explorer)
  {
    mode = "n";
    key = "<C-o>";
    action = ":Neotree toggle<cr>";
    options.desc = "Toggle Neo-tree (Ctrl+o)";
  }

  # 3.3. Comment.nvim (Comment)
  # For Neovim (nixvim), the best way to map C-/ for Comment.nvim
  # is often to use the Lua call directly or the default mapping 'gc'.
  # Use <Plug>(...):
  {
    mode = ["n" "v"];
    key = "<C-/>";
    action = "<Plug>(comment_toggle)";
    options.desc = "Toggle Comment (Ctrl+/)";
  }
  # Note: If <Plug> does not work for visual mode, you will
  # probably have to use the specific command for visual mode or 'gc'.
  # The "v" mapping for "gc" is already done below.

  # Specific mapping for visual mode (gc)
  {
    mode = "v";
    key = "gc";
    action = "<Plug>(comment_toggle)";
    options.desc = "Toggle Comment Visually";
  }

  # 3.4. ToggleTerm (Terminal)
  {
    mode = "n";
    key = "<F2>";
    action = ":ToggleTerm<cr>";
    options.desc = "Toggle Terminal (F2)";
  }

  # 3.5. BufferLine (Tab navigation)
  {
    mode = "n";
    key = "<tab>";
    action = ":BufferLineCycleNext<cr>";
    options.desc = "Next Buffer";
  }
  {
    mode = "n";
    key = "<S-tab>";
    action = ":BufferLineCyclePrev<cr>";
    options.desc = "Previous Buffer";
  }
  {
    mode = "n";
    key = "<C-t>";
    action = ":tabnew<cr>";
    options.desc = "New Tab";
  }

  # 3.6. SessionManager
  {
    mode = "n";
    key = "<C-f>";
    action = ":SessionManager load_session<cr>";
    options.desc = "Load Session";
  }
  {
    mode = "n";
    key = "<C-x>";
    action = ":SessionManager save_current_session<cr>";
    options.desc = "Save Current Session";
  }
  {
    mode = "n";
    key = "<C-q>";
    action = ":SessionManager delete_session<CR>";
    options.desc = "Delete Session";
  }

  # 3.7. Avante (Chat/AI)
  # The visual mode mapping for Avante.
  {
    mode = "v";
    key = "<C-;>";
    action = ":AvanteToggle<cr>";
    options.desc = "Avante: Toggle My Prompt (Visual)";
  }
  # Remark: Your autocommand for `avante.config` must be placed
  # in the `programs.nixvim.extraConfigLua` section or `plugins.avante.settings.extraConfig`.


  # 3.8. Git (Shell shortcuts)
  { mode = "n"; key = "gp"; action = ":!gp<cr>"; options.desc = "Git Push (Shell)"; }
  { mode = "n"; key = "gn"; action = ":!gn "; options.desc = "Git New Branch (Shell)"; }
  { mode = "n"; key = "gt"; action = ":!gt "; options.desc = "Git Tag (Shell)"; }
  { mode = "n"; key = "gl"; action = ":!gpl<cr>"; options.desc = "Git Pull (Shell)"; }
  { mode = "n"; key = "gr"; action = ":!grsh<cr>"; options.desc = "Git Rebase Stash (Shell)"; }

  # 3.9. Lazy/Packer (Update)
  {
    mode = "n";
    key = "<F1>";
    action = ":Lazy update<cr>";
    options.desc = "Lazy Update";
  }
]
