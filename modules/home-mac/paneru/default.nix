{ pkgs, lib, ... }:
let
  # Paneru = the macOS WM closest to niri (infinite horizontal strip,
  # columns, vertical workspaces). This config is the mirror of
  # modules/home/niri/default.nix (niri, on the Linux side): same gestures, same
  # widths, same rules. niri's Mod (= Super) becomes Cmd on macOS.
  #
  # Assumed deviation: the macOS shortcuts taken by apps (Cmd+V paste,
  # Cmd+F find, Cmd+Q quit) are NOT hijacked; the corresponding
  # niri commands are placed on Cmd+Shift or Option.
  initLua = pkgs.writeText "paneru-init.lua" ''
    -- Paneru: mirror of marc's niri config (~/git/nixos/modules/home/niri).
    local HOME = os.getenv("HOME")

    local function sh(cmd)
      os.execute(cmd .. " >/dev/null 2>&1 &")
    end

    paneru.setup {
      options = {
        -- niri: input.focus-follows-mouse.enable = true
        focus_follows_mouse = true,
        -- niri does not teleport the cursor on focus change
        mouse_follows_focus = false,
        -- niri: animated scrolling (strip from 8 to 20)
        animation_speed = 12.0,
        auto_center = false,
        window_resize_cycle = true,
        -- niri removes empty workspaces
        reap_empty_workspaces = true,
        insert_windows_mid_strip = false,
        -- niri: layout.default-column-width.proportion = 0.5
        preset_column_widths = { 0.3333, 0.5, 0.6667, 1.0, 1.5, 2.0 },
        sliver_width = 5,
        sliver_height = 1.0,
        window_hidden_ratio = 0.0,
      },
      -- niri: no gaps (layout without padding)
      padding = { top = 0, bottom = 0, left = 0, right = 0 },
      swipe = {
        sensitivity = 0.4,
        continuous = true,
        -- 3-finger gesture: horizontal = strip, vertical = workspaces
        gesture = {
          fingers_count = 3,
          direction = "Natural",
          vertical = true,
          paging = false,
          haptics = true,
        },
        scroll = { modifier = "alt", window_step = false },
      },
      decorations = {
        -- niri: layout.focus-ring.enable = false
        active = { border = { enabled = false } },
        menu = {
          colors = { "#b4befe" },
          indicator = { style = "mono", format = "default", font_size = 13.0 },
        },
      },
      restore = { enabled = true, startup_grace_ms = 3000 },
      windows = {
        -- niri: Alacritty open-maximized. `manage = true` is essential:
        -- without it Paneru ignores Alacritty windows (app seen as
        -- unobservable), measured 13/11/2026. Declarative rule, no Lua hook.
        alacritty = { title = ".*", bundle_id = "org.alacritty", manage = true, width = 1.0 },
        dialogs = { title = ".*", subrole = "AXDialog", floating = true },
        floating_window = { title = ".*", subrole = "AXFloatingWindow", floating = true },
      },
    }

    -- --- Navigation: niri Mod+H / Mod+L / arrows ---
    paneru.bind("cmd - h", "window focus west")
    paneru.bind("cmd - l", "window focus east")
    paneru.bind("cmd - leftarrow", "window focus west")
    paneru.bind("cmd - rightarrow", "window focus east")
    paneru.bind("cmd - uparrow", "window focus north")
    paneru.bind("cmd - downarrow", "window focus south")

    -- --- Vertical workspaces: niri Mod+J / Mod+K ---
    paneru.bind("cmd - j", "window virtual south")
    paneru.bind("cmd - k", "window virtual north")

    -- --- Columns ---
    paneru.bind("cmd - m", "window fullwidth")   -- niri Mod+M maximize-column
    paneru.bind("cmd - t", "window resize")      -- niri Mod+T set-column-width 50%
    paneru.bind("cmd - y", "window shrink")      -- niri Mod+Y set-column-width 33%
    paneru.bind("cmd - minus", "window shrink")
    paneru.bind("cmd - equal", "window resize")
    paneru.bind("cmd + shift - v", "window manage")   -- niri Mod+V floating (Cmd+V = paste)

    -- --- Window movement (AeroSpace habit) ---
    paneru.bind("cmd + shift - h", "window swap west")
    paneru.bind("cmd + shift - l", "window swap east")
    paneru.bind("cmd + shift - j", "window swap south")
    paneru.bind("cmd + shift - k", "window swap north")

    -- --- Applications ---
    paneru.bind("cmd - return", function() sh("open -a Alacritty") end)      -- niri Mod+Return
    paneru.bind("alt - f", function() sh("open -a LibreWolf") end)          -- niri Mod+F (Cmd+F = find)
    paneru.bind("alt - l", function() sh("open -a Finder " .. HOME) end)     -- niri Alt+L nautilus
    paneru.bind("cmd + shift - s", function()                                -- niri Print
      sh("mkdir -p " .. HOME .. "/media/screenshots && screencapture -i " ..
         HOME .. "/media/screenshots/$(date +%Y-%m-%d_%H-%M-%S).png")
    end)
    paneru.bind("cmd + shift - m", function() sh([[open -a "Mission Control"]]) end)

    -- --- Spotify : niri Alt+D / Alt+S / Alt+K ---
    paneru.bind("alt - d", function() sh([[osascript -e 'tell application "Spotify" to next track']]) end)
    paneru.bind("alt - s", function() sh([[osascript -e 'tell application "Spotify" to previous track']]) end)
    paneru.bind("alt - k", function() sh([[osascript -e 'tell application "Spotify" to playpause']]) end)

    -- --- Numbered workspaces: niri Mod+1..9 / Alt+1..9 ---
    for i = 1, 9 do
      paneru.bind("cmd - " .. i, "window virtualnum " .. i)
      paneru.bind("alt + shift - " .. i, "window virtualmovenum " .. i)
    end
  '';
in
{
  xdg.configFile."paneru/init.lua".source = initLua;
}
