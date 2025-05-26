{ pkgs }: {
  deps = [
    pkgs.ruby_3_2
    pkgs.rubyPackages_3_2.puma
    pkgs.rubyPackages_3_2.sinatra
  ];
}
