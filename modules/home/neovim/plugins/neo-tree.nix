{
  # Laisser le reste à la configuration par défaut de Neo-tree

  filesystem = {
    window = {
      # Ces mappings sont pour les actions principales dans la fenêtre Neo-tree (Filesystem Source).
      mappings = {
        # Ouvre/Ferme les nœuds. Correspond au comportement VIM standard (h/l) dans un explorateur.
        "h" = "close_node"; # ⬅️ Similaire à se déplacer vers la gauche / fermer le répertoire
        "l" = "open";       # ➡️ Similaire à se déplacer vers la droite / ouvrir le fichier ou le répertoire

        # Le reste utilise les actions par défaut de Neo-tree (qui sont souvent déjà VIM-like).
        
        # Mouvements de base (j/k) sont implicitement gardés si non surchargés, mais on peut les confirmer:
        "j" = "move_cursor_down";
        "k" = "move_cursor_up";
        
        # Actions courantes que vous avez peut-être dans un explorateur :
        "<cr>" = "open"; 
        
        # Aller au répertoire parent (Back)
        "<bs>" = "navigate_up"; 
        
        # Aller à la racine du projet
        "." = "set_root";
        
        # Toggle les fichiers cachés
        "H" = "toggle_hidden"; 
      };
    };
  };

  # Pour la source Buffers si vous l'activez:
  buffers = {
    window = {
      mappings = {
        "j" = "move_cursor_down";
        "k" = "move_cursor_up";
        "l" = "open";
      };
    };
  };
  
  # Assurez-vous que l'option de fermer si c'est la dernière fenêtre est là pour la commodité.
  close_if_last_window = true;
}
