#!/usr/bin/env bash

# ——— Guardias de ejecución ———
# 1) Debe ejecutarse con Bash (no zsh/sh/fish, etc.)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Este script está pensado para Bash. Ejecútalo así:  bash installs.sh  (no 'sh' ni 'zsh')." >&2
  # Si fue 'source', intenta return; si no, exit.
  return 1 2>/dev/null || exit 1
fi

# 2) No debe ejecutarse con 'source' ni '.'
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "No 'source' este script. Ejecútalo así:  bash installs.sh" >&2
  return 1 2>/dev/null || exit 1
fi

set -euo pipefail

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
dpkg_ge(){ dpkg --compare-versions "$1" ge "$2"; }  # >=
has_schema() {
  command -v gsettings >/dev/null 2>&1 || return 1
  gsettings list-schemas 2>/dev/null | grep -qx "$1"
}
has_ptyxis() {
  # 1) Si existe el schema de dconf (instalación nativa)
  if has_schema "org.gnome.Ptyxis"; then
    return 0
  fi

  # 2) Si hay claves en /org/gnome/Ptyxis (Ptyxis ya se ha abierto al menos una vez)
  if command -v dconf >/dev/null 2>&1 && \
     dconf list /org/gnome/ 2>/dev/null | grep -q '^Ptyxis/'; then
    return 0
  fi

  # 3) Si hay Flatpak de Ptyxis instalado
  if command -v flatpak >/dev/null 2>&1 && \
     flatpak list --app 2>/dev/null | grep -q 'app.devsuite.Ptyxis'; then
    return 0
  fi

  return 1
}

# ==============================================================================
# 2) INSTALLS
# ==============================================================================

sudo apt update -y
sudo apt upgrade -y

# BASICS
sudo apt install -y git curl make unzip gcc ripgrep xclip zsh zsh-syntax-highlighting zsh-autosuggestions eza fontconfig

# ------------------------------------------------------------------------------
# NEOVIM (instala solo si NO es la estable 0.11.x)
# ------------------------------------------------------------------------------
install_neovim_stable_011(){
  curl -fsSLO "https://github.com/neovim/neovim-releases/releases/latest/download/nvim-linux-x86_64.deb"
  sudo apt install -y ./nvim-linux-x86_64.deb
  rm -f ./nvim-linux-x86_64.deb
}
NV_CURR="$(nv_ver || true)"
if [[ ! "$NV_CURR" =~ ^0\.11\. ]]; then
  echo "[Neovim] Instalando estable 0.11.x (actual: ${NV_CURR:-no instalado})"
  install_neovim_stable_011
else
  echo "[Neovim] Ya en 0.11.x → OK ($NV_CURR)"
fi

# Config de Neovim (clona solo si falta)
mkdir -p "$HOME/.config"
cd "$HOME/.config"
if [ ! -d nvim ]; then
  git clone https://github.com/endikallanomatxin/nvim.git
else
  echo "[Neovim] ~/.config/nvim ya existe → skip clone"
fi
cd ~/

# For djlint
sudo apt install pipx -y
pipx install djlint

append_both <<'EOF'
# Binarios de usuario (pipx, pip --user, etc.)
export PATH="$HOME/.local/bin:$PATH"
EOF

# --- Git editor por defecto Neovim ---------------------------------------
# 1) Variables de entorno para todas las shells
append_both <<'EOF'
# Editor por defecto
export VISUAL="nvim"
export EDITOR="$VISUAL"
EOF

# 2) Config global de Git (solo si no estaba definida)
if command -v nvim >/dev/null 2>&1; then
  if ! git config --global --get core.editor >/dev/null; then
    git config --global core.editor "nvim"
  fi
  # Opcional: asegurar editor para rebase interactivo
  if ! git config --global --get sequence.editor >/dev/null; then
    git config --global sequence.editor "nvim"
  fi
fi

# ------------------------------------------------------------------------------
# NODE + NPM (nvm) → instala nvm si falta y Node 22 si no está
# ------------------------------------------------------------------------------
export NVM_DIR="$HOME/.nvm"

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "[nvm] Instalando nvm…"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

