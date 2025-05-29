{ pkgs }: {
  deps = [
    pkgs.ruby_3_2
    pkgs.rubyPackages_3_2.puma
    pkgs.rubyPackages_3_2.sinatra
    pkgs.rubyPackages_3_2.bundler
    pkgs.glibc
    pkgs.glibc.locales
  ];
  env = {
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
    RUBYOPT = "-E UTF-8:UTF-8";
  };
}
