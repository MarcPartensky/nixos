[
  # ==============================
  # 1. MAPPINGS GLOBALES ET SYSTÈME
  # ==============================

  # Enregistrer le fichier (Ctrl+s)
  {
    mode = "n";
    key = "<C-s>";
    action = ":w<cr>";
    options.desc = "Save File";
  }

  # Sélectionner tout (Ctrl+a)
  {
    mode = "n";
    key = "<C-a>";
    action = "ggVG";
    options.desc = "Select All";
  }

  # Fermer toutes les fenêtres/buffers (Ctrl+w - remappé ici pour la fermeture de Neovim)
  {
    mode = "n";
    key = "<C-w>";
    action = ":qa<cr>";
    options.desc = "Quit All (Neovim)";
  }

  # Lancer 'make' (Ctrl+m)
  {
    mode = "n";
    key = "<C-m>";
    # Note : jobstart est mieux géré directement dans Lua ou en utilisant ToggleTerm
    action = ":call jobstart(['alacritty', '-e', 'make'])<CR>";
    options.desc = "Run Make in Alacritty";
  }

  # Exécuter le fichier courant (Ctrl+i)
  {
    mode = "n";
    key = "<C-i>";
    action = ":!$PWD/%<cr>";
    options.desc = "Execute Current File";
  }

  # ==============================
  # 2. GESTION DES FENÊTRES (SPLIT)
  # ==============================

  # Naviguer entre les splits (Ctrl+h/j/k/l)
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
  # 3. MAPPINGS PLUGINS DE BASE
  # ==============================

  # 3.1. Telescope (Recherche de fichiers)
  {
    mode = "n";
    key = "<C-p>";
    action = "<cmd>Telescope find_files<cr>";
    options.desc = "Telescope Find Files (Ctrl+p)";
  }

  # 3.2. Neo-tree (Explorateur de fichiers)
  {
    mode = "n";
    key = "<C-o>";
    action = ":Neotree toggle<cr>";
    options.desc = "Toggle Neo-tree (Ctrl+o)";
  }

  # 3.3. Comment.nvim (Commentaire)
  # Pour Neovim (nixvim), la meilleure façon de mapper C-/ pour Comment.nvim
  # est souvent d'utiliser directement l'appel Lua ou le mapping par défaut 'gc'.
  # Utiliser <Plug>(...):
  {
    mode = ["n" "v"];
    key = "<C-/>";
    action = "<Plug>(comment_toggle)";
    options.desc = "Toggle Comment (Ctrl+/)";
  }
  # Note : Si <Plug> ne fonctionne pas pour le mode visuel, vous devrez
  # probablement utiliser la commande spécifique pour le mode visuel ou 'gc'.
  # Le mapping "v" pour "gc" est déjà fait ci-dessous.

  # Mapping spécifique pour le mode visuel (gc)
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

  # 3.5. BufferLine (Navigation par onglets)
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

  # 3.7. Avante (Chat/IA)
  # Le mapping en mode visuel pour Avante.
  {
    mode = "v";
    key = "<C-;>";
    action = ":AvanteToggle<cr>";
    options.desc = "Avante: Toggle My Prompt (Visual)";
  }
  # Remarque : Votre autocommande pour `avante.config` doit être placée
  # dans la section `programs.nixvim.extraConfigLua` ou `plugins.avante.settings.extraConfig`.


  # 3.8. Git (Raccourcis shell)
  { mode = "n"; key = "gp"; action = ":!gp<cr>"; options.desc = "Git Push (Shell)"; }
  { mode = "n"; key = "gn"; action = ":!gn "; options.desc = "Git New Branch (Shell)"; }
  { mode = "n"; key = "gt"; action = ":!gt "; options.desc = "Git Tag (Shell)"; }
  { mode = "n"; key = "gl"; action = ":!gpl<cr>"; options.desc = "Git Pull (Shell)"; }
  { mode = "n"; key = "gr"; action = ":!grsh<cr>"; options.desc = "Git Rebase Stash (Shell)"; }

  # 3.9. Lazy/Packer (Mise à jour)
  {
    mode = "n";
    key = "<F1>";
    action = ":Lazy update<cr>";
    options.desc = "Lazy Update";
  }
]