# nvm.sh puede fallar con set -e y además hace auto-use; lo evitamos
set +e
set +u
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

# ------------------------------------------------------------------------------
# GO (desde go.dev) → descarga solo si la instalada < latest
# ------------------------------------------------------------------------------
GO_LATEST_RAW="$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1 | tr -d '\r')"  # ej: go1.25.3
GO_LATEST="${GO_LATEST_RAW#go}"
GO_CURR="$(go_ver || echo 0)"
if has_cmd go && dpkg_ge "$GO_CURR" "$GO_LATEST"; then
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

# PATH de Go en ambas shells
append_both <<'EOF'
# Go
export GOPATH="${GOPATH:-$HOME/go}"
export PATH="/usr/local/go/bin:$GOPATH/bin:$PATH"
EOF

# ------------------------------------------------------------------------------
# RUST (rustup) → instala rustup si falta; si existe, no descarga de nuevo
# ------------------------------------------------------------------------------
if ! has_cmd rustup; then
  echo "[Rustup] Instalando rustup…"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y
fi
# Carga entorno en esta sesión
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
# Asegura componentes (idempotente)
rustup component add rustfmt clippy rust-analyzer >/dev/null || true
rustc --version && cargo --version && (rust-analyzer --version || true)

# RC de Rust en ambas shells
append_both <<'EOF'
# Rust
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
EOF

# ------------------------------------------------------------------------------
# ZSH + plugins (apt ya lo ha instalado arriba). Asegura login shell zsh.
# ------------------------------------------------------------------------------
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
  chsh -s /usr/bin/zsh || true
fi

# Bloque ZSH (historial, compinit, autosuggestions)
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
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_USE_ASYNC=1
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
EOF

# ------------------------------------------------------------------------------
# STARSHIP → descarga solo si falta; escribe config cada vez (con backup)
# ------------------------------------------------------------------------------
# intenta instalador oficial y cae en apt si falla
if ! has_cmd starship; then
  echo "[Starship] Instalando… (primero instalador oficial, luego apt si hace falta)"

  # intentamos el instalador oficial, pero SIN romper el script si falla
  if ! curl -fsSL https://starship.rs/install.sh | sh -s -- -y; then
    echo "[Starship] Instalador oficial ha fallado, probando con apt…" >&2

    if sudo apt install -y starship; then
      echo "[Starship] Instalado desde apt ✔"
    else
      echo "[Starship] ❌ No se ha podido instalar Starship ni con el instalador oficial ni con apt." >&2
      echo "[Starship] El script seguirá sin Starship." >&2
    fi
  fi
else
  echo "[Starship] Ya instalado → OK ($(starship --version))"
fi

STAR_CFG="$HOME/.config/starship.toml"
mkdir -p "$HOME/.config"

if has_cmd starship; then
  if [ -f "$STAR_CFG" ]; then
    cp -f "$STAR_CFG" "$STAR_CFG.bak"
  fi
  starship preset nerd-font-symbols -o "$STAR_CFG"
else
  echo "[Starship] No se ha encontrado starship tras intentar instalarlo → no genero starship.toml"
fi

# Starship init en cada shell
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
# Syntax highlighting SIEMPRE al final
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF

# ------------------------------------------------------------------------------
# EZA → alias ls
# ------------------------------------------------------------------------------
append_both <<'EOF'
# eza en lugar de ls
alias ls='eza'
EOF

# ------------------------------------------------------------------------------
# TMUX (opcional)
# ------------------------------------------------------------------------------
sudo apt install tmux -y

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
# Paleta: bg #1a1b26, fg #c0caf5, blue #7aa2f7, cyan #7dcfff, magenta #bb9af7
# green #9ece6a, yellow #e0af68, red #f7768e, orange #ff9e64, grey #565f89
set -g status on
set -g status-interval 5
set -g status-justify centre
set -g status-style "bg=#1a1b26,fg=#c0caf5"

