#!/usr/bin/env bash
# =============================================================================
# Immich Interactive Installer
# Docker Compose based — inspired by fixtse/immich-simple-installer
# =============================================================================
set -o pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; }
header()  { echo -e "\n${BOLD}${BLUE}── $* ${RESET}"; }

# ─── Banner ──────────────────────────────────────────────────────────────────
banner() {
  echo -e "${BOLD}${BLUE}"
  echo "  ██╗███╗   ███╗███╗   ███╗██╗ ██████╗██╗  ██╗"
  echo "  ██║████╗ ████║████╗ ████║██║██╔════╝██║  ██║"
  echo "  ██║██╔████╔██║██╔████╔██║██║██║     ███████║"
  echo "  ██║██║╚██╔╝██║██║╚██╔╝██║██║██║     ██╔══██║"
  echo "  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║██║╚██████╗██║  ██║"
  echo "  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝╚═╝ ╚═════╝╚═╝  ╚═╝"
  echo -e "${RESET}${CYAN}        Interactive Docker Installer${RESET}"
  echo -e "  ─────────────────────────────────────────────\n"
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
prompt() {
  # prompt "Question" "default" → reads into REPLY
  local question="$1" default="$2"
  if [[ -n "$default" ]]; then
    echo -ne "${BOLD}  → $question${RESET} [${default}]: "
  else
    echo -ne "${BOLD}  → $question${RESET}: "
  fi
  read -r REPLY
  REPLY="${REPLY:-$default}"
}

confirm() {
  # confirm "Question" → returns 0 for yes, 1 for no
  echo -ne "${BOLD}  → $1${RESET} [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

gen_password() {
  # Generate a 24-char alphanumeric password
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 2>/dev/null || \
    echo "$RANDOM$(date +%s)$RANDOM" | sha256sum | base64 | head -c 24
}

detect_timezone() {
  # Try timedatectl, then /etc/timezone, then fallback
  if command -v timedatectl &>/dev/null; then
    timedatectl show --property=Timezone --value 2>/dev/null
  elif [[ -f /etc/timezone ]]; then
    cat /etc/timezone
  else
    echo "UTC"
  fi
}

get_local_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"
}

# ─── Preflight ───────────────────────────────────────────────────────────────
check_requirements() {
  header "Checking requirements"

  if ! command -v docker &>/dev/null; then
    error "Docker is not installed."
    echo -e "  Install it with: ${CYAN}curl -fsSL https://get.docker.com | sh${RESET}"
    exit 1
  fi
  success "Docker found: $(docker --version | cut -d' ' -f3 | tr -d ',')"

  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 not available."
    echo -e "  Make sure you have Docker Engine 20.10+ or install the compose plugin."
    exit 1
  fi
  success "Docker Compose found: $(docker compose version --short)"

  if ! docker info &>/dev/null; then
    error "Docker daemon is not running."
    echo -e "  Try: ${CYAN}sudo systemctl start docker${RESET}"
    exit 1
  fi
  success "Docker daemon is running."

  if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    error "Neither wget nor curl found. Please install one."
    exit 1
  fi
}

# ─── Hardware Acceleration ───────────────────────────────────────────────────
detect_hwaccel() {
  header "Hardware acceleration detection"

  HWACCEL_TRANSCODING=""
  HWACCEL_ML=""

  # NVENC (NVIDIA)
  if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    success "NVIDIA GPU detected: $GPU"
    HWACCEL_DETECTED="nvenc"
  # VAAPI / QSV (Intel/AMD)
  elif ls /dev/dri/renderD* &>/dev/null; then
    DRI_DEVICE=$(ls /dev/dri/renderD* | head -1)
    success "DRI render node detected: $DRI_DEVICE"
    # Try to distinguish Intel QSV vs generic VAAPI
    if lspci 2>/dev/null | grep -qi "intel.*graphics\|intel.*uhd\|intel.*iris"; then
      HWACCEL_DETECTED="qsv"
    else
      HWACCEL_DETECTED="vaapi"
    fi
  # RKMPP (Rockchip)
  elif [[ -e /dev/mpp_service ]]; then
    success "Rockchip MPP device detected."
    HWACCEL_DETECTED="rkmpp"
  else
    info "No hardware acceleration detected. CPU mode will be used."
    HWACCEL_DETECTED=""
  fi

  if [[ -n "$HWACCEL_DETECTED" ]]; then
    echo
    if confirm "Enable hardware transcoding (${HWACCEL_DETECTED^^})?"; then
      HWACCEL_TRANSCODING="$HWACCEL_DETECTED"
      success "Hardware transcoding enabled: $HWACCEL_TRANSCODING"
    else
      info "Skipping hardware transcoding."
    fi

    echo
    # Suggest matching ML backend
    case "$HWACCEL_DETECTED" in
      nvenc) ML_SUGGESTION="cuda" ;;
      qsv)   ML_SUGGESTION="openvino" ;;
      *)     ML_SUGGESTION="" ;;
    esac

    if [[ -n "$ML_SUGGESTION" ]]; then
      if confirm "Enable ML hardware acceleration (${ML_SUGGESTION^^})?"; then
        HWACCEL_ML="$ML_SUGGESTION"
        success "ML acceleration enabled: $HWACCEL_ML"
      else
        info "Skipping ML acceleration."
      fi
    fi
  fi
}

