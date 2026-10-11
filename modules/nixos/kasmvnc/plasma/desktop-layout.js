// Layout de la barre Plasma du bureau distant (kasm.marcpartensky.com).
//
// Base : share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel de
// plasma-desktop 6.6.6. Deux ecarts volontaires par rapport a l'upstream :
//   1. la barre est forcee en bas alors que l'upstream laisse ShellCorona
//      choisir un bord disponible (en pratique le bas, mais pas garanti) ;
//   2. le gestionnaire de taches epingle konsole et LibreWolf, pour qu'ils se
//      lancent en UN clic depuis la barre et pas seulement via le menu.
//
// Ce fichier est charge par plasmashell au PREMIER demarrage d'une session,
// quand aucun ~/.config/plasma-org.kde.plasma.desktop-appletsrc n'existe. Un
// appletsrc deja present (marc aurait deja lance Plasma sur tower) n'est PAS
// ecrase : c'est voulu, on ne detruit pas un reglage utilisateur.

var panel = new Panel
panel.location = "bottom"

// Hauteur : *2 est trop petit, *3 trop grand (calcul de l'upstream, arrondi au
// nombre pair suivant : le widget de taille de barre n'affiche que des pairs).
panel.height = 2 * Math.ceil(gridUnit * 2.5 / 2)

// Sur un ecran ultra-large, la barre ne s'etale pas sur toute la largeur.
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

// Epinglage des lanceurs dans le gestionnaire de taches.
//
// Ids de .desktop VERIFIES dans le store : le terminal de KDE 6 s'appelle
// org.kde.konsole.desktop (pas konsole.desktop) et LibreWolf librewolf.desktop.
// Un id inexistant est simplement ignore par l'applet.
//
// try/catch obligatoire : une exception non rattrapee ferait echouer TOUT le
// script de layout, donc une session sans barre du tout. L'epinglage est un
// confort, la barre est l'essentiel.
try {
    var tasks = panel.widgets("org.kde.plasma.icontasks")
    if (tasks.length > 0) {
        tasks[0].currentConfigGroup = ["General"]
        tasks[0].writeConfig("launchers", "applications:org.kde.konsole.desktop,applications:librewolf.desktop")
    }
} catch (e) {
    print("kasmvnc-plasma: epinglage des lanceurs impossible (" + e + ")")
}

var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    desktopsArray[j].wallpaperPlugin = 'org.kde.image';
}