# Izquierda / derecha
set -g status-left ""
set -g status-right  "#[bold]#S #[fg=#7aa2f7]#[default] #I:#W "
set -g status-justify left

# Ventanas (pestañas)
setw -g window-status-separator ""
setw -g window-status-format         " #[fg=#565f89]#I #[fg=#c0caf5]#W "
setw -g window-status-current-format "#[bg=#7aa2f7,fg=#1a1b26,bold] #I #W #[default]"

# Bordes panel
set -g pane-border-style        "fg=#3b4261"
set -g pane-active-border-style "fg=#7aa2f7"

# Mensajes / prompts / copy-mode (sin 'command-prompt-style' para compatibilidad)
set -g message-style         "bg=#1f2335,fg=#c0caf5"
set -g message-command-style "bg=#1f2335,fg=#c0caf5"
set -g mode-style            "bg=#33467c,fg=#c0caf5"

##### Opcional: títulos en borde (tmux >= 3.2) #################################
# set -g pane-border-status top
# set -g pane-border-format " #[fg=#a6adc8]#{pane_index}#[default] #{pane_current_command} "

##### Copia al portapapeles #########################################
# For X11:
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "xclip -selection clipboard -in"
bind -T copy-mode    MouseDragEnd1Pane send -X copy-pipe-and-cancel "xclip -selection clipboard -in"
# For wayland:
# bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "wl-copy"
# bind -T copy-mode    MouseDragEnd1Pane send -X copy-pipe-and-cancel "wl-copy"

if-shell "command -v xclip >/dev/null 2>&1" \
  'bind -T copy-mode-vi y send -X copy-pipe-and-cancel "xclip -sel clip -i"'
if-shell "command -v pbcopy >/dev/null 2>&1" \
  'bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"'

TMUX
fi


# ------------------------------------------------------------------------------
# Tokyo Night instalado según la terminal
#   - GNOME Terminal (Ubuntu 24)
#   - GNOME Console (kgx)
#   - Ptyxis (Ubuntu 25+)
# ------------------------------------------------------------------------------

if command -v dconf >/dev/null 2>&1; then
  if has_schema "org.gnome.Terminal.ProfilesList"; then
    echo "[GNOME Terminal] Detectado → aplico tema Tokyo Night"

    # Descarga y aplica la config de Tokyo Night para GNOME Terminal
    if wget -qO "$HOME/tokyonight-gnome-terminal.txt" \
      https://raw.githubusercontent.com/bftelman/tokyonight-gnome-terminal/master/tokyonight-gnome-terminal.txt; then

      if ! dconf load /org/gnome/terminal/ < "$HOME/tokyonight-gnome-terminal.txt"; then
        echo "[GNOME Terminal] ⚠ No se ha podido aplicar Tokyo Night (dconf error), pero sigo." >&2
      fi
    else
      echo "[GNOME Terminal] ⚠ No se ha podido descargar el tema Tokyo Night, pero sigo." >&2
    fi

  elif has_schema "org.gnome.Console"; then
    echo "[Console] Detectada GNOME Console (kgx) → activo tema oscuro"
    # Console usa su propia key 'theme' (light / dark / system).
    gsettings set org.gnome.Console theme 'prefer-dark' || true

  elif has_ptyxis; then
    echo "[Ptyxis] Detectado Ptyxis → aplico Tokyo Night"

    # 0) Aseguramos paleta Tokyo Night para Ptyxis
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

    # 1) Obtenemos el UUID del perfil por defecto
    PTYXIS_UUID="$(dconf read /org/gnome/Ptyxis/default-profile-uuid 2>/dev/null | tr -d \')"

    if [ -n "${PTYXIS_UUID:-}" ]; then
      PROFILE_PATH="org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/${PTYXIS_UUID}/"

      # 2) Asignamos paleta + etiqueta Tokyo Night
      gsettings set "$PROFILE_PATH" palette 'Tokyo Night' || true
      gsettings set "$PROFILE_PATH" label 'Tokyo Night' || true

    else
      echo "[Ptyxis] ⚠ No hay perfil por defecto aún (quizá nunca has abierto Ptyxis) → salto paleta/opacidad." >&2
    fi

  else
    echo "[Terminal] No se ha detectado GNOME Terminal, GNOME Console ni Ptyxis con schemas conocidos → salto tema Tokyo Night."
  fi
