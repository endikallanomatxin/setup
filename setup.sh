#!/usr/bin/env bash

# ——— Guardias de ejecución ———
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Este script está pensado para Bash. Ejecútalo así:  bash setup.sh  (no 'sh' ni 'zsh')." >&2
  return 1 2>/dev/null || exit 1
fi

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "No 'source' este script. Ejecútalo así:  bash setup.sh" >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

# ==============================================================================
# 0) DETECCIÓN DE DISTRO + ABSTRACCIÓN DE PAQUETES
# ==============================================================================
OS_ID=""
OS_LIKE=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_LIKE="${ID_LIKE:-}"
fi

is_ubuntu_like() { [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_LIKE" == *debian* ]]; }
is_fedora_like() { [[ "$OS_ID" == "fedora" || "$OS_LIKE" == *fedora* || "$OS_LIKE" == *rhel* ]]; }

if ! is_ubuntu_like && ! is_fedora_like; then
  echo "Distro no soportada (ID=$OS_ID ID_LIKE=$OS_LIKE). Solo Ubuntu/Debian y Fedora/RHEL-like." >&2
  exit 1
fi

PKG_MGR=""
if is_ubuntu_like; then PKG_MGR="apt"; else PKG_MGR="dnf"; fi

pkg_update() {
  if [ "$PKG_MGR" = "apt" ]; then
    sudo apt update -y
  else
    sudo dnf -y upgrade --refresh || true
    # Nota: dnf no necesita update separado; el refresh ya trae metadata.
  fi
}

pkg_upgrade() {
  if [ "$PKG_MGR" = "apt" ]; then
    sudo apt upgrade -y
  else
    sudo dnf -y upgrade
  fi
}

pkg_install() {
  if [ "$PKG_MGR" = "apt" ]; then
    sudo apt install -y "$@"
  else
    sudo dnf install -y "$@"
  fi
}

pkg_autoremove_clean() {
  if [ "$PKG_MGR" = "apt" ]; then
    sudo apt autoremove -y
    sudo apt clean
  else
    sudo dnf autoremove -y || true
    sudo dnf clean all -y || true
  fi
}

# ==============================================================================
# 1) RC ACCUMULATORS + HELPERS
# ==============================================================================
BASH_RC=''   # contenido para ~/.bashrc
ZSH_RC=''    # contenido para ~/.zshrc

append_bash() { local block; block="$(cat)"; BASH_RC+=$'\n'"$block"$'\n'; }
append_zsh()  { local block; block="$(cat)"; ZSH_RC+=$'\n'"$block"$'\n'; }
append_both() { local block; block="$(cat)"; BASH_RC+=$'\n'"$block"$'\n'; ZSH_RC+=$'\n'"$block"$'\n'; }

write_managed_block() {  # write_managed_block <file> <content>
  local file="$1" content="$2"
  local START="# >>> ENDIKA MANAGED START >>>"
  local END="# <<< ENDIKA MANAGED END <<<"
  touch "$file"
  awk -v s="$START" -v e="$END" '
    $0==s {inside=1; next}
    $0==e {inside=0; next}
    !inside {print}
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  {
    echo "$START"
    printf '%s\n' "$content" | sed '1{/^[[:space:]]*$/d};$ {/^[[:space:]]*$/d}'
    echo "$END"
  } >> "$file"
}

# Utils
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
nv_ver(){ nvim --version 2>/dev/null | sed -n '1{s/.*NVIM v//;s/ .*//;p}'; }
go_ver(){ go version 2>/dev/null | awk '{print $3}' | sed 's/^go//'; }
ts_ver(){ tree-sitter --version 2>/dev/null | awk '{print $2}'; }

ver_ge() { # ver_ge <a> <b>  (true si a >= b)
  # sort -V está en coreutils en Ubuntu y Fedora
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

has_schema() {
  command -v gsettings >/dev/null 2>&1 || return 1
  gsettings list-schemas 2>/dev/null | grep -qx "$1"
}
has_ptyxis() {
  if has_schema "org.gnome.Ptyxis"; then
    return 0
  fi
  if command -v dconf >/dev/null 2>&1 && \
     dconf list /org/gnome/ 2>/dev/null | grep -q '^Ptyxis/'; then
    return 0
  fi
  if command -v flatpak >/dev/null 2>&1 && \
     flatpak list --app 2>/dev/null | grep -q 'app.devsuite.Ptyxis'; then
    return 0
  fi
  return 1
}

# ==============================================================================
# 2) INSTALLS BASE
# ==============================================================================
pkg_update
pkg_upgrade

# Paquetes comunes (nombres varían en Fedora)
if is_ubuntu_like; then
  pkg_install \
    git curl make unzip gcc ripgrep xclip zsh \
    zsh-syntax-highlighting zsh-autosuggestions \
    eza fontconfig tmux podman podman-compose \
    pipx
  # Wayland clipboard opcional
  pkg_install wl-clipboard || true
else
  # Fedora
  pkg_install \
    git curl make unzip gcc ripgrep xclip zsh \
    zsh-syntax-highlighting zsh-autosuggestions \
    eza fontconfig tmux podman \
    python3-pipx
  # En Fedora, podman-compose puede no venir por defecto; intentamos ambos
  pkg_install podman-compose || pkg_install python3-podman-compose || true
  pkg_install wl-clipboard || true
fi

# ==============================================================================
# 3) NEOVIM 0.12.1 (cross-distro)
#   - Tarball oficial versionado y symlink en /usr/local/bin
# ==============================================================================
install_neovim_0121() {
  local want_version="0.12.1"
  local arch="x86_64"
  local url="https://github.com/neovim/neovim-releases/releases/download/v${want_version}/nvim-linux-${arch}.tar.gz"
  local tmp="/tmp/nvim-linux-${arch}.tar.gz"
  local dst="/opt/nvim"

  echo "[Neovim] Descargando desde: $url"
  curl -fsSLo "$tmp" "$url"

  sudo rm -rf "$dst"
  sudo mkdir -p "$dst"
  sudo tar -xzf "$tmp" -C /opt
  rm -f "$tmp"

  # El tar trae /opt/nvim-linux-x86_64; lo normalizamos a /opt/nvim
  if [ -d "/opt/nvim-linux-${arch}" ]; then
    sudo rm -rf "$dst"
    sudo mv "/opt/nvim-linux-${arch}" "$dst"
  fi

  sudo ln -sf "$dst/bin/nvim" /usr/local/bin/nvim
  echo "[Neovim] Instalado en $dst y symlink /usr/local/bin/nvim"
}

NV_CURR="$(nv_ver || true)"
if [ "$NV_CURR" != "0.12.1" ]; then
  echo "[Neovim] Instalando 0.12.1 (actual: ${NV_CURR:-no instalado})"
  install_neovim_0121
else
  echo "[Neovim] Ya en 0.12.1 → OK ($NV_CURR)"
fi

# Config de Neovim
mkdir -p "$HOME/.config"
if [ ! -d "$HOME/.config/nvim" ]; then
  git clone https://github.com/endikallanomatxin/nvim.git "$HOME/.config/nvim"
else
  echo "[Neovim] ~/.config/nvim ya existe → skip clone"
fi

# ==============================================================================
# 4) pipx: djlint + PATH
# ==============================================================================
# (pipx ya instalado via paquete)
pipx ensurepath >/dev/null 2>&1 || true
pipx install djlint || true

append_both <<'EOF'
# Binarios de usuario (pipx, pip --user, etc.)
export PATH="$HOME/.local/bin:$PATH"
EOF

# ==============================================================================
# 5) Editor por defecto + Git
# ==============================================================================
append_both <<'EOF'
# Editor por defecto
export VISUAL="nvim"
export EDITOR="$VISUAL"
EOF

if has_cmd nvim; then
  if ! git config --global --get core.editor >/dev/null; then
    git config --global core.editor "nvim"
  fi
  if ! git config --global --get sequence.editor >/dev/null; then
    git config --global sequence.editor "nvim"
  fi

  git config --global difftool.nvim_difftool.cmd "nvim -c \"packadd nvim.difftool\" -d \"\$LOCAL\" \"\$REMOTE\""
  git config --global diff.tool "nvim_difftool"
  git config --global alias.dt "difftool -d"
  git config --global alias.cdt "!f() { c=\"\${1:-HEAD}\"; git difftool -d \"\$c^\" \"\$c\"; }; f"
fi

# ==============================================================================
# 6) NODE + NPM (nvm)
# ==============================================================================
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "[nvm] Instalando nvm…"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

set +e
set +u
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh" --no-use
nvm_rc=$?
set -u
set -e

if [ "$nvm_rc" -ne 0 ]; then
  echo "[nvm] ⚠ No se pudo cargar nvm (rc=$nvm_rc). Salto Node." >&2
else
  NODE_TARGET_MAJOR=22
  NODE_CURR="$(node -v 2>/dev/null || true)"
  if [[ ! "$NODE_CURR" =~ ^v${NODE_TARGET_MAJOR}\. ]]; then
    echo "[Node] Instalando Node $NODE_TARGET_MAJOR con nvm…"
    nvm install "$NODE_TARGET_MAJOR"
  else
    echo "[Node] Ya en $NODE_CURR → OK"
  fi
  node -v && npm -v
fi

# ==============================================================================
# 7) GO (go.dev) → instala solo si la instalada < latest
# ==============================================================================
GO_LATEST_RAW="$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1 | tr -d '\r')"  # ej: go1.25.3
GO_LATEST="${GO_LATEST_RAW#go}"
GO_CURR="$(go_ver || echo 0)"

if has_cmd go && ver_ge "$GO_CURR" "$GO_LATEST"; then
  echo "[Go] Ya en $GO_CURR (>= $GO_LATEST) → OK"
else
  echo "[Go] Instalando $GO_LATEST_RAW… (actual: $GO_CURR)"
  curl -fsSLo /tmp/go.tgz "https://go.dev/dl/${GO_LATEST_RAW}.linux-amd64.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi

export GOPATH="${GOPATH:-$HOME/go}"
export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
go version

append_both <<'EOF'
# Go
export GOPATH="${GOPATH:-$HOME/go}"
export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
EOF

# ==============================================================================
# 8) RUST (rustup)
# ==============================================================================
if ! has_cmd rustup; then
  echo "[Rustup] Instalando rustup…"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
rustup component add rustfmt clippy rust-analyzer >/dev/null || true
rustc --version && cargo --version && (rust-analyzer --version || true)

append_both <<'EOF'
# Rust
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
EOF

# ==============================================================================
# 8.1) TREE-SITTER CLI (requerido por nvim-treesitter main en Neovim 0.12)
# ==============================================================================
TS_MIN="0.26.1"
TS_CURR="$(ts_ver || echo 0)"

if has_cmd tree-sitter && ver_ge "$TS_CURR" "$TS_MIN"; then
  echo "[tree-sitter] Ya en $TS_CURR (>= $TS_MIN) → OK"
else
  echo "[tree-sitter] Instalando tree-sitter-cli >= $TS_MIN con cargo… (actual: $TS_CURR)"
  cargo install --locked tree-sitter-cli --version 0.26.8
fi

tree-sitter --version || true

# Si la config de nvim ya está presente, recompila parsers para alinear queries y parser ABI.
if [ -d "$HOME/.config/nvim" ] && has_cmd nvim && has_cmd tree-sitter; then
  echo "[nvim-treesitter] Recompilando parsers base para Neovim 0.12…"
  nvim --headless '+lua require("nvim-treesitter").install({"bash","c","diff","html","lua","luadoc","markdown","markdown_inline","query","vim","vimdoc","java"},{summary=true,force=true}):wait(300000)' +qall! || true
fi

# ==============================================================================
# 9) ZSH + plugins (ya instalados arriba). Asegura login shell zsh.
# ==============================================================================
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
  chsh -s /usr/bin/zsh || true
fi

append_zsh <<'EOF'
# Historial zsh + opciones
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=50000
export SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS SHARE_HISTORY

# Completion
autoload -Uz compinit
compinit

# Autosuggestions (highlight al final del archivo)
# Ubuntu/Fedora suelen usar estas rutas:
if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
ZSH_AUTOSUGGEST_USE_ASYNC=1
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
EOF

# ==============================================================================
# 10) STARSHIP
# ==============================================================================
if ! has_cmd starship; then
  echo "[Starship] Instalando… (instalador oficial; si falla, paquetizado)"
  if ! curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
    echo "[Starship] Instalador oficial falló; probando con $PKG_MGR…" >&2
    pkg_install starship || true
  fi
else
  echo "[Starship] Ya instalado → OK ($(starship --version))"
fi

STAR_CFG="$HOME/.config/starship.toml"
mkdir -p "$HOME/.config"

if has_cmd starship; then
  [ -f "$STAR_CFG" ] && cp -f "$STAR_CFG" "$STAR_CFG.bak"
  starship preset nerd-font-symbols -o "$STAR_CFG"
else
  echo "[Starship] No se ha encontrado starship → no genero starship.toml"
fi

append_bash <<'EOF'
# Starship en bash
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi
EOF

append_zsh <<'EOF'
# Starship en zsh (antes de syntax-highlighting)
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

# Syntax highlighting SIEMPRE al final (Ubuntu/Fedora suelen usar esta ruta):
if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
EOF

# ==============================================================================
# 11) EZA → alias ls
# ==============================================================================
append_both <<'EOF'
# eza en lugar de ls
alias ls='eza'
EOF

# ==============================================================================
# 12) TMUX (config)
# ==============================================================================
if [ ! -f "$HOME/.tmux.conf" ]; then
  cat > "$HOME/.tmux.conf" <<'TMUX'
##### Terminal y color verdadero ###############################################
set -g default-terminal "tmux-256color"
set -as terminal-overrides ",*:Tc"

##### Usabilidad ###############################################################
set -g mouse on
setw -g mode-keys vi
set -g history-limit 100000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Recarga
unbind r
bind r source-file ~/.tmux.conf \; display-message "✓ TMUX config loaded"

##### Splits y resize ##########################################################
unbind '"'
unbind %
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

##### Tokyo Night colors #######################################################
set -g status on
set -g status-interval 5
set -g status-justify centre
set -g status-style "bg=#1a1b26,fg=#c0caf5"

set -g status-left ""
set -g status-right  "#[bold]#S #[fg=#7aa2f7]#[default] #I:#W "
set -g status-justify left

setw -g window-status-separator ""
setw -g window-status-format         " #[fg=#565f89]#I #[fg=#c0caf5]#W "
setw -g window-status-current-format "#[bg=#7aa2f7,fg=#1a1b26,bold] #I #W #[default]"

set -g pane-border-style        "fg=#3b4261"
set -g pane-active-border-style "fg=#7aa2f7"

set -g message-style         "bg=#1f2335,fg=#c0caf5"
set -g message-command-style "bg=#1f2335,fg=#c0caf5"
set -g mode-style            "bg=#33467c,fg=#c0caf5"

##### Copia al portapapeles #########################################
# X11:
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "xclip -selection clipboard -in"
bind -T copy-mode    MouseDragEnd1Pane send -X copy-pipe-and-cancel "xclip -selection clipboard -in"
if-shell "command -v xclip >/dev/null 2>&1" \
  'bind -T copy-mode-vi y send -X copy-pipe-and-cancel "xclip -sel clip -i"'

# Wayland (si quieres):
# if-shell "command -v wl-copy >/dev/null 2>&1" \
#   'bind -T copy-mode-vi y send -X copy-pipe-and-cancel "wl-copy"'
TMUX
fi

# ==============================================================================
# 13) Tokyo Night según terminal GNOME
# ==============================================================================
if command -v dconf >/dev/null 2>&1; then
  if has_schema "org.gnome.Terminal.ProfilesList"; then
    echo "[GNOME Terminal] Detectado → aplico Tokyo Night"

    if curl -fsSLo "$HOME/tokyonight-gnome-terminal.txt" \
      https://raw.githubusercontent.com/bftelman/tokyonight-gnome-terminal/master/tokyonight-gnome-terminal.txt; then
      if ! dconf load /org/gnome/terminal/ < "$HOME/tokyonight-gnome-terminal.txt"; then
        echo "[GNOME Terminal] ⚠ No se ha podido aplicar Tokyo Night (dconf error), pero sigo." >&2
      fi
    else
      echo "[GNOME Terminal] ⚠ No se ha podido descargar Tokyo Night, pero sigo." >&2
    fi

  elif has_schema "org.gnome.Console"; then
    echo "[Console] Detectada GNOME Console (kgx) → activo tema oscuro"
    gsettings set org.gnome.Console theme 'prefer-dark' || true

  elif has_ptyxis; then
    echo "[Ptyxis] Detectado → aplico Tokyo Night"

    PTYXIS_PALETTE_DIR="$HOME/.local/share/org.gnome.Ptyxis/palettes"
    mkdir -p "$PTYXIS_PALETTE_DIR"

    cat > "$PTYXIS_PALETTE_DIR/tokyo-night.palette" <<'EOF'
[Palette]
Name=Tokyo Night
Primary=true

[Dark]
Background=#1a1b26
Foreground=#c0caf5
TitlebarBackground=#1a1b26
TitlebarForeground=#c0caf5
Cursor=#c0caf5
Color0=#15161E
Color1=#f7768e
Color2=#9ece6a
Color3=#e0af68
Color4=#7aa2f7
Color5=#bb9af7
Color6=#7dcfff
Color7=#a9b1d6
Color8=#414868
Color9=#f7768e
Color10=#9ece6a
Color11=#e0af68
Color12=#7aa2f7
Color13=#bb9af7
Color14=#7dcfff
Color15=#c0caf5
EOF

    PTYXIS_UUID="$(dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d \')"
    if [ -n "${PTYXIS_UUID:-}" ]; then
      PROFILE_PATH="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/"
      gsettings set "$PROFILE_PATH" palette 'Tokyo Night' || true
      gsettings set "$PROFILE_PATH" label 'Tokyo Night' || true
    else
      echo "[Ptyxis] ⚠ No hay perfil por defecto aún (abre Ptyxis una vez) → salto ajustes del perfil." >&2
    fi
  else
    echo "[Terminal] No detecto GNOME Terminal / Console / Ptyxis → salto tema."
  fi
fi

# ==============================================================================
# 14) Podman: config
# ==============================================================================
mkdir -p "$HOME/.config/containers"
cat > "$HOME/.config/containers/containers.conf" <<'EOF'
[engine]
compose_warning_logs = false
EOF

# ==============================================================================
# 15) Fonts: Meslo Nerd Font + terminales GNOME
# ==============================================================================
install_meslo_nerdfont() {
  local FONT="Meslo"
  local DEST="$HOME/.local/share/fonts/NerdFonts/${FONT}"
  local ZIP="/tmp/${FONT}.zip"
  local FAMILY_MONO="MesloLGS Nerd Font Mono"
  local FAMILY="MesloLGS Nerd Font"

  nerdfont_present() {
    if command -v fc-list >/dev/null 2>&1; then
      fc-list | grep -qiE "MesloLGS.*Nerd.*Font"
    else
      [ -d "$DEST" ] && ls "$DEST"/MesloLGS*Nerd*Font*.ttf >/dev/null 2>&1
    fi
  }

  if [ "${FORCE_NERDFONT:-0}" != "1" ] && nerdfont_present; then
    echo "[Fonts] Meslo Nerd Font ya instalada → skip descarga"
  else
    echo "[Fonts] Instalando Meslo Nerd Font…"
    mkdir -p "$DEST"
    if curl -fsSLo "$ZIP" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${FONT}.zip"; then
      unzip -o "$ZIP" -d "$DEST" >/dev/null
      rm -f "$ZIP"
      command -v fc-cache >/dev/null 2>&1 && fc-cache -f || true
      if nerdfont_present; then
        echo "[Fonts] Meslo Nerd Font lista ✔"
      else
        echo "[Fonts] ⚠ No se detecta la fuente tras instalar (revisa $DEST)" >&2
      fi
    else
      echo "[Fonts] ⚠ No se ha podido descargar Meslo, pero sigo." >&2
    fi
  fi

  if has_schema "org.gnome.Terminal.ProfilesList"; then
    echo "[Fonts] Configurando Meslo en GNOME Terminal…"
    local PROF_ID PROF_PATH CURR_FONT WANT_FONT
    PROF_ID="$(gsettings get org.gnome.Terminal.ProfilesList default | tr -d \')"
    PROF_PATH="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:${PROF_ID}/"

    if fc-list | grep -qi "$FAMILY_MONO"; then
      WANT_FONT="${FAMILY_MONO} 12"
    else
      WANT_FONT="${FAMILY} 12"
    fi

    CURR_FONT="$(gsettings get "$PROF_PATH" font 2>/dev/null || echo '')"
    if [ "$CURR_FONT" != "'$WANT_FONT'" ]; then
      gsettings set "$PROF_PATH" use-system-font false || true
      gsettings set "$PROF_PATH" font "$WANT_FONT" || true
      echo "[Fonts] GNOME Terminal → ${WANT_FONT}"
    else
      echo "[Fonts] GNOME Terminal ya usa ${WANT_FONT} → OK"
    fi

  elif has_schema "org.gnome.Console"; then
    echo "[Fonts] Configurando Meslo en GNOME Console (kgx)…"
    local WANT_FONT
    if fc-list | grep -qi "$FAMILY_MONO"; then
      WANT_FONT="${FAMILY_MONO} 12"
    else
      WANT_FONT="${FAMILY} 12"
    fi

    if gsettings list-keys org.gnome.Console 2>/dev/null | grep -qx "use-system-font"; then
      gsettings set org.gnome.Console use-system-font false || true
    fi

    if gsettings list-keys org.gnome.Console 2>/dev/null | grep -qx "custom-font"; then
      gsettings set org.gnome.Console custom-font "$WANT_FONT" || true
      echo "[Fonts] GNOME Console → ${WANT_FONT}"
    elif gsettings list-keys org.gnome.Console 2>/dev/null | grep -qx "font"; then
      gsettings set org.gnome.Console font "$WANT_FONT" || true
      echo "[Fonts] GNOME Console (key font) → ${WANT_FONT}"
    else
      echo "[Fonts] ⚠ org.gnome.Console no expone custom-font/font; tendrás que elegirla a mano." >&2
    fi

  elif has_ptyxis; then
    echo "[Fonts] Configurando Meslo en Ptyxis…"
    local WANT_FONT
    if fc-list | grep -qi "$FAMILY_MONO"; then
      WANT_FONT="${FAMILY_MONO} 12"
    else
      WANT_FONT="${FAMILY} 12"
    fi
    gsettings set org.gnome.Ptyxis use-system-font false || true
    gsettings set org.gnome.Ptyxis font-name "$WANT_FONT" || true
    echo "[Fonts] Ptyxis → $WANT_FONT"
  else
    echo "[Fonts] No detecto terminal GNOME conocida. Meslo instalada, pero no ajusto fuente automáticamente."
  fi
}

install_meslo_nerdfont

if has_cmd gsettings && gsettings list-schemas 2>/dev/null | grep -qx 'org.gnome.desktop.interface'; then
  if fc-list | grep -qi 'MesloLGS Nerd Font Mono'; then
    gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS Nerd Font Mono 12' || true
  elif fc-list | grep -qi 'MesloLGS Nerd Font'; then
    gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS Nerd Font 12' || true
  fi
  echo "[Fonts] monospace-font-name de GNOME → Meslo"
fi

# ==============================================================================
# 16) ESCRITURA FINAL EN ~/.bashrc y ~/.zshrc
# ==============================================================================
write_managed_block "$HOME/.bashrc" "$BASH_RC"
write_managed_block "$HOME/.zshrc"  "$ZSH_RC"

# ==============================================================================
# 17) CLEANUP
# ==============================================================================
pkg_autoremove_clean

echo "✅ Setup finalizado."
