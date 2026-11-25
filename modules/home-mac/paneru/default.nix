{ pkgs, lib, ... }:
let
  # Paneru = le WM macOS le plus proche de niri (bande horizontale infinie,
  # colonnes, workspaces verticaux). Cette conf est le miroir de
  # modules/home/niri/default.nix (niri, côté Linux) : memes gestes, memes
  # largeurs, memes regles. Mod de niri (= Super) devient Cmd sur macOS.
  #
  # Ecart assume : les raccourcis macOS pris par les apps (Cmd+V coller,
  # Cmd+F chercher, Cmd+Q quitter) ne sont PAS detournes ; les commandes
  # niri correspondantes sont posees sur Cmd+Shift ou Option.
  initLua = pkgs.writeText "paneru-init.lua" ''
    -- Paneru : miroir de la conf niri de marc (~/git/nixos/modules/home/niri).
    local HOME = os.getenv("HOME")

    local function sh(cmd)
      os.execute(cmd .. " >/dev/null 2>&1 &")
    end

    paneru.setup {
      options = {
        -- niri: input.focus-follows-mouse.enable = true
        focus_follows_mouse = true,
        -- niri ne teleporte pas le curseur au changement de focus
        mouse_follows_focus = false,
        -- niri: defilement anime (bande de 8 a 20)
        animation_speed = 12.0,
        auto_center = false,
        window_resize_cycle = true,
        -- niri supprime les workspaces vides
        reap_empty_workspaces = true,
        insert_windows_mid_strip = false,
        -- niri: layout.default-column-width.proportion = 0.5
        preset_column_widths = { 0.3333, 0.5, 0.6667, 1.0, 1.5, 2.0 },
        sliver_width = 5,
        sliver_height = 1.0,
        window_hidden_ratio = 0.0,
      },
      -- niri: pas de gaps (layout sans padding)
      padding = { top = 0, bottom = 0, left = 0, right = 0 },
      swipe = {
        sensitivity = 0.4,
        continuous = true,
        -- geste 3 doigts : horizontal = bande, vertical = workspaces
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
        -- niri: Alacritty open-maximized. `manage = true` est indispensable :
        -- sans lui Paneru ignore les fenetres Alacritty (app vue comme
        -- inobservable), mesure 13/11/2026. Regle declarative, pas de hook Lua.
        alacritty = { title = ".*", bundle_id = "org.alacritty", manage = true, width = 1.0 },
        dialogs = { title = ".*", subrole = "AXDialog", floating = true },
        floating_window = { title = ".*", subrole = "AXFloatingWindow", floating = true },
      },
    }

    -- --- Navigation : niri Mod+H / Mod+L / fleches ---
    paneru.bind("cmd - h", "window focus west")
    paneru.bind("cmd - l", "window focus east")
    paneru.bind("cmd - leftarrow", "window focus west")
    paneru.bind("cmd - rightarrow", "window focus east")
    paneru.bind("cmd - uparrow", "window focus north")
    paneru.bind("cmd - downarrow", "window focus south")

    -- --- Workspaces verticaux : niri Mod+J / Mod+K ---
    paneru.bind("cmd - j", "window virtual south")
    paneru.bind("cmd - k", "window virtual north")

    -- --- Colonnes ---
    paneru.bind("cmd - m", "window fullwidth")   -- niri Mod+M maximize-column
    paneru.bind("cmd - t", "window resize")      -- niri Mod+T set-column-width 50%
    paneru.bind("cmd - y", "window shrink")      -- niri Mod+Y set-column-width 33%
    paneru.bind("cmd - minus", "window shrink")
    paneru.bind("cmd - equal", "window resize")
    paneru.bind("cmd + shift - v", "window manage")   -- niri Mod+V floating (Cmd+V = coller)

    -- --- Deplacement de fenetres (habitude AeroSpace) ---
    paneru.bind("cmd + shift - h", "window swap west")
    paneru.bind("cmd + shift - l", "window swap east")
    paneru.bind("cmd + shift - j", "window swap south")
    paneru.bind("cmd + shift - k", "window swap north")

    -- --- Applications ---
    paneru.bind("cmd - return", function() sh("open -a Alacritty") end)      -- niri Mod+Return
    paneru.bind("alt - f", function() sh("open -a LibreWolf") end)          -- niri Mod+F (Cmd+F = chercher)
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

    -- --- Workspaces numerotes : niri Mod+1..9 / Alt+1..9 ---
    for i = 1, 9 do
      paneru.bind("cmd - " .. i, "window virtualnum " .. i)
      paneru.bind("alt + shift - " .. i, "window virtualmovenum " .. i)
    end
  '';
in
{
  xdg.configFile."paneru/init.lua".source = initLua;
}
