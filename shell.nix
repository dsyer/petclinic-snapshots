with import <nixpkgs> { };
pkgs.mkShell {
  name = "buildroot";
  buildInputs = [ cvs gcc git autoconf mercurial ncurses rsync subversion texinfo figlet ];
  shellHook = ''
    figlet ":buildroot:"
    echo
  '';
}