# ─── Interactive Configuration ───────────────────────────────────────────────
configure() {
  header "Installation configuration"

  # Install directory
  prompt "Installation directory" "/opt/immich"
  INSTALL_DIR="$REPLY"

  # Upload / library location
  prompt "Photo library storage path" "${INSTALL_DIR}/library"
  UPLOAD_LOCATION="$REPLY"

  # Timezone
  DEFAULT_TZ=$(detect_timezone)
  prompt "Timezone" "$DEFAULT_TZ"
  TIMEZONE="$REPLY"

  # DB password
  DEFAULT_PASS=$(gen_password)
  echo
  info "A secure database password has been generated."
  if confirm "Use auto-generated password? (no = enter your own)"; then
    DB_PASSWORD="$DEFAULT_PASS"
  else
    prompt "Database password"
    DB_PASSWORD="$REPLY"
    if [[ -z "$DB_PASSWORD" ]]; then
      warn "Empty password is not allowed. Using generated password."
      DB_PASSWORD="$DEFAULT_PASS"
    fi
  fi

  # Immich version
  echo
  prompt "Immich version (press Enter for latest stable)" "release"
  IMMICH_VERSION="$REPLY"

  # Port
  prompt "Expose port" "2283"
  PORT="$REPLY"

  # Summary
  header "Summary"
  echo -e "  Install dir   : ${CYAN}${INSTALL_DIR}${RESET}"
  echo -e "  Library path  : ${CYAN}${UPLOAD_LOCATION}${RESET}"
  echo -e "  Timezone      : ${CYAN}${TIMEZONE}${RESET}"
  echo -e "  DB password   : ${CYAN}${DB_PASSWORD}${RESET}"
  echo -e "  Version       : ${CYAN}${IMMICH_VERSION}${RESET}"
  echo -e "  Port          : ${CYAN}${PORT}${RESET}"
  [[ -n "$HWACCEL_TRANSCODING" ]] && echo -e "  HW Transcode  : ${CYAN}${HWACCEL_TRANSCODING}${RESET}"
  [[ -n "$HWACCEL_ML" ]]          && echo -e "  ML Accel      : ${CYAN}${HWACCEL_ML}${RESET}"
  echo

  if ! confirm "Proceed with installation?"; then
    info "Installation cancelled."
    exit 0
  fi
}

# ─── Download Helper ─────────────────────────────────────────────────────────
download() {
  local url="$1" dest="$2"
  if command -v wget &>/dev/null; then
    wget -q --show-progress -O "$dest" "$url"
  else
    curl -fsSL -o "$dest" "$url"
  fi
}

# ─── Setup Files ─────────────────────────────────────────────────────────────
REPO_BASE="https://github.com/immich-app/immich/releases/latest/download"

