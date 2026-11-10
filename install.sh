#!/usr/bin/env bash
# post-install.sh: пост-установка Arch (niri + базовый харденинг)
# Запуск: от обычного пользователя (не root), после первой загрузки, с сетью.
#   ./post-install.sh              # все модули по порядку
#   ./post-install.sh sysctl dns   # только выбранные
# Модули: pkgs niri apparmor sysctl misc snapper flatpak firewall dns
set -euo pipefail

LOG="$HOME/post-install.log"
exec > >(tee -a "$LOG") 2>&1

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

# put /путь: пишет stdin в файл от root, старую версию сохраняет как .bak.<время>
put() {
  local dst=$1
  sudo install -d "$(dirname "$dst")"
  if [[ -f $dst ]]; then
    sudo cp -a "$dst" "$dst.bak.$(date +%s)"
  fi
  sudo tee "$dst" >/dev/null
}

[[ $EUID -ne 0 ]] || die "Запускайте от обычного пользователя, не от root."
command -v pacman >/dev/null || die "Это не Arch."
curl -fsS --max-time 8 -o /dev/null https://archlinux.org || die "Нет сети."
sudo -v

PKGS=(
  niri xwayland-satellite xdg-desktop-portal-gnome xdg-desktop-portal-gtk
  gnome-keyring polkit-gnome alacritty fuzzel waybar mako swaylock swayidle
  swaybg wl-clipboard brightnessctl noto-fonts noto-fonts-emoji ttf-dejavu
  nftables apparmor sbctl tpm2-tss snapper snap-pac btrfs-progs
  pacman-contrib arch-audit flatpak firefox git nano man-db man-pages
)

mod_pkgs() {
  sudo pacman -Syu --needed --noconfirm "${PKGS[@]}"
  warn "Драйвер видео (mesa/vulkan-*/nvidia-open) скрипт не ставит: сделайте вручную."
}

mod_niri() {
  local cfgdir="$HOME/.config/niri" cfg="$HOME/.config/niri/config.kdl"
  local src=/usr/share/doc/niri/default-config.kdl
  local polkit=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
  mkdir -p "$cfgdir"

  if [[ ! -f $cfg ]]; then
    if [[ -f $src ]]; then
      cp "$src" "$cfg"
    else
      warn "Дефолтный конфиг не найден ($src). Запустите niri один раз, он создаст свой, и повторите: ./post-install.sh niri"
    fi
  fi

  if [[ -f $cfg ]] && ! grep -qF '# >>> post-install.sh >>>' "$cfg"; then
    {
      echo
      echo '# >>> post-install.sh >>>'
      grep -q '^spawn-at-startup "waybar"' "$cfg" || echo 'spawn-at-startup "waybar"'
      grep -q '^spawn-at-startup "mako"'   "$cfg" || echo 'spawn-at-startup "mako"'
      if [[ -x $polkit ]] && ! grep -q 'polkit-gnome-authentication' "$cfg"; then
        echo "spawn-at-startup \"$polkit\""
      fi
      echo 'spawn-at-startup "swayidle" "-w" "timeout" "300" "swaylock -f" "timeout" "600" "niri msg action power-off-monitors" "before-sleep" "swaylock -f"'
      echo '# <<< post-install.sh <<<'
    } >>"$cfg"
  fi

  # Фрагменты, которые надо вставить вручную (дубли секций input/binds ломают конфиг)
  cat >"$cfgdir/snippets-to-paste.kdl" <<'EOF'
// Внутрь существующего блока input { keyboard { ... } }:
//     xkb {
//         layout "us,ru"
//         options "grp:alt_shift_toggle"
//     }
//
// Внутрь существующего блока binds { ... }:
//     Mod+Alt+L { spawn "swaylock"; }
EOF

  if [[ -f $cfg ]]; then
    niri validate && echo "Конфиг niri валиден." || warn "niri validate нашёл ошибки: проверьте $cfg"
  fi

  # Автозапуск niri с TTY1 + umask
  if ! grep -qF '# >>> post-install.sh >>>' "$HOME/.bash_profile" 2>/dev/null; then
    cat >>"$HOME/.bash_profile" <<'EOF'

# >>> post-install.sh >>>
umask 077
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ]; then
    exec niri-session
fi
# <<< post-install.sh <<<
EOF
  fi
  echo "Фрагменты для ручной вставки: $cfgdir/snippets-to-paste.kdl"
  echo "Если niri не стартует, переключитесь на TTY2 (Ctrl+Alt+F2) и чините конфиг."
}

