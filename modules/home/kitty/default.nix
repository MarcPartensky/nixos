{...}: {
  programs.kitty = {
    enable = true;

    font = {
      name = "JetBrainsMono Nerd Font";
      size = 12;
    };

    settings = {
      background = "#262624";
      foreground = "#d8d6d1";

      cursor = "#d97757";
      cursor_text_color = "#262624";

      selection_background = "#3a3936";
      selection_foreground = "#d8d6d1";

      url_color = "#d97757";

      background_opacity = "1.0";
      window_padding_width = 8;
      confirm_os_window_close = 0;
    };
  };
}
