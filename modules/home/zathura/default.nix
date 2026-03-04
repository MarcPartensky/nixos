{pkgs, ...}: {
  programs.zathura = {
    enable = true;

    package = pkgs.zathura.override {
      plugins = with pkgs.zathuraPkgs; [
        zathura_pdf_poppler
        zathura_pdf_mupdf
        # zathura_core
        zathura_ps
      ];
    };

    options = {
      selection-clipboard = "clipboard";
      recolor = true;
      recolor-keephue = true;
    };
  };
}