fi

# ------------------------------------------------------------------------------
# Podman
# ------------------------------------------------------------------------------

sudo apt install -y podman podman-compose

mkdir -p "$HOME/.config/containers"
cat > "$HOME/.config/containers/containers.conf" <<'EOF'
[engine]
compose_warning_logs = false
EOF


# ==============================================================================
# 3) FONT: Meslo Nerd Font + terminales GNOME
# ==============================================================================

install_meslo_nerdfont() {
  local FONT="Meslo"
  local DEST="$HOME/.local/share/fonts/NerdFonts/${FONT}"
  local ZIP="/tmp/${FONT}.zip"
  local FAMILY_MONO="MesloLGS Nerd Font Mono"
  local FAMILY="MesloLGS Nerd Font"

  nerdfont_present() {
    # Si hay fontconfig, mira familias; si no, mira ficheros en destino
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
      echo "[Fonts] ⚠ No se ha podido descargar la Nerd Font Meslo, pero sigo." >&2
    fi
  fi

  # Si hay GNOME Terminal, intenta ajustar fuente por defecto
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

    if gsettings list-keys org.gnome.Console | grep -qx "use-system-font"; then
      gsettings set org.gnome.Console use-system-font false || true
    fi

    if gsettings list-keys org.gnome.Console | grep -qx "custom-font"; then
      gsettings set org.gnome.Console custom-font "$WANT_FONT" || true
      echo "[Fonts] GNOME Console → ${WANT_FONT}"
    elif gsettings list-keys org.gnome.Console | grep -qx "font"; then
      gsettings set org.gnome.Console font "$WANT_FONT" || true
      echo "[Fonts] GNOME Console (key font) → ${WANT_FONT}"
    else
      echo "[Fonts] ⚠ org.gnome.Console no expone ni custom-font ni font; Meslo está instalada pero tendrás que elegirla a mano." >&2
    fi

  elif has_ptyxis; then
    echo "[Fonts] Configurando Meslo en Ptyxis…"
    local WANT_FONT
    if fc-list | grep -qi "$FAMILY_MONO"; then
      WANT_FONT="${FAMILY_MONO} 12"
    else
      WANT_FONT="${FAMILY} 12"
    fi

    # Ptyxis tiene font global en org.gnome.Ptyxis
    gsettings set org.gnome.Ptyxis use-system-font false || true
    gsettings set org.gnome.Ptyxis font-name "$WANT_FONT" || true
    echo "[Fonts] Ptyxis → $WANT_FONT"

  else
    echo "[Fonts] No se ha detectado GNOME Terminal, GNOME Console ni Ptyxis con schemas conocidos. Meslo está instalada, pero no ajusto ninguna terminal por defecto."
  fi
}

install_meslo_nerdfont

# Si estamos en un escritorio GNOME, usa Meslo como monospace global
if has_cmd gsettings && gsettings list-schemas 2>/dev/null | grep -qx 'org.gnome.desktop.interface'; then
  if fc-list | grep -qi 'MesloLGS Nerd Font Mono'; then
    gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS Nerd Font Mono 12' || true
  elif fc-list | grep -qi 'MesloLGS Nerd Font'; then
    gsettings set org.gnome.desktop.interface monospace-font-name 'MesloLGS Nerd Font 12' || true
  fi
  echo "[Fonts] monospace-font-name de GNOME → Meslo"
fi

# ==============================================================================
# 4) ESCRITURA FINAL EN ~/.bashrc y ~/.zshrc
# ==============================================================================
write_managed_block "$HOME/.bashrc" "$BASH_RC"
write_managed_block "$HOME/.zshrc"  "$ZSH_RC"

# ==============================================================================
# 5) CLEANUP
# ==============================================================================

sudo apt autoremove -y
sudo apt clean

echo "✅ Setup finalizado."
