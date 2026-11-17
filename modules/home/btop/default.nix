# btop : TUI themee Catppuccin Mocha (accent Lavender) ouverte sur le
# classement CPU des process.
#
# Pourquoi btop en plus de htop : htop ne sait PAS prendre des couleurs
# arbitraires (seulement ses schemes internes 0 a 6, qui heritent du palette
# ANSI du terminal). btop lit un vrai fichier de theme en 24 bits, donc il est
# le seul des trois a pouvoir porter le mocha exact avec l'accent lavender.
# atop, lui, n'a aucun systeme de theme (couleurs figees dans le binaire).
#
# Ce module ecrit deux fichiers dans ~/.config/btop :
#   btop.conf                        la conf, boites "cpu" + "proc" seulement
#   themes/catppuccin_mocha.theme    le palette mocha, accent lavender
{
  xdg.configFile = {
    # force = true : remplace un btop.conf edite a la main. Le lien pointe
    # dans le store, donc btop ne peut plus y ecrire (save_config_on_exit est
    # desactive dans la conf pour eviter l'avertissement en sortie).
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
