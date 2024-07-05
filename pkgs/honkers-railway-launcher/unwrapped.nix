{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  openssl,
  glib,
  pango,
  gdk-pixbuf,
  gtk4,
  libadwaita,
  gobject-introspection,
  gsettings-desktop-schemas,
  wrapGAppsHook4,
  librsvg,
  customIcon ? null,
}:
with lib;
  rustPlatform.buildRustPackage rec {
    pname = "honkers-railway-launcher";
    version = "1.6.1+vazDByO7d3";

    src = fetchFromGitHub {
      owner = "an-anime-team";
      repo = "the-honkers-railway-launcher";
      rev = version;
      sha256 = "sha256-ah4h6SX2ALJFxWJlIm8GNiAN3MuANTnBJkS4tbketdo=";
      fetchSubmodules = true;
    };

    patches = [./sdk.patch];
    patchFlags = ["-p4"];

    prePatch = optionalString (customIcon != null) ''
      rm assets/images/icon.png
      cp ${customIcon} assets/images/icon.png
    '';

    cargoLock = {
      lockFile = ./Cargo.lock;
      outputHashes = {
        "anime-game-core-1.21.1" = "sha256-8s9c7DkNObOPyyCrezBz6HORzjWasmSI8/KJ2QYhCLk=";
        "anime-launcher-sdk-1.16.2" = "sha256-4pQ5PRQbSBCTktnw1/l5zvgUJoamjmRh/xsgk96hfmw=";
      };
    };

    nativeBuildInputs = [
      cmake
      glib
      gobject-introspection
      gtk4
      pkg-config
      wrapGAppsHook4
    ];

    buildInputs = [
      gdk-pixbuf
      gsettings-desktop-schemas
      libadwaita
      librsvg
      openssl
      pango
    ];

    passthru = {inherit customIcon;};
  }
