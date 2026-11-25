// Plasma panel layout for the remote desktop (kasm.marcpartensky.com).
//
// Base: share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel from
// plasma-desktop 6.6.6. Two deliberate deviations from upstream:
//   1. the panel is forced to the bottom whereas upstream lets ShellCorona
//      choose an available edge (in practice the bottom, but not guaranteed);
//   2. the task manager pins konsole and LibreWolf, so that they
//      launch in ONE click from the panel and not only via the menu.
//
// This file is loaded by plasmashell on the FIRST start of a session,
// when no ~/.config/plasma-org.kde.plasma.desktop-appletsrc exists. An
// appletsrc already present (marc may have already launched Plasma on tower) is NOT
// overwritten: that is intended, we do not destroy a user setting.

var panel = new Panel
panel.location = "bottom"

// Height: *2 is too small, *3 too big (upstream's computation, rounded to the
// next even number: the panel size widget only shows even numbers).
panel.height = 2 * Math.ceil(gridUnit * 2.5 / 2)

// On an ultra-wide screen, the panel does not span the full width.
var panelScreen = panel.screen
const maximumAspectRatio = 21 / 9;
if (panel.formFactor === "horizontal") {
    const geo = screenGeometry(panelScreen);
    const maximumWidth = Math.ceil(geo.height * maximumAspectRatio);
    if (geo.width > maximumWidth) {
        panel.alignment = "center";
        panel.minimumLength = maximumWidth;
        panel.maximumLength = maximumWidth;
    }
}

panel.addWidget("org.kde.plasma.kickoff")
panel.addWidget("org.kde.plasma.icontasks")
panel.addWidget("org.kde.plasma.marginsseparator")
panel.addWidget("org.kde.plasma.systemtray")
panel.addWidget("org.kde.plasma.digitalclock")
panel.addWidget("org.kde.plasma.showdesktop")

// Pinning the launchers in the task manager.
//
// .desktop ids VERIFIED in the store: KDE 6's terminal is called
// org.kde.konsole.desktop (not konsole.desktop) and LibreWolf librewolf.desktop.
// A nonexistent id is simply ignored by the applet.
//
// try/catch mandatory: an uncaught exception would make the WHOLE
// layout script fail, hence a session with no panel at all. Pinning is a
// convenience, the panel is essential.
try {
    var tasks = panel.widgets("org.kde.plasma.icontasks")
    if (tasks.length > 0) {
        tasks[0].currentConfigGroup = ["General"]
        tasks[0].writeConfig("launchers", "applications:org.kde.konsole.desktop,applications:librewolf.desktop")
    }
} catch (e) {
    print("kasmvnc-plasma: launcher pinning failed (" + e + ")")
}

var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
}
