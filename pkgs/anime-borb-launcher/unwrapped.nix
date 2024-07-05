{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
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
    pname = "anime-borb-launcher";
    version = "1.0.1+WP1UGi2ZnP";

    src = fetchFromGitHub {
      owner = "an-anime-team";
      repo = "an-anime-borb-launcher";
      rev = version;
      sha256 = "sha256-dT1dA22gMPw7H353+zeu2Y+pHD0Qgs98ZolqJ7zzIeQ=";
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
