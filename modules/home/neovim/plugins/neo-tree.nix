{
  # Leave the rest to Neo-tree's default configuration

  filesystem = {
    window = {
      # These mappings are for the main actions in the Neo-tree window (Filesystem Source).
      mappings = {
        # Open/Close nodes. Corresponds to the standard VIM behavior (h/l) in an explorer.
        "h" = "close_node"; # -> Similar to moving left / closing the directory
        "l" = "open";       # -> Similar to moving right / opening the file or directory

        # The rest uses Neo-tree's default actions (which are often already VIM-like).
        
        # Basic movements (j/k) are implicitly kept if not overridden, but we can confirm them:
        "j" = "move_cursor_down";
        "k" = "move_cursor_up";
        
        # Common actions you may have in an explorer:
        "<cr>" = "open"; 
        
        # Go to the parent directory (Back)
        "<bs>" = "navigate_up"; 
        
        # Go to the project root
        "." = "set_root";
        
        # Toggle hidden files
        "H" = "toggle_hidden"; 
      };
    };
  };

  # For the Buffers source if you enable it:
  buffers = {
    window = {
      mappings = {
        "j" = "move_cursor_down";
        "k" = "move_cursor_up";
        "l" = "open";
      };
    };
  };
  
  # Make sure the close-if-last-window option is there for convenience.
  close_if_last_window = true;
}