mod_apparmor() {
  sudo systemctl enable --now apparmor.service
  if grep -q apparmor /sys/kernel/security/lsm 2>/dev/null; then
    echo "AppArmor активен в ядре."
  else
    warn "AppArmor НЕ активен в ядре. Добавьте в командную строку ядра:"
    warn "  lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
    warn "(для UKI это /etc/kernel/cmdline + mkinitcpio -P + sbctl sign-all; для systemd-boot без UKI: файл в /boot/loader/entries/)"
  fi
}

mod_sysctl() {
  put /etc/sysctl.d/99-hardening.conf <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.yama.ptrace_scope = 1
kernel.sysrq = 0
kernel.perf_event_paranoid = 2
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
EOF
  sudo sysctl --system >/dev/null
  echo "sysctl применён."
}

mod_misc() {
  put /etc/systemd/coredump.conf.d/disable.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  chmod 700 "$HOME"
  sudo passwd -l root >/dev/null && echo "root заблокирован."
  sudo systemctl enable --now paccache.timer
}

mod_snapper() {
  if [[ $(findmnt -no FSTYPE /) != btrfs ]]; then
    warn "Корень не btrfs, snapper пропущен."
    return
  fi
  if sudo snapper list-configs | grep -q '^root'; then
    echo "Конфиг snapper для root уже есть."
  else
    if findmnt -n /.snapshots >/dev/null; then
      # подтом @.snapshots от archinstall мешает create-config
      sudo umount /.snapshots
      sudo rm -r /.snapshots
      sudo snapper -c root create-config /
      sudo btrfs subvolume delete /.snapshots
      sudo mkdir /.snapshots
      sudo mount -a
      findmnt -n /.snapshots >/dev/null || warn "/.snapshots не смонтирован: проверьте /etc/fstab"
    else
      sudo snapper -c root create-config /
    fi
    sudo chmod 750 /.snapshots
    sudo snapper -c root set-config \
      TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 \
      TIMELINE_LIMIT_WEEKLY=0 TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0
  fi
  sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
  warn "ESP/ядро в снимки не входит: после отката корня выполните mkinitcpio -P && sbctl sign-all."
}

mod_flatpak() {
  sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  sudo flatpak install -y --noninteractive flathub com.github.tchx84.Flatseal
  echo "Права приложений урезайте так:"
  echo "  flatpak override --user --nosocket=x11 --nosocket=fallback-x11 --nofilesystem=home ID"
}

mod_firewall() {
  local tmp; tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
#!/usr/bin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state invalid drop
        ct state { established, related } accept
        iif "lo" accept
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept
        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
  sudo nft -c -f "$tmp" || { rm -f "$tmp"; die "Правила nftables не прошли проверку."; }
  put /etc/nftables.conf <"$tmp"
  rm -f "$tmp"
  sudo systemctl enable nftables.service
  sudo systemctl restart nftables.service
  warn "flush ruleset сломает правила Docker/Podman/libvirt, если будете их ставить."
}

mod_dns() {
  put /etc/NetworkManager/conf.d/dns.conf <<'EOF'
[main]
dns=systemd-resolved
EOF
  put /etc/NetworkManager/conf.d/00-privacy.conf <<'EOF'
[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=stable
EOF
  put /etc/systemd/resolved.conf.d/dot.conf <<'EOF'
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF
  sudo systemctl enable --now systemd-resolved
  sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  sudo systemctl restart systemd-resolved NetworkManager
  sleep 5
  resolvectl status | head -n 15 || true
  warn "Если не открывается вход в публичный Wi-Fi, поставьте DNSOverTLS=opportunistic в /etc/systemd/resolved.conf.d/dot.conf."
}

# dns последним: перезапуск NetworkManager может на секунды оборвать сеть
ALL=(pkgs niri apparmor sysctl misc snapper flatpak firewall dns)

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  sed -n '2,6p' "$0"; exit 0
fi

if [[ $# -eq 0 ]]; then mods=("${ALL[@]}"); else mods=("$@"); fi

for m in "${mods[@]}"; do
  declare -F "mod_$m" >/dev/null || die "Неизвестный модуль: $m (есть: ${ALL[*]})"
  log "Модуль: $m"
  "mod_$m"
done

log "Готово. Лог: $LOG"
cat <<'EOF'
Дальше вручную:
  1. Вставить фрагменты из ~/.config/niri/snippets-to-paste.kdl (раскладка us,ru).
  2. Этап 6 из гайда: UKI, Secure Boot (sbctl), TPM2 + PIN.
  3. Перезагрузиться и проверить: aa-status, nft list ruleset, resolvectl status, snapper list.
EOF
