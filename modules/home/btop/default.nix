# btop: Catppuccin Mocha themed TUI (Lavender accent) opened on the
# CPU ranking of processes.
#
# Why btop in addition to htop: htop does NOT know how to take arbitrary
# colors (only its internal schemes 0 to 6, which inherit from the terminal's
# ANSI palette). btop reads a real 24-bit theme file, so it is
# the only one of the three able to carry the exact mocha with the lavender accent.
# atop, for its part, has no theme system (colors hardcoded in the binary).
#
# This module writes two files into ~/.config/btop:
#   btop.conf                        the conf, "cpu" + "proc" boxes only
#   themes/catppuccin_mocha.theme    the mocha palette, lavender accent
{
  xdg.configFile = {
    # force = true: replaces a hand-edited btop.conf. The link points
    # into the store, so btop can no longer write to it (save_config_on_exit is
    # disabled in the conf to avoid the warning on exit).
    "btop/btop.conf" = {
      source = ./btop.conf;
      force = true;
    };
    "btop/themes/catppuccin_mocha.theme" = {
      source = ./themes/catppuccin_mocha.theme;
      force = true;
    };
  };
}