setup_directory() {
  header "Setting up directory"

  if [[ -d "$INSTALL_DIR" ]]; then
    warn "Directory already exists: $INSTALL_DIR"
    if [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || [[ -f "$INSTALL_DIR/.env" ]]; then
      if ! confirm "Existing Immich files found. Overwrite them?"; then
        info "Installation cancelled."
        exit 0
      fi
    fi
  else
    mkdir -p "$INSTALL_DIR" || { error "Failed to create $INSTALL_DIR"; exit 1; }
    success "Directory created: $INSTALL_DIR"
  fi

  mkdir -p "$UPLOAD_LOCATION" || { error "Failed to create library path"; exit 1; }
  success "Library path ready: $UPLOAD_LOCATION"

  cd "$INSTALL_DIR" || exit 1
}

download_compose_files() {
  header "Downloading Immich files"

  info "Downloading docker-compose.yml..."
  download "${REPO_BASE}/docker-compose.yml" docker-compose.yml \
    || { error "Failed to download docker-compose.yml"; exit 1; }
  success "docker-compose.yml downloaded."

  info "Downloading .env..."
  download "${REPO_BASE}/example.env" .env \
    || { error "Failed to download .env"; exit 1; }
  success ".env downloaded."
}

patch_env() {
  header "Configuring .env"

  # Patch upload location
  sed -i "s|UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${UPLOAD_LOCATION}|" .env
  # Patch DB password
  sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" .env
  # Patch timezone
  if grep -q "^TZ=" .env; then
    sed -i "s|^TZ=.*|TZ=${TIMEZONE}|" .env
  else
    echo "TZ=${TIMEZONE}" >> .env
  fi
  # Patch version
  sed -i "s|IMMICH_VERSION=.*|IMMICH_VERSION=${IMMICH_VERSION}|" .env

  success ".env configured."
}

patch_port() {
  # Only patch if user chose a non-default port
  if [[ "$PORT" != "2283" ]]; then
    header "Setting custom port"
    if grep -q "2283:" docker-compose.yml; then
      sed -i "s|2283:|${PORT}:|g" docker-compose.yml
      success "Port set to $PORT."
    else
      warn "Could not auto-patch port. Edit docker-compose.yml manually."
    fi
  fi
}

setup_hwaccel() {
  [[ -z "$HWACCEL_TRANSCODING" && -z "$HWACCEL_ML" ]] && return

  header "Configuring hardware acceleration"
  HW_BASE="https://github.com/immich-app/immich/releases/latest/download"

  if [[ -n "$HWACCEL_TRANSCODING" ]]; then
    info "Downloading hwaccel.transcoding.yml..."
    download "${HW_BASE}/hwaccel.transcoding.yml" hwaccel.transcoding.yml \
      && success "hwaccel.transcoding.yml downloaded." \
      || warn "Failed to download hwaccel.transcoding.yml. Skipping."

    # Inject transcoding API into the yml
    if [[ -f hwaccel.transcoding.yml ]]; then
      sed -i "s|api: .*|api: ${HWACCEL_TRANSCODING}|" hwaccel.transcoding.yml 2>/dev/null || true
      # Add extend to docker-compose.yml if not already present
      if ! grep -q "hwaccel.transcoding.yml" docker-compose.yml; then
        sed -i '/immich-server:/a\    extends:\n      file: hwaccel.transcoding.yml\n      service: hwaccel' \
          docker-compose.yml 2>/dev/null || warn "Could not auto-inject transcoding extend."
      fi
    fi
  fi

  if [[ -n "$HWACCEL_ML" ]]; then
    info "Downloading hwaccel.ml.yml..."
    download "${HW_BASE}/hwaccel.ml.yml" hwaccel.ml.yml \
      && success "hwaccel.ml.yml downloaded." \
      || warn "Failed to download hwaccel.ml.yml. Skipping."
  fi
}

# ─── Launch ──────────────────────────────────────────────────────────────────
start_containers() {
  header "Starting Immich"

  info "Pulling images (this may take a few minutes)..."
  docker compose pull

  echo
  info "Starting containers..."
  docker compose up -d --remove-orphans \
    || { error "Failed to start containers. Check logs with: docker compose logs"; exit 1; }

  success "Immich is running!"
}

# ─── Done ────────────────────────────────────────────────────────────────────
show_summary() {
  local ip
  ip=$(get_local_ip)

  echo
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗"
  echo -e "║         Immich installed successfully!       ║"
  echo -e "╚══════════════════════════════════════════════╝${RESET}"
  echo
  echo -e "  ${BOLD}Web UI:${RESET}       ${CYAN}http://${ip}:${PORT}${RESET}"
  echo -e "  ${BOLD}Install dir:${RESET}  ${CYAN}${INSTALL_DIR}${RESET}"
  echo -e "  ${BOLD}Library:${RESET}      ${CYAN}${UPLOAD_LOCATION}${RESET}"
  echo
  echo -e "  ${BOLD}Useful commands:${RESET}"
  echo -e "    ${CYAN}cd ${INSTALL_DIR} && docker compose logs -f${RESET}      # follow logs"
  echo -e "    ${CYAN}cd ${INSTALL_DIR} && docker compose pull && docker compose up -d${RESET}  # update"
  echo -e "    ${CYAN}cd ${INSTALL_DIR} && docker compose down${RESET}          # stop"
  echo
  echo -e "  ${YELLOW}First run: open the web UI and create your admin account.${RESET}"
  echo
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
  banner
  check_requirements
  detect_hwaccel
  configure
  setup_directory
  download_compose_files
  patch_env
  patch_port
  setup_hwaccel
  start_containers
  show_summary
}

main "$@"
