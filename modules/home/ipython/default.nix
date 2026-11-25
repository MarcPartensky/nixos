{ ... }:

{
  programs.ipython = {
    enable = true;

    # Default profile (profile_default)
    profiles.default = {
      startupBanner = false;   # <- removes the welcome message
    };
  };
  # Creation of the IPython configuration file
  xdg.configFile."ipython/profile_default/ipython_config.py".text = ''
    c = get_config()

    # Enable Vi editing mode
    c.TerminalInteractiveShell.editing_mode = 'vi'

    # Optionnel : sets the switch delay (escape time) 
    # for a faster transition between modes
    c.TerminalInteractiveShell.emacs_bindings_in_vi_insert_mode = False
  '';

  # # Optional: `py` launches IPython in silent mode
  # programs.zsh.aliases = {
  #   py = "ipython -q";
  # };
}

