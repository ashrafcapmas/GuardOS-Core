#!/system/bin/sh
# Guard_OS Creator and Injector
# Author: Ashraf Saber
VERSION="3.1.0"
TARGET="/system/bin/install"

if [ "$(id -u 2>/dev/null)" != "0" ]; then
  printf '%s\n' "Root privileges are required." >&2
  exit 1
fi

remount_rw() {
  mount -o rw,remount /system 2>/dev/null || mount -o remount,rw /system 2>/dev/null
}
remount_ro() {
  mount -o ro,remount /system 2>/dev/null || mount -o remount,ro /system 2>/dev/null || true
}

remount_rw || { printf '%s\n' "Cannot remount /system read-write." >&2; exit 1; }
mkdir -p /system/bin /system/etc || { remount_ro; exit 1; }
cat > "$TARGET" <<'GUARD_OS_install_EOF'
#!/system/bin/sh
# ============================================================
# Guard_OS Installer - Version 3.1.0 (Ubuntu Base noble)
# Author: Ashraf Saber
# ============================================================

export TERM=xterm
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:/vendor/xbin:$PATH

VERSION="3.1.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================================
# MODULE 01: CORE, PATHS, LOGGING, TRAPS, CONFIG
# ============================================================

STATE_FILE="/system/etc/guard_os_install.state"
HOST_CONFIG="/system/etc/guard_os.conf"
SYSTEM_MANIFEST="/system/etc/guard_os_manifest.conf"
HOST_LOG="/data/local/tmp/guard_os_installer.log"
AUTOSTART_FILE="/system/etc/install-recovery.sh"
DEFAULT_TARGET="/data/Guard_OS"

CURRENT_STAGE="IDLE"
TARGET_DIR=""
ROOTFS_ARCH=""
RELEASE_CHANNEL="stable"
ROOTFS_SOURCE=""
ROOTFS_SIZE=0

now() {
  date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

log_event() {
  level="$1"
  shift
  printf '%s [%s] %s\n' "$(now)" "$level" "$*" >> "$HOST_LOG" 2>/dev/null || true
}

# ---- Corrected remount functions ----
remount_system_rw() {
  # Check if already rw
  if mount | grep " /system " | grep -q "rw,"; then
    return 0
  fi
  mount -o rw,remount /system 2>/dev/null ||
  mount -o remount,rw /system 2>/dev/null || {
    log_event ERROR "Unable to remount /system read-write"
    return 1
  }
  return 0
}

remount_system_ro() {
  # Check if already ro
  if mount | grep " /system " | grep -q "ro,"; then
    return 0
  fi
  mount -o ro,remount /system 2>/dev/null ||
  mount -o remount,ro /system 2>/dev/null || {
    log_event WARNING "Unable to remount /system read-only; continuing"
    return 0  # Not fatal
  }
  return 0
}

set_install_stage() {
  stage="$1"
  detail="$2"
  CURRENT_STAGE="$stage"
  if ! remount_system_rw; then
    printf "${RED}[FAIL] Cannot remount /system rw${NC}\n" >&2
    return 1
  fi
  mkdir -p /system/etc 2>/dev/null
  cat > "$STATE_FILE" <<STATEEOF
STATUS=installing
CURRENT_STAGE=$stage
LAST_DETAIL=$detail
INSTALL_DIR=${TARGET_DIR:-}
VERSION=$VERSION
UPDATED_AT=$(now)
STATEEOF
  if [ $? -ne 0 ]; then
    log_event ERROR "Failed to write state file"
    return 1
  fi
  log_event INFO "$stage: $detail"
  return 0
}

complete_install_state() {
  if remount_system_rw && [ -f "$STATE_FILE" ]; then
    sed -i 's/^STATUS=.*/STATUS=complete/' "$STATE_FILE" 2>/dev/null
    sed -i 's/^CURRENT_STAGE=.*/CURRENT_STAGE=COMPLETE/' "$STATE_FILE" 2>/dev/null
    sed -i 's/^LAST_DETAIL=.*/LAST_DETAIL=installation_successful/' "$STATE_FILE" 2>/dev/null
  fi
  log_event SUCCESS "Installation complete"
}

on_interrupt() {
  set_install_stage "INTERRUPTED" "at_$CURRENT_STAGE" 2>/dev/null || true
  rm -f /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part
  printf "\n${YELLOW}Interrupted at: $CURRENT_STAGE${NC}\n"
  exit 130
}

trap 'on_interrupt' INT TERM HUP

# ---- free_kib without awk ----
free_kib() {
  _line=$(df -Pk "$1" 2>/dev/null | tail -n 1)
  if [ -n "$_line" ]; then
    set -- $_line
    echo "$4"
  else
    echo 0
  fi
}

human_mib_from_kib() {
  kib=${1:-0}
  echo $((kib / 1024))
}


# ============================================================
# UI CONTROLS & UTILITIES
# ============================================================
clear_screen() {
  printf '\033[2J\033[3J\033[H'
  command -v clear >/dev/null 2>&1 && clear
}

print_line() {
  printf "${CYAN}========================================${NC}\n"
}

print_header() {
  clear_screen
  print_line
  printf "${BOLD}${WHITE}%s${NC}\n" "$1"
  print_line
}

print_subheader() {
  printf "\n${YELLOW}--- %s ---${NC}\n" "$1"
}

# ============================================================
# MODULE 02: UI ENGINE - All menu items use [number] format
# ============================================================

print_menu_item() {
  printf "  ${GREEN}[%s]${NC} %s\n" "$1" "$2"
}

print_info() {
  printf "  ${CYAN}-${NC} ${YELLOW}%s${NC} : ${WHITE}%s${NC}\n" "$1" "$2"
}

print_success() {
  printf "  ${GREEN}[+]${NC} %s\n" "$1"
}

print_error() {
  printf "  ${RED}[x]${NC} %s\n" "$1"
}

print_warning() {
  printf "  ${YELLOW}[!]${NC} %s\n" "$1"
}

print_info_msg() {
  printf "  ${CYAN}[i]${NC} %s\n" "$1"
}

UI_WIDTH=60
UI_INNER=58
UI_MODE=compact

ui_detect() {
  c=$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2)
  case "$c" in ''|*[!0-9]*) c=40 ;; esac
  UI_WIDTH=$c
  [ "$UI_WIDTH" -lt 32 ] && UI_WIDTH=32
  [ "$UI_WIDTH" -gt 60 ] && UI_WIDTH=60
  UI_INNER=$UI_WIDTH
  UI_MODE=compact
}

ui_repeat() {
  x=""
  i=0
  while [ "$i" -lt "$2" ]; do
    x="$x$1"
    i=$((i+1))
  done
  printf '%s' "$x"
}

ui_separator() {
  ui_repeat "$1" "$UI_INNER"
  printf '\n'
}

ui_title() {
  clear_screen
  ui_separator '='
  printf "${BOLD}%s${NC}\n" "$1"
  ui_separator '='
}

ui_row() {
  printf '%-13.13s : %s\n' "$1" "$2"
}

ui_status() {
  z="$1"
  shift
  case "$z" in
    ok) q="${GREEN}[ OK ]${NC}" ;;
    del) q="${RED}[DEL ]${NC}" ;;
    fail) q="${RED}[FAIL]${NC}" ;;
    warn) q="${YELLOW}[WARN]${NC}" ;;
    wait) q="${CYAN}[WAIT]${NC}" ;;
    *) q="${CYAN}[INFO]${NC}" ;;
  esac
  printf "%b %s\n" "$q" "$*"
}

ui_menu() {
  printf "${GREEN}[%s]${NC} %s\n" "$1" "$2"
}

ui_prompt() {
  printf "${YELLOW}Choice %s: ${NC}" "$1"
  read "$2" < /dev/tty
}

ui_pause() {
  printf "\n${YELLOW}Press ENTER to continue...${NC}"
  read dummy < /dev/tty
}

# ---- Spinner / Activity ----
ACTIVITY_PID=""

activity_start() { printf "  \033[0;36m%s...\033[0m\n" "$1"; }

activity_stop() { :; }

activity_run() {
  label="$1"
  shift
  activity_start "$label"
  "$@"
  rc=$?
  activity_stop
  return $rc
}

ui_step() {
  if [ "$UI_MODE" = compact ]; then
    printf '[%s/%s] %s\n' "$1" "$2" "$4"
    case "$3" in
      ok) printf '      %b\n' "${GREEN}Status: OK${NC}" ;;
      fail) printf '      %b\n' "${RED}Status: FAILED${NC}" ;;
      wait) printf '      %b\n' "${CYAN}Status: WORKING...${NC}" ;;
      *) printf '      Status: Pending\n' ;;
    esac
  else
    printf ' [%s/%s] %-38.38s ' "$1" "$2" "$4"
    case "$3" in
      ok) printf '%b\n' "${GREEN}[ OK ]${NC}" ;;
      fail) printf '%b\n' "${RED}[FAIL]${NC}" ;;
      wait) printf '%b\n' "${CYAN}[WAIT]${NC}" ;;
      *) echo '[----]' ;;
    esac
  fi
}

# ============================================================
# MODULE 03: COMMAND WRAPPERS (no awk, busybox detection)
# ============================================================

find_bb() {
  for b in busybox /system/xbin/busybox /system/bin/busybox /sbin/busybox /vendor/bin/busybox; do
    if command -v "$b" >/dev/null 2>&1 || [ -f "$b" ]; then
      echo "$b"
      return 0
    fi
  done
  echo ""
}

download_file() {
  url="$1"
  output="$2"
  rm -f "$output"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$output" || { log_event WARNING "TLS verification failed; trying insecure curl fallback"; curl -k -fSL "$url" -o "$output"; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$output" || { log_event WARNING "TLS verification failed; trying insecure wget fallback"; wget --no-check-certificate -q "$url" -O "$output"; }
  else
    bb=$(find_bb)
    if [ -n "$bb" ]; then
      "$bb" wget -q -O "$output" "$url" || { log_event WARNING "TLS verification failed; trying insecure BusyBox wget fallback"; "$bb" wget --no-check-certificate -q -O "$output" "$url"; }
    else
      return 1
    fi
  fi
}

validate_archive() {
  file="$1"
  bb=$(find_bb)
  if [ -n "$bb" ]; then
    "$bb" tar -tzf "$file" >/dev/null 2>&1 && return 0
    "$bb" gzip -t "$file" >/dev/null 2>&1 && return 0
  fi
  tar -tzf "$file" >/dev/null 2>&1 && return 0
  gzip -t "$file" >/dev/null 2>&1 && return 0
  return 1
}

validate_xz_archive() {
  file="$1"
  bb=$(find_bb)
  if [ -n "$bb" ]; then
    "$bb" tar -tJf "$file" >/dev/null 2>&1 && return 0
  fi
  tar -tJf "$file" >/dev/null 2>&1 && return 0
  return 1
}

# ============================================================
# MODULE 04: PREFLIGHT, STORAGE SELECTION, DRY-RUN
# ============================================================

preflight_check() {
  clear_screen
  ui_detect
  ui_title "STEP 1 OF 6: ENVIRONMENT CHECK"
  fail=0

  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64|armv7l|armv7*|armhf)
      ui_status ok "Architecture: $arch"
      ;;
    *)
      ui_status fail "Unsupported architecture: $arch"
      fail=1
      ;;
  esac

  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    ui_status ok "Root privileges available"
  else
    ui_status fail "Root privileges required"
    fail=1
  fi

  if command -v chroot >/dev/null 2>&1; then
    ui_status ok "chroot available"
  else
    ui_status fail "chroot missing"
    fail=1
  fi

  bb=$(find_bb)
  if [ -n "$bb" ]; then
    ui_status ok "BusyBox: $bb"
  else
    ui_status warn "BusyBox not found"
  fi

  dk=$(free_kib /data)
  tk=$(free_kib /data/local/tmp)
  dm=$(human_mib_from_kib "$dk")
  tm=$(human_mib_from_kib "$tk")

  if [ "$dk" -ge 1536000 ] 2>/dev/null; then
    ui_status ok "Free /data: $dm MiB"
  else
    ui_status fail "Free /data: $dm MiB, need 1500 MiB"
    fail=1
  fi

  if [ "$tk" -ge 153600 ] 2>/dev/null; then
    ui_status ok "Free /data/local/tmp: $tm MiB"
  else
    ui_status fail "Free /data/local/tmp: $tm MiB, need 150 MiB"
    fail=1
  fi

  ui_separator '-'
  if [ "$fail" = 0 ]; then
    ui_status ok "RESULT: READY"
    ui_separator '-'
    return 0
  else
    ui_status fail "RESULT: BLOCKED"
    ui_separator '-'
    return 1
  fi
}

dry_run_report() {
  clear_screen
  ui_title "GUARD_OS DRY RUN REPORT"
  case "$(uname -m)" in
    aarch64|arm64) a=arm64 ;;
    armv7*) a=armhf ;;
    *) a=unsupported ;;
  esac
  ui_row "Target" "/data/Guard_OS"
  ui_row "Host Arch" "$(uname -m)"
  ui_row "RootFS Arch" "$a"
  ui_row "RootFS" "Ubuntu Base noble / Alpine Linux"
  ui_row "Storage" "1.5 GiB minimum"
  ui_separator '-'
  ui_status info "Creates Guard_OS_start and Android autostart"
  ui_status ok "Keeps install and Telnet"
  ui_status warn "No changes made"
  ui_pause
}

select_target_dir() {
  clear_screen
  ui_title "STEP 2 OF 6: INSTALLATION TARGET"
  ui_status info "Choose the location for the Guard_OS RootFS"
  printf "\n${YELLOW}  Do you want to install inside default [/data/Guard_OS]? [Y/n]: ${NC}"
  read choice < /dev/tty

  case "$choice" in
    [nN][oO]|[nN])
      printf "\n${YELLOW}  Do you want to create a new folder under [/data]? [Y/n]: ${NC}"
      read sub_choice < /dev/tty
      case "$sub_choice" in
        [yY][eE][sS]|[yY]|"")
          printf "${CYAN}  Enter folder name under /data/ (e.g. Guard_OS): ${NC}"
          read custom_folder < /dev/tty
          if [ -z "$custom_folder" ]; then custom_folder="Guard_OS"; fi
          TARGET_DIR="/data/$custom_folder"
          ;;
        *)
          printf "\n${CYAN}Select storage device:${NC}\n"
          raw_mounts=$(df -h | grep -E '/data$|/mnt/media_rw|/storage/mmcblk|/storage/sdcard|/storage/usb' | grep -v -E 'runtime|tmpfs|sdcard$|emulated')
          if [ -z "$raw_mounts" ]; then
            SELECTED_BASE="/data"
          else
            idx=1
            while read -r fs size used avail use mount; do
              printf " [${GREEN}%d${NC}] %s (Free: %s)\n" "$idx" "$mount" "$avail"
              idx=$((idx+1))
            done << EOF
$raw_mounts
EOF
            printf "\n${YELLOW}  Select Storage Device Number [1-%d]: ${NC}" "$((idx-1))"
            read drive_num < /dev/tty
            if [ -z "$drive_num" ]; then drive_num=1; fi
            SELECTED_BASE=$(echo "$raw_mounts" | sed -n "${drive_num}p" | while read -r fs size used avail use mount; do echo "$mount"; done)
            if [ -z "$SELECTED_BASE" ]; then SELECTED_BASE="/data"; fi
          fi
          printf "\n${CYAN}  Enter folder name to create inside [${YELLOW}%s${CYAN}]: ${NC}" "$SELECTED_BASE"
          read final_folder < /dev/tty
          if [ -z "$final_folder" ]; then final_folder="Guard_OS"; fi
          TARGET_DIR="$SELECTED_BASE/$final_folder"
          ;;
      esac
      ;;
    *)
      TARGET_DIR="/data/Guard_OS"
      ;;
  esac

  case "$TARGET_DIR" in
    /|/data|/system|/vendor|/proc|/sys|/dev|/storage|/mnt)
      print_error "Unsafe target directory: $TARGET_DIR"
      TARGET_DIR=""
      return 1
      ;;
    *)
      ;;
  esac

  mkdir -p "$TARGET_DIR" 2>/dev/null || {
    print_error "Cannot create directory: $TARGET_DIR"
    TARGET_DIR=""
    return 1
  }

  print_success "Selected target: $TARGET_DIR"
  return 0
}

# ============================================================
# MODULE 05: ROOTFS DOWNLOAD & EXTRACTION (ALPINE + UBUNTU)
# ============================================================

detect_architecture() {
  # Enforced ARMv7 Architecture as requested by user
  # This prevents fatal libc mismatch errors on Android boxes where uname returns aarch64 but userland is 32-bit.
  ROOTFS_ARCH="armhf"
  UBUNTU_ARCH="armhf"
  
  # Note for maintainers: If you ever deploy this to a native 64-bit system, uncomment the autodetection below:
  # arch=$(uname -m)
  # case "$arch" in
  #   aarch64|armv8l) ROOTFS_ARCH="aarch64"; UBUNTU_ARCH="arm64" ;;
  #   armv7l|armv6l) ROOTFS_ARCH="armhf"; UBUNTU_ARCH="armhf" ;;
  #   x86_64) ROOTFS_ARCH="x86_64"; UBUNTU_ARCH="amd64" ;;
  #   i*86) ROOTFS_ARCH="x86"; UBUNTU_ARCH="i386" ;;
  #   *) ROOTFS_ARCH="armhf"; UBUNTU_ARCH="armhf" ;;
  # esac
  
  return 0
}

select_channel() {
  clear_screen
  ui_title "STEP 3 OF 6: RELEASE CHANNEL"
  ui_status info "Stable is recommended for normal use"
  ui_menu "1" "Stable Ubuntu Base noble (Recommended)"
  ui_menu "2" "Alpine Linux Minirootfs (Very small, ~5 MiB)"
  printf "\n${YELLOW}  Select [1-2, default 1]: ${NC}"
  read channel_choice < /dev/tty
  case "$channel_choice" in
    2) RELEASE_CHANNEL="alpine" ;;
    *) RELEASE_CHANNEL="stable" ;;
  esac
  return 0
}

download_and_extract_rootfs() {
  clear_screen
  ui_title "STEP 4 OF 6: INSTALLATION REVIEW"
  ui_row "Target" "$TARGET_DIR"
  ui_row "Host Arch" "$(uname -m)"
  ui_row "RootFS Arch" "$ROOTFS_ARCH"
  ui_row "Channel" "$RELEASE_CHANNEL"
  ui_row "Free /data" "$(human_mib_from_kib "$(free_kib /data)") MiB"
  ui_separator '-'
  ui_status ok "install and Telnet will be preserved"
  ui_menu "1" "Start installation"
  ui_menu "0" "Cancel"
  ui_prompt "[0-1]" rv
  if [ "$rv" != "1" ]; then
    ui_status warn "Cancelled"
    ui_pause
    return 0
  fi

  clear_screen
  ui_title "STEP 5 OF 6: INSTALLING GUARD_OS"
  ui_step 1 9 ok "Environment check"
  ui_step 2 9 ok "Target selected"
  ui_step 3 9 ok "Release selected"
  ui_step 4 9 wait "Downloading RootFS"

  # URLs
  STABLE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/ubuntu-base-24.04.3-base-${UBUNTU_ARCH}.tar.gz"
  # Alpine minirootfs (using version 3.19)
  ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/${ROOTFS_ARCH}/alpine-minirootfs-3.24.1-${ROOTFS_ARCH}.tar.gz"

  if [ "$RELEASE_CHANNEL" = "alpine" ]; then
    ROOTFS_URLS="$ALPINE_URL"
  else
    ROOTFS_URLS="$STABLE_URL"
  fi

  set_install_stage "DOWNLOAD" "channel=$RELEASE_CHANNEL"
  download_ok=0

  activity_start "Downloading RootFS"

  for URL in $ROOTFS_URLS; do
    local offline_file=""
    case "$URL" in
      *alpine*) 
        source_name="Alpine Linux"
        ext=".tar.gz"
        validate_func="validate_archive"
        for f in "$(dirname "$0")"/alpine-minirootfs-*.tar.gz /storage/emulated/0/alpine-minirootfs-*.tar.gz /sdcard/Download/alpine-minirootfs-*.tar.gz; do
          if [ -s "$f" ]; then offline_file="$f"; break; fi
        done
        ;;
      *) 
        source_name="Ubuntu Base"
        ext=".tar.gz"
        validate_func="validate_archive"
        for f in "$(dirname "$0")"/ubuntu-base-*.tar.gz /storage/emulated/0/ubuntu-base-*.tar.gz /sdcard/Download/ubuntu-base-*.tar.gz; do
          if [ -s "$f" ]; then offline_file="$f"; break; fi
        done
        ;;
    esac

    ui_status info "Source: $source_name / $ROOTFS_ARCH"
    rm -f "/data/local/tmp/rootfs$ext" "/data/local/tmp/rootfs$ext.part"
    
    if [ -n "$offline_file" ] && [ -s "$offline_file" ]; then
      ui_status info "Using offline file: $(basename "$offline_file")"
      cp "$offline_file" "/data/local/tmp/rootfs$ext.part"
    else
      ui_status warn "Offline file not found locally!"
      local save_path="/storage/emulated/0/${URL##*/}"
      touch "$save_path" 2>/dev/null || save_path="/sdcard/Download/${URL##*/}"
      
      echo -e "\n\033[1;36m[INFO] Offline version not found.\033[0m"
      echo -e "       Downloading from internet and saving to: \033[1;32m$save_path\033[0m"
      echo -e "       (It will be kept for future offline installs!)\n"
      
      download_file "$URL" "$save_path.part"
      if [ -s "$save_path.part" ]; then
        mv "$save_path.part" "$save_path"
        cp "$save_path" "/data/local/tmp/rootfs$ext.part"
      fi
    fi
    if [ -s "/data/local/tmp/rootfs$ext.part" ]; then
      mv "/data/local/tmp/rootfs$ext.part" "/data/local/tmp/rootfs$ext"
    else
      continue
    fi
    size=$(stat -c%s "/data/local/tmp/rootfs$ext" 2>/dev/null || wc -c < "/data/local/tmp/rootfs$ext" 2>/dev/null || echo 0)
    size_mb=$((size/1024/1024))
    ui_status info "Downloaded: $size_mb MiB ($size bytes)"
    if [ "$size" -ge 100000 ] 2>/dev/null && $validate_func "/data/local/tmp/rootfs$ext"; then
      ui_status ok "Valid RootFS: $source_name, $size_mb MiB"
      download_ok=1
      ROOTFS_SOURCE="$source_name"
      ROOTFS_SIZE="$size"
      break
    fi
    ui_status warn "Validation failed; trying fallback"
    rm -f "/data/local/tmp/rootfs$ext"
  done

  activity_stop

  if [ "$download_ok" -ne 1 ]; then
    print_error "All RootFS sources failed validation"
    set_install_stage "DOWNLOAD_FAILED" "archive_validation"
    return 5
  fi

  ui_step 4 9 ok "Downloading RootFS"
  ui_step 5 9 ok "Validating archive"
  ui_step 6 9 wait "Extracting RootFS"

  set_install_stage "EXTRACT" "extracting"
  ui_status wait "Extracting to $TARGET_DIR"

  bb=$(find_bb)
  extract_ok=0
  activity_start "Extracting RootFS (this may take several minutes)"

  # Both are tar.gz now
  if [ -f /data/local/tmp/rootfs.tar.gz ]; then
    if [ -n "$bb" ]; then
      if "$bb" tar -xzf /data/local/tmp/rootfs.tar.gz -C "$TARGET_DIR" 2>/dev/null; then extract_ok=1; fi
    fi
    if [ "$extract_ok" -ne 1 ] && command -v tar >/dev/null 2>&1; then
      if tar -xzf /data/local/tmp/rootfs.tar.gz -C "$TARGET_DIR" 2>/dev/null; then extract_ok=1; fi
    fi
    if [ "$extract_ok" -ne 1 ] && [ -n "$bb" ]; then
      if "$bb" gzip -dc /data/local/tmp/rootfs.tar.gz 2>/dev/null | "$bb" tar -xf - -C "$TARGET_DIR" 2>/dev/null; then extract_ok=1; fi
    fi
  fi

  activity_stop
  rm -f /data/local/tmp/rootfs.tar.gz

  # For Alpine, /bin/sh exists; for Ubuntu, /bin/bash
  if [ ! -f "$TARGET_DIR/bin/bash" ] && [ ! -f "$TARGET_DIR/bin/busybox" ] && [ ! -L "$TARGET_DIR/bin/sh" ]; then
    ui_status fail "RootFS extraction failed or shell is missing"
    set_install_stage "EXTRACT_FAILED" "rootfs_incomplete"
    return 6
  fi

  ui_status ok "RootFS extracted successfully"
  return 0
}

# ============================================================
# MODULE 06: CHROOT SETUP, SSH, SUPERVISOR, AUTOSTART
# ============================================================

prepare_rootfs_dirs() {
  mkdir -p "$TARGET_DIR/etc" "$TARGET_DIR/usr/local/bin" "$TARGET_DIR/root" \
    "$TARGET_DIR/dev/pts" "$TARGET_DIR/proc" "$TARGET_DIR/sys" \
    "$TARGET_DIR/run" "$TARGET_DIR/tmp" "$TARGET_DIR/sdcard" \
    "$TARGET_DIR/var/log/guard-os" "$TARGET_DIR/run/sshd"
  touch "$TARGET_DIR/root/.hushlogin" 2>/dev/null
  chmod 1777 "$TARGET_DIR/tmp"
  chmod 0755 "$TARGET_DIR/run/sshd" 2>/dev/null
}

mount_chroot() {
  [ -e /dev/stdin ] || ln -sf /proc/self/fd/0 /dev/stdin 2>/dev/null
  [ -e /dev/stdout ] || ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null
  [ -e /dev/stderr ] || ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null
  mount -o bind /dev "$TARGET_DIR/dev" 2>/dev/null
  mount -t proc proc "$TARGET_DIR/proc" 2>/dev/null
  mount -t sysfs sysfs "$TARGET_DIR/sys" 2>/dev/null
  mount -t devpts devpts "$TARGET_DIR/dev/pts" 2>/dev/null
  mkdir -p "$TARGET_DIR/dev/shm" 2>/dev/null
  mount -t tmpfs tmpfs "$TARGET_DIR/dev/shm" 2>/dev/null
}

setup_network_config() {
  # For Alpine, we need /etc/resolv.conf
  rm -f "$TARGET_DIR/etc/resolv.conf"
  echo "nameserver 1.1.1.1" > "$TARGET_DIR/etc/resolv.conf"
  echo "nameserver 8.8.8.8" >> "$TARGET_DIR/etc/resolv.conf"
  echo "Guard_OS" > "$TARGET_DIR/etc/hostname"
  cat > "$TARGET_DIR/etc/hosts" <<EOF
127.0.0.1 localhost Guard_OS
::1 localhost ip6-localhost ip6-loopback
EOF
}

install_base_packages() {
  ui_step 6 9 ok "Extracting RootFS"
  ui_step 7 9 wait "Installing base packages"
  set_install_stage "BASE_PACKAGES" "pkg_install"
  ui_status wait "Configuring package manager and base system (this can take several minutes)"

  # Determine if Alpine or Ubuntu
  if [ -f "$TARGET_DIR/etc/alpine-release" ]; then
    # Alpine system
    ui_status info "Alpine detected; using apk"
    activity_start "Installing base packages (apk)"
    chroot "$TARGET_DIR" /bin/sh -c "
      unset LD_LIBRARY_PATH
      export TMPDIR=/tmp
      apk update
      apk add openssh openssh-server openssh-client curl wget tar gzip procps iproute2 net-tools nano less openssl sudo tzdata bash shadow
      apk add mawk || apk add awk
      addgroup -g 3003 inet 2>/dev/null || true
      addgroup -g 3004 net_raw 2>/dev/null || true
      addgroup root inet 2>/dev/null || true
      addgroup root net_raw 2>/dev/null || true
      addgroup sshd inet 2>/dev/null || true
      addgroup sshd net_raw 2>/dev/null || true
      echo 'root:tv' | /usr/sbin/chpasswd || echo -e "tv\ntv" | passwd root
      mkdir -p /run/sshd /var/run/sshd /var/log/guard-os
      chmod 0755 /run/sshd /var/run/sshd
      # Generate host keys
      ssh-keygen -A
      # Configure sshd
      sed -i '/^PermitRootLogin/d; /^PasswordAuthentication/d' /etc/ssh/sshd_config 2>/dev/null
      echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
      echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
      sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
      echo 'StrictModes no' >> /etc/ssh/sshd_config
      echo 'TCPKeepAlive yes' >> /etc/ssh/sshd_config
      echo 'ClientAliveInterval 60' >> /etc/ssh/sshd_config
      echo 'ClientAliveCountMax 10' >> /etc/ssh/sshd_config
      echo 'PrintMotd no' >> /etc/ssh/sshd_config
      echo 'UseDNS no' >> /etc/ssh/sshd_config
      sshd -t || exit 41
    " > "$TARGET_DIR/var/log/guard-os/base-install.log" 2>&1
    base_rc=$?
    activity_stop
  else
    # Ubuntu system
    local codename="noble"
    if [ -f "$TARGET_DIR/etc/os-release" ]; then
      local detected=$(grep "^VERSION_CODENAME=" "$TARGET_DIR/etc/os-release" | cut -d= -f2)
      [ -n "$detected" ] && codename="$detected"
    fi
    cat > "$TARGET_DIR/etc/apt/sources.list" <<SOURCES
deb http://ports.ubuntu.com/ubuntu-ports $codename main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports $codename-updates main restricted universe multiverse
SOURCES
    # Remove deb822 sources format to prevent duplicate warnings in 24.04+
    rm -f "$TARGET_DIR/etc/apt/sources.list.d/ubuntu.sources"

    activity_start "Installing base packages (apt update + install)"
    chroot "$TARGET_DIR" /bin/bash -c "
      unset LD_LIBRARY_PATH
      export DEBIAN_FRONTEND=noninteractive
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
      export TMPDIR=/tmp
      export TERM=xterm
      mkdir -p /tmp /run/sshd /var/run/sshd /var/log/guard-os
      chmod 0755 /run/sshd /var/run/sshd 2>/dev/null
      chmod 1777 /tmp

      groupadd -g 3003 inet 2>/dev/null || true
      groupadd -g 3004 net_raw 2>/dev/null || true
      usermod -a -G inet,net_raw root 2>/dev/null || true
      usermod -a -G inet,net_raw _apt 2>/dev/null || true

      echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
      chmod +x /usr/sbin/policy-rc.d

      echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox-root

      # Pre-create SSH keys to prevent ssh-keygen from hanging in dpkg postinst on some Android devices
      mkdir -p /etc/ssh
      touch /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ed25519_key
      
      apt-get update -y
      apt-get install -y --no-install-recommends \
        ca-certificates curl wget tar gzip xz-utils procps iproute2 net-tools dnsutils \
        nano less openssh-server openssh-client openssl sudo locales tzdata \
        mawk passwd

      usermod -a -G inet,net_raw sshd 2>/dev/null || true
      chmod 4755 /bin/ping 2>/dev/null || chmod 4755 /usr/bin/ping 2>/dev/null || true

      TZ_AREA=\$(curl -s http://ip-api.com/line?fields=timezone 2>/dev/null)
      [ -z \"\$TZ_AREA\" ] && TZ_AREA=\"Africa/Cairo\"
      ln -sf \"/usr/share/zoneinfo/\$TZ_AREA\" /etc/localtime 2>/dev/null || true
      echo \"\$TZ_AREA\" > /etc/timezone 2>/dev/null || true

      locale-gen en_US.UTF-8 2>/dev/null || true
      update-locale LANG=en_US.UTF-8 2>/dev/null || true

      echo 'root:tv' | /usr/sbin/chpasswd || echo -e "tv\ntv" | passwd root

      [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key
      [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key
      [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key

      sed -i '/^PermitRootLogin/d; /^PasswordAuthentication/d; /^UsePAM/d; /^StrictModes/d; /^UseDNS/d' /etc/ssh/sshd_config 2>/dev/null
      cat >> /etc/ssh/sshd_config <<'SSHCFG'
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
StrictModes no
TCPKeepAlive yes
ClientAliveInterval 60
UseDNS no
ClientAliveCountMax 10
PrintMotd no
SSHCFG

      mkdir -p /run/sshd /var/run/sshd
      chmod 0755 /run/sshd /var/run/sshd
      /usr/sbin/sshd -t || exit 41
    " > "$TARGET_DIR/var/log/guard-os/base-install.log" 2>&1
    base_rc=$?
    activity_stop

    if [ $base_rc -ne 0 ] || [ ! -x "$TARGET_DIR/usr/sbin/sshd" ]; then
      ui_status warn "Base install failed or sshd missing; attempting repair"
      activity_start "Repairing packages"
      chroot "$TARGET_DIR" /bin/bash -c "
        unset LD_LIBRARY_PATH
        export TMPDIR=/tmp
        export DEBIAN_FRONTEND=noninteractive
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
        dpkg --configure -a
        apt-get update -y
        apt-get install -f -y
        apt-get install -y --no-install-recommends openssh-server openssh-client mawk passwd
        mkdir -p /run/sshd /var/run/sshd
        chmod 0755 /run/sshd /var/run/sshd
        [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key
        [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key
        [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
        sed -i 's/^#UseDNS.*/UseDNS no/' /etc/ssh/sshd_config 2>/dev/null || echo 'UseDNS no' >> /etc/ssh/sshd_config
        echo 'root:tv' | /usr/sbin/chpasswd || echo -e \"tv\ntv\" | passwd root
        /usr/sbin/sshd -t || exit 42
      " >> "$TARGET_DIR/var/log/guard-os/base-install.log" 2>&1
      repair_rc=$?
      activity_stop
      if [ $repair_rc -ne 0 ] || [ ! -x "$TARGET_DIR/usr/sbin/sshd" ]; then
        ui_status fail "OpenSSH Server installation failed"
        set_install_stage "SSH_INSTALL_FAILED" "sshd_binary_missing"
        return 9
      fi
    fi
  fi

  ui_status ok "Base packages installed"
  return 0
}

# ============================================================
# MODULE 07: CONTROL CENTER (setup script)
# ============================================================
# ============================================================


# ============================================================





create_control_center_scripts() {
  # guard-os-welcome
  cat > "$TARGET_DIR/usr/local/bin/guard-os-welcome" <<'WELCOMEEOF'
#!/bin/sh
[ -t 1 ] || exit 0
cfg=/etc/guard-os-welcome.conf
[ -r "$cfg" ] && . "$cfg"
[ "${WELCOME_LOGO:-enabled}" = enabled ] || exit 0
version=$(sed -n 's/^VERSION=//p' /etc/guard-os-release 2>/dev/null | head -1)
[ -n "$version" ] || version=3.1.0
if [ -f /etc/os-release ]; then
  sys_name=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
else
  sys_name="Linux $(uname -m)"
fi
host=$(hostname 2>/dev/null); [ -n "$host" ] || host=Guard_OS
arch=$(uname -m 2>/dev/null)
ip=$(ip addr 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
[ -n "$ip" ] || ip=N/A
ssh_state=STOPPED
pidof sshd >/dev/null 2>&1 && ssh_state=RUNNING
spid=$(cat /run/guard-os-autostart.pid 2>/dev/null)
[ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && supervisor="RUNNING PID $spid" || supervisor=STOPPED

mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
mem_used=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
ram_info="${mem_used:-0}MB / ${mem_total:-0}MB"
temp_val="N/A (No Sensor)"
for tf in /sys/class/thermal/thermal_zone*/temp /sys/devices/virtual/thermal/thermal_zone*/temp; do
  if [ -f "$tf" ]; then
    t=$(cat "$tf" 2>/dev/null)
    [ -n "$t" ] && [ "$t" -gt 1000 ] 2>/dev/null && t=$((t / 1000))
    [ -n "$t" ] && temp_val="${t} C" && break
  fi
done

printf '%s\n' '=========================================================='
printf '%s\n' '                         GUARD_OS'
printf '%s\n' '=========================================================='
printf '%s\n' '          Android TV Linux Management Platform'
printf '\n'
printf ' %-12s: %s\n' 'Version' "$version Stable"
printf ' %-12s: %s\n' 'System' "$sys_name"
printf ' %-12s: %s\n' 'Hostname' "$host"
printf ' %-12s: %s\n' 'Architecture' "$arch"
printf ' %-12s: %s\n' 'IP Address' "$ip"
printf ' %-12s: %s\n' 'CPU Temp' "$temp_val"
printf ' %-12s: %s\n' 'RAM Usage' "$ram_info"
printf ' %-12s: %s\n' 'SSH' "$ssh_state"
printf ' %-12s: %s\n' 'Supervisor' "$supervisor"
printf ' %-12s: %s\n' 'Creator' 'Ashraf Saber'
printf '%s\n' '----------------------------------------------------------'
printf ' %-12s: %s\n' 'Status' 'READY'
printf ' %-12s: %s\n' 'Control' 'Type tv or setup'
printf ' %-12s: %s\n' 'Help' 'Type setup --help'
printf '%s\n' '=========================================================='
WELCOMEEOF
  chmod 755 "$TARGET_DIR/usr/local/bin/guard-os-welcome"

  cat > "$TARGET_DIR/etc/guard-os-welcome.conf" <<WELCOMECFG
WELCOME_LOGO=enabled
WELCOMECFG
  chmod 644 "$TARGET_DIR/etc/guard-os-welcome.conf"

  # .bashrc and .bash_profile
  cat > "$TARGET_DIR/root/.bash_profile" <<'BASHPROFILE'
if [ -f ~/.bashrc ]; then
  . ~/.bashrc
fi
BASHPROFILE

  cat > "$TARGET_DIR/root/.profile" <<'PROFILE'
if [ -f ~/.bashrc ]; then
  . ~/.bashrc
fi
PROFILE

  cat > "$TARGET_DIR/root/.bashrc" <<'BASHRC'
export TERM=xterm
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PS1="\[\033[1;32m\]Guard_OS# \[\033[0m\]"
alias ls='ls --color=auto'
alias ll='ls -l'
if [ -t 0 ] && [ -t 1 ] && [ -z "${GUARD_OS_WELCOME_SHOWN:-}" ]; then
  export GUARD_OS_WELCOME_SHOWN=1
  [ -x /usr/local/bin/guard-os-welcome ] && /usr/local/bin/guard-os-welcome
fi
BASHRC

  # ============================================================
  # SUPERVISOR & WATCHDOG DAEMONS
  # ============================================================
  cat > "$TARGET_DIR/usr/local/bin/tv_watchdog.sh" <<'WDGEOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
get_cfg() {
  key=$1
  val=$(grep "^${key}=" /etc/tv_autostart.conf 2>/dev/null | cut -d= -f2 | tr -d '\r\n')
  [ -z "$val" ] && val="enabled"
  echo "$val"
}
mkdir -p /run/sshd /var/run/sshd 2>/dev/null
chmod 0755 /run/sshd 2>/dev/null || true

for k in SSH ADGUARD SAMBA ZEROTIER DNSCRYPT NGINX IPERF3 NODERED HASS MOTIONEYE TTYD; do
  if [ "$(get_cfg "$k")" = "enabled" ]; then
    /usr/local/bin/setup start "$k" >/dev/null 2>&1
  fi
done

# Improvement 1: Log Rotation (Truncate logs > 5MB)
find /var/log -type f -size +5M -exec truncate -s 0 {} \; 2>/dev/null

WDGEOF
  chmod 755 "$TARGET_DIR/usr/local/bin/tv_watchdog.sh"

  # tv_autostart.sh (supervisor)
  cat > "$TARGET_DIR/usr/local/bin/tv_autostart.sh" <<'RUNSTARTEOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
LOCKDIR=/run/guard-os-autostart.lock
PIDFILE=/run/guard-os-autostart.pid
LOGFILE=/var/log/guard-os/autostart.log
mkdir -p /run /var/log/guard-os
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  old_pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    exit 0
  fi
  rm -rf "$LOCKDIR" "$PIDFILE" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$PIDFILE"
cleanup_autostart() {
  rm -f "$PIDFILE" 2>/dev/null
  rmdir "$LOCKDIR" 2>/dev/null || true
}
trap cleanup_autostart EXIT INT TERM HUP

sleep 3
hostname Guard_OS 2>/dev/null || true
mkdir -p /run/sshd /var/run/sshd 2>/dev/null
chmod 0755 /run/sshd 2>/dev/null || true
[ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key 2>/dev/null
[ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key 2>/dev/null
[ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key 2>/dev/null
printf '%s supervisor started pid=%s\n' "$(date '+%F %T')" "$$" >> "$LOGFILE" 2>/dev/null

while :; do
  /usr/local/bin/tv_watchdog.sh >> "$LOGFILE" 2>&1
  sleep 60
done
RUNSTARTEOF
  chmod 755 "$TARGET_DIR/usr/local/bin/tv_autostart.sh"

  # guard-os-release
  cat > "$TARGET_DIR/etc/guard-os-release" <<RELEASEEOF
NAME=Guard_OS
VERSION=$VERSION
CHANNEL=stable
ROOTFS=$([ "$RELEASE_CHANNEL" = "alpine" ] && echo "Alpine_Mini" || echo "Ubuntu_noble")
CREATOR=Ashraf_Saber
DEFAULT_PASSWORD=tv
ADGUARD_DEFAULT_USERNAME=admin
ADGUARD_DEFAULT_PASSWORD=admin
WELCOME_LOGO=enabled
PROJECT_STATUS=complete
RELEASEEOF
  chmod 644 "$TARGET_DIR/etc/guard-os-release"

  # tv_autostart.conf
  cat > "$TARGET_DIR/etc/tv_autostart.conf" <<CFGEOF
SSH=enabled
ADGUARD=disabled
SAMBA=disabled
ZEROTIER=disabled
DNSCRYPT=disabled
NGINX=disabled
IPERF3=disabled
NODERED=disabled
TTYD=enabled
CFGEOF
  chmod 644 "$TARGET_DIR/etc/tv_autostart.conf"

  # install_manifest.log
  cat > "$TARGET_DIR/install_manifest.log" <<MANIFESTEOF
INSTALL_DIR=$TARGET_DIR
CREATED_HOST_BIN=/system/bin/Guard_OS_start
CREATED_HOST_STOP=/system/bin/Guard_OS_stop
CREATED_HOST_RESTART=/system/bin/Guard_OS_restart
AUTOSTART_FILE=/system/etc/install-recovery.sh
EXCLUDED_PROTECTED=/system/bin/install
MANIFESTEOF

  # guard-os-maintenance
  cat > "$TARGET_DIR/usr/local/bin/guard-os-maintenance" <<'MAINEOF2'
#!/bin/bash
LOGDIR=/var/log/guard-os
mkdir -p "$LOGDIR"
rotate_one(){ f="$1"; max="$2"; [ -f "$f" ] || return 0; size=$(wc -c < "$f" 2>/dev/null); [ "${size:-0}" -le "$max" ] && return 0; rm -f "$f.1"; mv "$f" "$f.1"; : > "$f"; }
rotate_one "$LOGDIR/autostart.log" 1048576
rotate_one "$LOGDIR/ssh-start.log" 524288
rotate_one "$LOGDIR/control.log" 1048576
rotate_one "$LOGDIR/installer.log" 2097152
rotate_one "$LOGDIR/repair.log" 1048576
count=0
for b in $(ls -1t /sdcard/Guard_OS_backup_*.tar.gz 2>/dev/null); do
  count=$((count+1)); [ "$count" -gt 3 ] && rm -f "$b"
done
exit 0
MAINEOF2
  chmod 755 "$TARGET_DIR/usr/local/bin/guard-os-maintenance"

  # guard-os-verify
  cat > "$TARGET_DIR/usr/local/bin/guard-os-verify" <<'VERIFYEOF'
#!/bin/bash
FILE=/etc/guard-os-checksums.sha256
[ -f "$FILE" ] || { echo "Checksum file missing"; exit 1; }
cd / || exit 1
sha256sum -c "$FILE"
VERIFYEOF
  chmod 755 "$TARGET_DIR/usr/local/bin/guard-os-verify"

  # README
  cat > "$TARGET_DIR/root/Guard_OS_README.txt" <<READMEEOF
Guard_OS $VERSION
=====================
Control Center : setup or tv
Login Logo     : tv > [L] Login Appearance
Health Check   : setup health
Full Report    : setup report
Logs           : setup logs
Host start     : Guard_OS_start
Normal stop    : Guard_OS_stop
Full stop      : Guard_OS_stop --with-ssh
Restart        : Guard_OS_restart
Default SSH    : root / tv
Run full stop from Android Telnet, not from the active SSH session.
READMEEOF
  chmod 600 "$TARGET_DIR/root/Guard_OS_README.txt"

  cat > "$TARGET_DIR/usr/local/bin/setup" <<'SETUPMAIN'
#!/bin/bash
export TMPDIR=/tmp
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

if ! command -v apt-get >/dev/null 2>&1; then
  apt-get() {
    case "$1" in
      update) apk update ;;
      install) shift; shift; apk add "$@" 2>/dev/null || true ;;
      clean) apk cache clean ;;
    esac
  }
  dpkg() { true; }
  dpkg-query() { apk info; }
fi

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TERM=xterm
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'
BOLD='\033[1m'


# ============================================================
# UI CONTROLS & UTILITIES
# ============================================================
clear_screen() { printf '\033[2J\033[3J\033[H'; command -v clear >/dev/null 2>&1 && clear; }
pkg_install() {
  if command -v apk >/dev/null 2>&1; then
    apk add "$@"
  else
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get update >/dev/null 2>&1
    apt-get -qq install -y "$@" >/dev/null 2>&1
  fi
}
print_line() { echo -e "${CYAN}========================================${NC}"; }
print_header() { clear_screen; print_line; echo -e "${BOLD}${WHITE}$1${NC}"; print_line; }
print_menu_item() { printf "  ${GREEN}[%s]${NC} %s\n" "$1" "$2"; }
print_info() { echo -e "  ${CYAN}${NC} ${YELLOW}$1${NC} : ${WHITE}$2${NC}"; }
print_success() { echo -e "  ${GREEN}${NC} $1"; }
print_error() { echo -e "  ${RED}${NC} $1"; }
print_warning() { echo -e "  ${YELLOW}${NC} $1"; }
ui_pause() { echo; echo -e -n "${YELLOW}Press ENTER to continue...${NC}"; read dummy < /dev/tty; }
invalid_choice(){ print_warning "Invalid choice"; sleep 1; }

get_local_ip() {
  ip=$(ip addr 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -n 1)
  [ -z "$ip" ] && ip="127.0.0.1"
  echo "$ip"
}


# ============================================================
# SERVICE STATE MANAGERS
# ============================================================
svc_auto() {
  v=$(grep "^$1=" /etc/tv_autostart.conf 2>/dev/null | tail -1 | cut -d= -f2)
  [ "$v" = enabled ] && echo ON || echo OFF
}
set_auto() {
  sed -i "/^$1=/d" /etc/tv_autostart.conf 2>/dev/null
  echo "$1=$2" >> /etc/tv_autostart.conf
}
svc_state() {
  if ! svc_installed "$1"; then echo 'Not Installed'; elif svc_running "$1"; then echo Running; else echo Stopped; fi
}
# ============================================================
# GUARD_OS SERVICE REGISTRY MATRIX (PROFESSIONAL EDITION)
# ============================================================
# Format: KEY | DISPLAY_NAME | PORT | CHECK_FILE | START_COMMAND | STOP_COMMAND | TEST_COMMAND
# ============================================================
SERVICE_REGISTRY="
SSH^OpenSSH^22^/usr/sbin/sshd^mkdir -p /run/sshd; chmod 755 /run/sshd; /usr/sbin/sshd -t && { pgrep -x sshd >/dev/null || /usr/sbin/sshd; }^pkill -TERM -x sshd^/usr/sbin/sshd -t^
ADGUARD^AdGuard Home^53,80^/opt/AdGuardHome/AdGuardHome^cd /opt/AdGuardHome && nohup ./AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome >/dev/null 2>&1 &^pkill -TERM -x AdGuardHome^[ -s /opt/AdGuardHome/AdGuardHome.yaml ]^install_adg
SAMBA^Samba^139,445^/usr/sbin/smbd^smbd -D; nmbd -D^pkill -TERM -x smbd; pkill -TERM -x nmbd^testparm -s >/dev/null^install_smb
ZEROTIER^ZeroTier^9993^zerotier-one^zerotier-one -d >/dev/null 2>&1 &^pkill -TERM -x zerotier-one^^install_zerotier
DNSCRYPT^DNSCrypt^5353^dnscrypt-proxy^dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/dev/null 2>&1 &^pkill -TERM -x dnscrypt-proxy^[ -s /etc/dnscrypt-proxy/dnscrypt-proxy.toml ]^install_dnscrypt
NGINX^Nginx^80,443^nginx^nginx^nginx -s quit 2>/dev/null || pkill -TERM -x nginx^nginx -t^install_nginx
IPERF3^iPerf3^5201^iperf3^iperf3 -s -p 5201 -D^pkill -TERM -x iperf3^^install_iperf3
NODERED^Node-RED^1880^node-red^nohup node-red >/dev/null 2>&1 &^pkill -TERM -f node-red^^install_nodered
HASS^Home Assistant^8123^/opt/homeassistant/bin/hass^nohup /opt/homeassistant/bin/hass -c /root/.homeassistant >/dev/null 2>&1 &^pkill -TERM -f "opt/homeassistant/bin/hass"^^install_hass
MOTIONEYE^MotionEye^8765^/opt/motioneye/bin/meyectl^nohup /opt/motioneye/bin/meyectl startserver -c /etc/motioneye/motioneye.conf >/dev/null 2>&1 &^pkill -TERM -f meyectl^^install_motioneye
TTYD^ttyd^7681^ttyd^env TERM=xterm LANG=C.UTF-8 ttyd -t 'theme={"background": "black"}' -p 7681 -c root:tv -W bash -c \"export LANG=C.UTF-8; export TERM=xterm; /usr/local/bin/setup\" >/dev/null 2>&1 &^pkill -TERM -x ttyd^^install_ttyd
"


# ============================================================
# DYNAMIC SERVICE ENGINE (CORE)
# ============================================================
get_svc_field() { echo "$SERVICE_REGISTRY" | grep "^$1^" | awk -F'^' -v f="$2" '{print $f}'; }
svc_name() { get_svc_field "$1" 2; }
svc_ports() { get_svc_field "$1" 3; }
svc_installed() { 
  f=$(get_svc_field "$1" 4); [ -z "$f" ] && return 1
  if echo "$f" | grep -q "^/"; then [ -x "$f" ]; else command -v "$f" >/dev/null 2>&1; fi
}
svc_running() { p="$(get_svc_field "$1" 4)"; b="$(basename "$p")"; pidof "$b" >/dev/null 2>&1 || pgrep -f "$p" >/dev/null 2>&1; }
svc_start() { if ! svc_running "$1"; then cmd=$(get_svc_field "$1" 5); [ -n "$cmd" ] && eval "$cmd"; sleep 1; fi; }
svc_stop() { cmd=$(get_svc_field "$1" 6); [ -n "$cmd" ] && eval "$cmd"; sleep 1; }
svc_test() { chk=$(get_svc_field "$1" 7); if [ -n "$chk" ]; then eval "$chk"; else svc_installed "$1"; fi; }
operation_result(){ print_header "OPERATION RESULT"; print_info Operation "$1"; print_info Result "$2"; [ -n "$3" ] && print_info Log "$3"; print_line; ui_pause; }

SERVICES="SSH ADGUARD SAMBA ZEROTIER DNSCRYPT NGINX IPERF3 NODERED HASS MOTIONEYE TTYD"
OPTIONAL_SERVICES="ADGUARD SAMBA ZEROTIER DNSCRYPT NGINX IPERF3 NODERED HASS MOTIONEYE TTYD"

service_detail_menu() {
  k=$1
  while :; do
    print_header "SERVICE: $(svc_name $k)"
    print_info Installed "$(svc_installed $k && echo Yes || echo No)"
    print_info Status "$(svc_state $k)"
    print_info Autostart "$(svc_auto $k)"
    print_info Ports "$(svc_ports $k)"
    svc_test $k >/dev/null 2>&1 && ct=Passed || ct=Failed
    print_info 'Config Test' "$ct"
    print_line
    print_menu_item 1 Start
    print_menu_item 2 Stop
    print_menu_item 3 Restart
    print_menu_item 4 'Enable Autostart'
    print_menu_item 5 'Disable Autostart'
    print_menu_item 6 'Health Check'
    print_menu_item 7 'View Log'
    print_menu_item 8 'Test Configuration'
    print_menu_item 9 'Service Settings'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) svc_installed $k && { svc_start $k; operation_result "Start $(svc_name $k)" "$(svc_state $k)"; } || { print_warning 'Not installed'; ui_pause; } ;;
      2) svc_stop $k; operation_result "Stop $(svc_name $k)" "$(svc_state $k)";;
      3) svc_stop $k; svc_start $k; operation_result "Restart $(svc_name $k)" "$(svc_state $k)";;
      4) svc_installed $k && { set_auto $k enabled; operation_result 'Enable Autostart' SUCCESS; } || { print_warning 'Service is not installed'; ui_pause; } ;;
      5) set_auto $k disabled; operation_result 'Disable Autostart' SUCCESS;;
      6) svc_test $k && operation_result 'Health Check' PASSED || operation_result 'Health Check' FAILED;;
      7) lf="/var/log/guard-os/$(echo $k | tr A-Z a-z).log"; clear_screen; tail -n120 "$lf" 2>/dev/null || echo 'No service log'; ui_pause;;
      8) svc_test $k; operation_result 'Configuration Test' "$([ $? = 0 ] && echo PASSED || echo FAILED)";;
      9) service_settings_menu "$k";;
      0) return;;
      *) invalid_choice;;
    esac
  done
}

service_settings_menu() {
  k="$1"
  case "$k" in
    SSH) ssh_settings ;;
    ADGUARD) adg_edit_settings ;;
    SAMBA) samba_settings ;;
    ZEROTIER) zerotier_settings ;;
    DNSCRYPT) dnscrypt_settings ;;
    NGINX) nginx_settings ;;
    IPERF3) iperf3_settings ;;
    NODERED) nodered_settings ;;
    TTYD) ttyd_settings ;;
    *) print_warning "No settings available for this service"; ui_pause ;;
  esac
}

ssh_settings() {
  while :; do
    print_header "SSH SETTINGS"
    print_info Port "$(grep '^Port ' /etc/ssh/sshd_config 2>/dev/null | cut -d' ' -f2 || echo 22)"
    print_info 'Root Login' "$(grep '^PermitRootLogin ' /etc/ssh/sshd_config 2>/dev/null | cut -d' ' -f2 || echo yes)"
    print_info 'Password Auth' "$(grep '^PasswordAuthentication ' /etc/ssh/sshd_config 2>/dev/null | cut -d' ' -f2 || echo yes)"
    print_line
    print_menu_item 1 'Change Port'
    print_menu_item 2 'Change Root Password'
    print_menu_item 3 'Regenerate Host Keys'
    print_menu_item 4 'Test Configuration'
    print_menu_item 5 'Restart SSH'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New SSH port [1-65535]: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid port"; sleep 1; continue;; esac; [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { print_warning "Invalid range"; sleep 1; continue; }; sed -i "/^Port /d" /etc/ssh/sshd_config; echo "Port $port" >> /etc/ssh/sshd_config; svc_start SSH; operation_result "SSH Port" "Changed to $port" ;;
      2) echo -n "New Root Password: "; stty -echo; read pass; stty echo; echo; echo "root:$pass" | /usr/sbin/chpasswd 2>/dev/null && operation_result "SSH Password" "Changed successfully" || print_error "Failed to change password"; ui_pause ;;
      3) /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key; /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key; /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key; operation_result "SSH Keys" "Regenerated" ;;
      4) /usr/sbin/sshd -t && operation_result "SSH Test" PASSED || operation_result "SSH Test" FAILED ;;
      5) svc_stop SSH; svc_start SSH; operation_result "SSH Restart" "$(svc_state SSH)" ;;
      0) return ;;
    esac
  done
}

samba_settings() {
  while :; do
    print_header "SAMBA SETTINGS"
    print_info Workgroup "$(grep '^   workgroup = ' /etc/samba/smb.conf 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo WORKGROUP)"
    print_info 'Server Name' "$(grep '^   server string = ' /etc/samba/smb.conf 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo TVBox)"
    print_info 'Public Mode' "$(grep '^   guest ok = ' /etc/samba/smb.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ' | grep -q yes && echo Yes || echo No)"
    print_line
    print_menu_item 1 'Toggle Public/Private Mode'
    print_menu_item 2 'Change Workgroup'
    print_menu_item 3 'Change Server Name'
    print_menu_item 4 'Change Password for Samba User'
    print_menu_item 5 'Validate with testparm'
    print_menu_item 6 'Restart Samba'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) current=$(grep '^   guest ok = ' /etc/samba/smb.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' '); if [ "$current" = "yes" ]; then sed -i 's/^   guest ok = yes/   guest ok = no/g; s/^   guest account = nobody/   guest account = root/g; s/^   map to guest = Bad User/   map to guest = never/g; /^#   valid users =/s/^#//' /etc/samba/smb.conf; else sed -i 's/^   guest ok = no/   guest ok = yes/g; s/^   guest account = root/   guest account = nobody/g; s/^   map to guest = never/   map to guest = Bad User/g; /^   valid users =/s/^/#/' /etc/samba/smb.conf; fi; operation_result "Samba Mode" "Toggled" ;;
      2) echo -n "New Workgroup: "; read wg; [ -z "$wg" ] && wg=WORKGROUP; sed -i "s|^   workgroup = .*|   workgroup = $wg|g" /etc/samba/smb.conf; operation_result "Workgroup" "Changed to $wg" ;;
      3) echo -n "New Server Name: "; read sn; [ -z "$sn" ] && sn=TVBox; sed -i "s|^   server string = .*|   server string = $sn|g" /etc/samba/smb.conf; operation_result "Server Name" "Changed to $sn" ;;
      4) echo -n "Enter Samba Username: "; read user; [ -z "$user" ] && user=admin; echo -n "New Password: "; stty -echo; read pass; stty echo; echo; (echo "$pass"; echo "$pass") | smbpasswd -s -a "$user" 2>/dev/null && operation_result "Samba Password" "Changed for $user" || print_error "Failed to change password"; ui_pause ;;
      5) testparm -s >/dev/null && operation_result "testparm" PASSED || operation_result "testparm" FAILED ;;
      6) svc_stop SAMBA; svc_start SAMBA; operation_result "Samba Restart" "$(svc_state SAMBA)" ;;
      0) return ;;
    esac
  done
}

zerotier_settings() {
  while :; do
    print_header "ZEROTIER SETTINGS"
    nodeid=$(zerotier-cli info 2>/dev/null | cut -d' ' -f3)
    print_info 'Node ID' "${nodeid:-Unknown}"
    print_info Status "$(zerotier-cli info 2>/dev/null | cut -d' ' -f5 || echo offline)"
    print_line
    print_menu_item 1 'Show Node ID'
    print_menu_item 2 'Join Network'
    print_menu_item 3 'Leave Network'
    print_menu_item 4 'List Networks'
    print_menu_item 5 'Restart ZeroTier'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) zerotier-cli info; ui_pause ;;
      2) echo -n "Enter Network ID (16 hex chars): "; read netid; if [ ${#netid} -ne 16 ]; then print_warning "Invalid network ID"; sleep 1; else zerotier-cli join "$netid" && operation_result "Join Network" "Joined $netid" || operation_result "Join Network" FAILED; fi ;;
      3) echo -n "Enter Network ID to leave: "; read netid; zerotier-cli leave "$netid" && operation_result "Leave Network" "Left $netid" || operation_result "Leave Network" FAILED ;;
      4) zerotier-cli listnetworks; ui_pause ;;
      5) svc_stop ZEROTIER; svc_start ZEROTIER; operation_result "ZeroTier Restart" "$(svc_state ZEROTIER)" ;;
      0) return ;;
    esac
  done
}

dnscrypt_settings() {
  cfg="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  while :; do
    print_header "DNSCRYPT SETTINGS"
    port=$(grep '^listen_addresses = ' "$cfg" 2>/dev/null | cut -d'[' -f2 | cut -d']' -f1 | cut -d':' -f2 | tr -d "'" || echo 5353)
    print_info 'Listen Port' "$port"
    print_info 'DNSSEC Required' "$(grep '^  require_dnssec = ' "$cfg" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo false)"
    print_info Cache Enabled "$(grep '^  cache = ' "$cfg" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo true)"
    print_line
    print_menu_item 1 'Change Listen Port'
    print_menu_item 2 'Toggle DNSSEC Requirement'
    print_menu_item 3 'Toggle Cache'
    print_menu_item 4 'Validate Configuration'
    print_menu_item 5 'Restart DNSCrypt'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New port [1-65535]: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid port"; sleep 1; continue;; esac; [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { print_warning "Invalid range"; sleep 1; continue; }; sed -i "s/listen_addresses = .*/listen_addresses = ['0.0.0.0:$port']/g" "$cfg"; operation_result "DNSCrypt Port" "Changed to $port" ;;
      2) current=$(grep '^  require_dnssec = ' "$cfg" 2>/dev/null | cut -d= -f2 | tr -d ' '); if [ "$current" = "true" ]; then sed -i 's/^  require_dnssec = true/  require_dnssec = false/g' "$cfg"; else sed -i 's/^  require_dnssec = false/  require_dnssec = true/g' "$cfg"; fi; operation_result "DNSSEC" "Toggled" ;;
      3) current=$(grep '^  cache = ' "$cfg" 2>/dev/null | cut -d= -f2 | tr -d ' '); if [ "$current" = "true" ]; then sed -i 's/^  cache = true/  cache = false/g' "$cfg"; else sed -i 's/^  cache = false/  cache = true/g' "$cfg"; fi; operation_result "Cache" "Toggled" ;;
      4) dnscrypt-proxy -config "$cfg" -check && operation_result "DNSCrypt Validate" PASSED || operation_result "DNSCrypt Validate" FAILED ;;
      5) svc_stop DNSCRYPT; svc_start DNSCRYPT; operation_result "DNSCrypt Restart" "$(svc_state DNSCRYPT)" ;;
      0) return ;;
    esac
  done
}

nginx_settings() {
  while :; do
    print_header "NGINX SETTINGS"
    print_info 'HTTP Port' "$(grep -E '^[[:space:]]*listen[[:space:]]+[0-9]+' /etc/nginx/sites-enabled/default 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';' || echo 80)"
    print_info 'HTTPS Port' "$(grep -E '^[[:space:]]*listen[[:space:]]+[0-9]+.*ssl' /etc/nginx/sites-enabled/default 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';' || echo 443)"
    print_info 'Document Root' "$(grep '^    root ' /etc/nginx/sites-enabled/default 2>/dev/null | head -1 | cut -d' ' -f2 | tr -d ';' || echo /var/www/html)"
    print_line
    print_menu_item 1 'Change HTTP Port'
    print_menu_item 2 'Change HTTPS Port'
    print_menu_item 3 'Change Document Root'
    print_menu_item 4 'Validate nginx -t'
    print_menu_item 5 'Restart Nginx'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New HTTP port: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid"; sleep 1; continue;; esac; sed -i "s/^[ \t]*listen[ \t]*[0-9][0-9]*/    listen $port/g" /etc/nginx/sites-enabled/default; operation_result "HTTP Port" "Changed to $port" ;;
      2) echo -n "New HTTPS port: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid"; sleep 1; continue;; esac; sed -i "s/^[ \t]*listen[ \t]*[0-9][0-9]*[ \t]*ssl/    listen $port ssl/g" /etc/nginx/sites-enabled/default; operation_result "HTTPS Port" "Changed to $port" ;;
      3) echo -n "New Document Root: "; read root; [ -z "$root" ] && root="/var/www/html"; sed -i "s#^    root .*;#    root $root;#g" /etc/nginx/sites-enabled/default; operation_result "Document Root" "Changed to $root" ;;
      4) nginx -t && operation_result "nginx -t" PASSED || operation_result "nginx -t" FAILED ;;
      5) svc_stop NGINX; svc_start NGINX; operation_result "Nginx Restart" "$(svc_state NGINX)" ;;
      0) return ;;
    esac
  done
}

iperf3_settings() {
  while :; do
    print_header "IPERF3 SETTINGS"
    print_info 'Server Port' "$(grep '^ -p ' /proc/*/cmdline 2>/dev/null | head -1 | cut -d'p' -f2 | tr -d '\0' || echo 5201)"
    print_info 'Status' "$(svc_state IPERF3)"
    print_line
    print_menu_item 1 'Change Server Port'
    print_menu_item 2 'Start Server'
    print_menu_item 3 'Stop Server'
    print_menu_item 4 'Run Local Speedtest'
    print_menu_item 5 'Run Client Test'
    print_menu_item 6 'Restart iPerf3'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New port [1-65535]: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid"; sleep 1; continue;; esac; [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { print_warning "Invalid range"; sleep 1; continue; }; svc_stop IPERF3; sed -i -E "s/(iperf3.*-p )[0-9]+/\1$port/g" /usr/local/bin/setup 2>/dev/null; svc_start IPERF3; operation_result "iPerf3 Port" "Changed to $port" ;;
      2) svc_start IPERF3; operation_result "iPerf3 Start" "$(svc_state IPERF3)" ;;
      3) svc_stop IPERF3; operation_result "iPerf3 Stop" "$(svc_state IPERF3)" ;;
      4) speedtest-cli 2>/dev/null || iperf3 -c localhost -p 5201 2>/dev/null; ui_pause ;;
      5) echo -n "Enter server IP: "; read sip; iperf3 -c "$sip" -p 5201 2>/dev/null; ui_pause ;;
      6) svc_stop IPERF3; svc_start IPERF3; operation_result "iPerf3 Restart" "$(svc_state IPERF3)" ;;
      0) return ;;
    esac
  done
}

nodered_settings() {
  while :; do
    print_header "NODE-RED SETTINGS"
    print_info Port "$(grep '^ *port: ' /root/.node-red/settings.js 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 1880)"
    print_info 'User Directory' "/root/.node-red"
    print_info Status "$(svc_state NODERED)"
    print_line
    print_menu_item 1 'Change Port'
    print_menu_item 2 'Start Node-RED'
    print_menu_item 3 'Stop Node-RED'
    print_menu_item 4 'Restart Node-RED'
    print_menu_item 5 'Backup User Data'
    print_menu_item 6 'Restore User Data'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New port [1-65535]: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid"; sleep 1; continue;; esac; [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { print_warning "Invalid range"; sleep 1; continue; }; sed -i "s/port:.*/port: $port,/g" /root/.node-red/settings.js 2>/dev/null; operation_result "Node-RED Port" "Changed to $port" ;;
      2) svc_start NODERED; operation_result "Node-RED Start" "$(svc_state NODERED)" ;;
      3) svc_stop NODERED; operation_result "Node-RED Stop" "$(svc_state NODERED)" ;;
      4) svc_stop NODERED; svc_start NODERED; operation_result "Node-RED Restart" "$(svc_state NODERED)" ;;
      5) back=/sdcard/nodered_backup_$(date +%Y%m%d).tar.gz; tar -czf "$back" /root/.node-red 2>/dev/null; [ -s "$back" ] && operation_result "Node-RED Backup" SUCCESS "$back" || operation_result "Node-RED Backup" FAILED ;;
      6) latest=$(ls -1t /sdcard/nodered_backup_*.tar.gz 2>/dev/null | head -1); [ -n "$latest" ] && tar -xzf "$latest" -C / 2>/dev/null && operation_result "Node-RED Restore" SUCCESS "$latest" || operation_result "Node-RED Restore" FAILED; ui_pause ;;
      0) return ;;
    esac
  done
}

ttyd_settings() {
  while :; do
    print_header "TTYD SETTINGS"
    print_info Port "$(ps aux | grep ttyd | grep -v grep | grep -o '\-p [0-9]*' | cut -d' ' -f2 || echo 7681)"
    print_info Username "root"
    print_info Status "$(svc_state TTYD)"
    print_line
    print_menu_item 1 'Change Port'
    print_menu_item 2 'Change Password'
    print_menu_item 3 'Start ttyd'
    print_menu_item 4 'Stop ttyd'
    print_menu_item 5 'Restart ttyd'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) echo -n "New port [1-65535]: "; read port; case "$port" in ''|*[!0-9]*) print_warning "Invalid"; sleep 1; continue;; esac; [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || { print_warning "Invalid range"; sleep 1; continue; }; sed -i -E "s/(ttyd.*-p )[0-9]+/\1$port/g" /usr/local/bin/setup; svc_stop TTYD; svc_start TTYD; operation_result "ttyd Port" "Changed to $port" ;;
      2) echo -n "New password: "; stty -echo; read pass; stty echo; echo; sed -i "s|-c root:[^ ]*|-c root:$pass|g" /usr/local/bin/setup; svc_stop TTYD; svc_start TTYD; operation_result "ttyd Password" "Changed" ;;
      3) svc_start TTYD; operation_result "ttyd Start" "$(svc_state TTYD)" ;;
      4) svc_stop TTYD; operation_result "ttyd Stop" "$(svc_state TTYD)" ;;
      5) svc_stop TTYD; svc_start TTYD; operation_result "ttyd Restart" "$(svc_state TTYD)" ;;
      0) return ;;
    esac
  done
}

adg_valid_port(){ case "$1" in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }
adg_read_value() {
  key="$1"; cfg=/opt/AdGuardHome/AdGuardHome.yaml
  case "$key" in
    web) awk '/^  address: 0.0.0.0:[0-9]+/ {print $2; exit}' "$cfg" | cut -d: -f2;;
    dns) awk '/^  port: [0-9]+/ {print $2; exit}' "$cfg";;
    https) awk '/^  port_https: [0-9]+/ {print $2; exit}' "$cfg";;
    dot) awk '/^  port_dns_over_tls: [0-9]+/ {print $2; exit}' "$cfg";;
    doq) awk '/^  port_dns_over_quic: [0-9]+/ {print $2; exit}' "$cfg";;
    cache) awk '/^  cache_size: [0-9]+/ {print $2; exit}' "$cfg";;
    mode) awk '/^  upstream_mode: / {print $2; exit}' "$cfg";;
  esac
}
adg_apply_setting() {
  key="$1"; val="$2"; cfg=/opt/AdGuardHome/AdGuardHome.yaml
  [ -f "$cfg" ] || { echo 'AdGuard configuration is missing.'; return 1; }
  cp -f "$cfg" "$cfg.guard-os.bak" || return 1
  case "$key" in
    web) sed -i "0,/^  address: 0.0.0.0:[0-9][0-9]*$/s//  address: 0.0.0.0:$val/" "$cfg";;
    dns) sed -i "0,/^  port: [0-9][0-9]*$/s//  port: $val/" "$cfg";;
    https) sed -i "0,/^  port_https: [0-9][0-9]*$/s//  port_https: $val/" "$cfg";;
    dot) sed -i "0,/^  port_dns_over_tls: [0-9][0-9]*$/s//  port_dns_over_tls: $val/" "$cfg";;
    doq) sed -i "0,/^  port_dns_over_quic: [0-9][0-9]*$/s//  port_dns_over_quic: $val/" "$cfg";;
    cache) sed -i "0,/^  cache_size: [0-9][0-9]*$/s//  cache_size: $val/" "$cfg";;
    mode) sed -i "0,/^  upstream_mode: [^ ]*$/s//  upstream_mode: $val/" "$cfg";;
  esac
  return 0
}
adg_restart_after_edit(){
  pkill -TERM -x AdGuardHome 2>/dev/null || true
  sleep 1
  (cd /opt/AdGuardHome && nohup ./AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome >/var/log/guard-os/adguard.log 2>&1 &)
  sleep 2
}
adg_edit_settings(){
  cfg=/opt/AdGuardHome/AdGuardHome.yaml
  [ -f "$cfg" ] || { print_warning 'Install or inject AdGuard configuration first.'; ui_pause; return; }
  while :; do
    print_header 'ADGUARD SETTINGS EDITOR'
    print_info 'HTTP Port' "$(adg_read_value web)"; print_info 'DNS Port' "$(adg_read_value dns)"
    print_info 'HTTPS Port' "$(adg_read_value https)"; print_info 'DoT Port' "$(adg_read_value dot)"
    print_info 'DoQ Port' "$(adg_read_value doq)"; print_info 'Cache Bytes' "$(adg_read_value cache)"
    print_info 'Upstream Mode' "$(adg_read_value mode)"
    print_line
    print_menu_item 1 'Change HTTP Web port'
    print_menu_item 2 'Change DNS port'
    print_menu_item 3 'Change HTTPS port'
    print_menu_item 4 'Change DNS-over-TLS port'
    print_menu_item 5 'Change DNS-over-QUIC port'
    print_menu_item 6 'Change cache size'
    print_menu_item 7 'Change upstream mode'
    print_menu_item 8 'Restore previous configuration'
    print_menu_item 9 'Restart AdGuard'
    print_menu_item 0 Back
    echo -n ' Choice: '; read ec < /dev/tty
    case "$ec" in
      1|2|3|4|5) echo -n ' New port [1-65535]: '; read nv < /dev/tty; adg_valid_port "$nv" || { print_warning 'Invalid port.'; sleep 1; continue; }; case "$ec" in 1) k=web;;2) k=dns;;3) k=https;;4) k=dot;;5) k=doq;;esac; adg_apply_setting "$k" "$nv" && { adg_restart_after_edit; print_success 'Saved and restarted.'; } || print_error 'Update failed'; sleep 2;;
      6) echo -n ' Cache size in bytes [1048576-1073741824]: '; read nv < /dev/tty; case "$nv" in ''|*[!0-9]*) print_warning 'Invalid number'; sleep 1; continue;; esac; [ "$nv" -ge 1048576 ] 2>/dev/null && [ "$nv" -le 1073741824 ] 2>/dev/null || { print_warning 'Out of range.'; sleep 1; continue; }; adg_apply_setting cache "$nv" && { adg_restart_after_edit; print_success 'Saved and restarted.'; }; sleep 2;;
      7) echo ' [1] parallel  [2] load_balance  [3] fastest_addr'; read nv < /dev/tty; case "$nv" in 1) nv=parallel;;2) nv=load_balance;;3) nv=fastest_addr;;*) print_warning 'Invalid mode'; sleep 1; continue;;esac; adg_apply_setting mode "$nv" && { adg_restart_after_edit; print_success 'Saved and restarted.'; }; sleep 2;;
      8) [ -f "$cfg.guard-os.bak" ] && { cp -f "$cfg.guard-os.bak" "$cfg"; adg_restart_after_edit; print_success 'Previous configuration restored.'; } || print_warning 'No backup found.'; sleep 2;;
      9) adg_restart_after_edit; print_success 'AdGuard restarted.'; sleep 2;;
      0) return;;
    esac
  done
}

# ============================================================
# SERVICE-SPECIFIC CONFIGURATION MENUS
# ============================================================
adg_menu() {
  while :; do
    clear_screen
    ACTIVE_IP=$(get_local_ip)
    print_header "ADGUARD HOME CONTROL"
    WEB_PORT=$(adg_read_value web); HTTPS_PORT=$(adg_read_value https); DNS_PORT=$(adg_read_value dns)
    echo -e "  ${GREEN}Web UI: https://${ACTIVE_IP}:${HTTPS_PORT:-443} (HTTP :${WEB_PORT:-80})${NC}"
    echo -e "  ${GREEN}Login : admin / (your password)${NC}"
    print_line
    print_menu_item 1 "Start AdGuard Home"
    print_menu_item 2 "Stop AdGuard Home"
    print_menu_item 3 "Check Status"
    print_menu_item 4 "Re-Inject Master Config"
    print_menu_item 5 "Regenerate SSL"
    print_menu_item 6 "Edit Settings"
    print_menu_item 0 "Back"
    echo -e -n "\n${YELLOW}  Enter Choice [0-6]: ${NC}"
    read ac < /dev/tty
    case $ac in
      1) bash -c "cd /opt/AdGuardHome && nohup ./AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome >/dev/null 2>&1 &"; echo -e " ${GREEN} AdGuard Home Started!${NC}"; ui_pause ;;
      2) pkill -TERM -x AdGuardHome 2>/dev/null || true; sleep 1; echo -e " ${RED} AdGuard Home Stopped.${NC}"; ui_pause ;;
      3) echo ""; ps aux | grep -i [A]dGuardHome; netstat -tlpn 2>/dev/null | grep AdGuardHome; ui_pause ;;
      4) inject_config_adg ;;
      5) gen_ssl_adg ;;
      6) adg_edit_settings ;;
      0) break ;;
    esac
  done
}
gen_ssl_adg() {
  ACTIVE_IP=$(get_local_ip)
  echo ""; echo -e " Detected IP: [${GREEN}$ACTIVE_IP${NC}]"
  echo -e " Generating Root CA & Fullchain SSL..."
  mkdir -p /opt/AdGuardHome/ssl /usr/local/share/ca-certificates
  openssl req -x509 -new -nodes -keyout /opt/AdGuardHome/ssl/ca.key -out /opt/AdGuardHome/ssl/ca.crt -days 3650 -subj "/CN=TVBox Root CA/O=TV Suite/C=EG" 2>/dev/null || true
  cp /opt/AdGuardHome/ssl/ca.crt /usr/local/share/ca-certificates/TVBox_Root_CA.crt 2>/dev/null || true
  update-ca-certificates 2>/dev/null || true
  openssl req -new -nodes -newkey rsa:2048 -keyout /opt/AdGuardHome/adguard.key -out /tmp/adg.csr -subj "/CN=${ACTIVE_IP}/O=AdGuard Home/C=EG" 2>/dev/null || true
  cat << EXTEOF > /tmp/adg_ext.cnf
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = IP:${ACTIVE_IP},DNS:${ACTIVE_IP}
EXTEOF
  openssl x509 -req -in /tmp/adg.csr -CA /opt/AdGuardHome/ssl/ca.crt -CAkey /opt/AdGuardHome/ssl/ca.key -CAcreateserial -out /opt/AdGuardHome/adguard.crt -days 3650 -extfile /tmp/adg_ext.cnf 2>/dev/null || true
  cat /opt/AdGuardHome/adguard.crt /opt/AdGuardHome/ssl/ca.crt > /opt/AdGuardHome/fullchain.crt
  chmod 644 /opt/AdGuardHome/fullchain.crt /opt/AdGuardHome/adguard.crt /opt/AdGuardHome/adguard.key 2>/dev/null
  echo -e "\n ${GREEN} SSL certificates generated.${NC}"
  ui_pause
}
inject_config_adg() {
  ACTIVE_IP=$(get_local_ip)
  echo ""; echo -e " Detected IP: [${GREEN}$ACTIVE_IP${NC}]"
  echo -e -n "${CYAN}Enter Admin Password for AdGuard (default 'admin'): ${NC}"
  stty -echo; read user_pass; stty echo; echo
  if [ -z "$user_pass" ]; then
    user_pass="admin"
    PASS_HASH="\$2a\$10\$E/eeSWbUgE/3Bzgi67FkMOc5nhOt3Gn50SoxVvYj1NAlaAIHGYeJK"
  else
    if ! command -v htpasswd >/dev/null 2>&1; then
      pkg_install apache2-utils || true
    fi
    PASS_HASH=$(htpasswd -bnBC 10 "" "$user_pass" 2>/dev/null | tr -d ':\n')
    [ -z "$PASS_HASH" ] && PASS_HASH="\$2a\$10\$E/eeSWbUgE/3Bzgi67FkMOc5nhOt3Gn50SoxVvYj1NAlaAIHGYeJK"
  fi
  if [ ! -f /opt/AdGuardHome/fullchain.crt ]; then gen_ssl_adg; fi
  mkdir -p /opt/AdGuardHome
  pkill -TERM -x AdGuardHome 2>/dev/null || true; sleep 1
  cat << ADGCONFIGEOF > /opt/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
      - GET /dns-query
      - POST /dns-query
      - GET /dns-query/{ClientID}
      - POST /dns-query/{ClientID}
    insecure_enabled: false
  address: 0.0.0.0:80
  session_ttl: 30d
users:
  - name: admin
    password: ${PASS_HASH}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 0
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns.nextdns.io/dns-query
    - https://1.1.1.1/dns-query
    - https://dns.google/dns-query
    - https://dns.quad9.net/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 45.90.28.0
    - 45.90.30.0
    - 1.1.1.1
    - 8.8.8.8
  fallback_dns: []
  upstream_mode: parallel
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 268435456
  cache_ttl_min: 600
  cache_ttl_max: 86400
  cache_optimistic: true
  cache_optimistic_answer_ttl: 1m
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: true
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: true
    use_custom: false
  max_goroutines: 300
  handle_ddr: false
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 5s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams:
    - 10.0.1.1
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
tls:
  enabled: true
  server_name: ${ACTIVE_IP}
  force_https: true
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  certificate_chain: ""
  private_key: ""
  certificate_path: /opt/AdGuardHome/fullchain.crt
  private_key_path: /opt/AdGuardHome/adguard.key
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 30d
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 30d
  enabled: true
  ignored_enabled: false
filters:
  - enabled: true
    url: https://github.com/ashrafcapmas/Block_update/raw/refs/heads/main/Block%20list
    name: Block_update
    id: 1761286022
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1769196457
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard Popup Hosts filter
    id: 1769196458
whitelist_filters: []
user_rules:
  - '||www.goooooooooooooooooooooooooooooooooooooooooooooooooooooooooogle.com^$important'
  - '||gameswhitelisted.googleapis.com^$important'
  - '||cloud.mikrotik.com^$important'
  - ""
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: 192.168.88.1
    subnet_mask: 255.255.255.0
    range_start: 192.168.88.100
    range_end: 192.168.88.254
    lease_duration: 1800
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: 0.0.0.0
  blocking_ipv6: '::'
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: true
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: nxdomain
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /data/AdGuardHome/work/userfilters/*
  max_http_size: 256MB
  safebrowsing_cache_size: 268435456
  safesearch_cache_size: 268435456
  parental_cache_size: 268435456
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 0
  filtering_enabled: true
  rewrites_enabled: true
  parental_enabled: true
  safebrowsing_enabled: true
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: true
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
ADGCONFIGEOF
  chmod 644 /opt/AdGuardHome/AdGuardHome.yaml
  echo "ADMIN_USERNAME=admin" > /opt/AdGuardHome/guard-os-default-credentials.conf
  echo "ADMIN_PASSWORD=$user_pass" >> /opt/AdGuardHome/guard-os-default-credentials.conf
  chmod 600 /opt/AdGuardHome/guard-os-default-credentials.conf
  bash -c "cd /opt/AdGuardHome && nohup ./AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome >/dev/null 2>&1 &"
  set_auto ADGUARD enabled
  echo -e "\n ${GREEN} AdGuard Home configuration injected with your password.${NC}"
  ui_pause
}


# ============================================================
# SERVICE INSTALLATION ROUTINES
# ============================================================
install_adg() {
  echo -e "${CYAN} Downloading AdGuard Home...${NC}"
  pkg_install wget curl tar apache2-utils || true
  mkdir -p /opt/AdGuardHome
  cd /tmp
  ARCH=$(uname -m)
  if echo "$ARCH" | grep -q "aarch64"; then ADG_ARCH="arm64"; else ADG_ARCH="armv7"; fi
  rm -f adguard.tar.gz
  wget "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ADG_ARCH}.tar.gz" -O adguard.tar.gz || curl -fSL "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${ADG_ARCH}.tar.gz" -o adguard.tar.gz || return 21
  [ -s adguard.tar.gz ] && tar -tzf adguard.tar.gz >/dev/null 2>&1 || { echo "Invalid AdGuard archive"; rm -f adguard.tar.gz; return 22; }
  tar -xzf adguard.tar.gz -C /opt/ || return 23
  rm -f adguard.tar.gz
  chmod 755 /opt/AdGuardHome/AdGuardHome 2>/dev/null; [ -x /opt/AdGuardHome/AdGuardHome ] || print_warning "Failed to set execute permissions"
  [ -x /opt/AdGuardHome/AdGuardHome ] || return 24
  gen_ssl_adg || return 25
  inject_config_adg || return 26
  return 0
}
install_smb() {
  echo -e "${CYAN} Installing Samba...${NC}"
  pkg_install samba
  command -v smbd >/dev/null 2>&1 || [ -f /usr/sbin/smbd ] || return 75
  mkdir -p /opt/shared /sdcard
  chmod -R 0775 /opt/shared 2>/dev/null || true
  print_menu_item 1 "Public Share (No Password)"
  print_menu_item 2 "Private Share (Password Protected)"
  echo -e -n "${YELLOW}  Select [1-2]: ${NC}"
  read sec_level < /dev/tty
  if [ "$sec_level" = "2" ]; then
    echo -e -n "${CYAN} Enter Samba Username: ${NC}"
    read smb_user < /dev/tty
    [ -z "$smb_user" ] && smb_user="admin"
    useradd -M "$smb_user" 2>/dev/null || true
    echo -e -n "${CYAN} Enter Password: ${NC}"
    stty -echo; read smb_pass; stty echo; echo
    (echo "$smb_pass"; echo "$smb_pass") | smbpasswd -s -a "$smb_user" 2>/dev/null
    cat << SEOF > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server string = TVBox NAS
   security = user
   map to guest = never
[Internal_Shared]
   comment = Internal Storage
   path = /sdcard
   browseable = yes
   writable = yes
   guest ok = no
   valid users = $smb_user
   force user = root
   create mask = 0777
   directory mask = 0777
[External_USB]
   comment = USB Drives
   path = /mnt
   browseable = yes
   writable = yes
   guest ok = no
   valid users = $smb_user
   force user = root
   create mask = 0777
   directory mask = 0777
SEOF
  else
    cat << 'SEOF' > /etc/samba/smb.conf
[global]
   workgroup = WORKGROUP
   server string = TVBox NAS
   security = user
   map to guest = Bad User
   guest account = nobody
[Internal_Shared]
   comment = Internal Storage
   path = /sdcard
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
   force user = root
   create mask = 0777
   directory mask = 0777
[External_USB]
   comment = USB Drives
   path = /mnt
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
   force user = root
   create mask = 0777
   directory mask = 0777
SEOF
  fi
  pkill -TERM -x smbd 2>/dev/null || true
  smbd -D 2>/dev/null; nmbd -D 2>/dev/null
  set_auto SAMBA enabled
  echo -e "\n ${GREEN} Samba installed.${NC}"
  ui_pause
}
install_zerotier() {
  echo -e "${CYAN} Installing ZeroTier...${NC}"
  export DEBIAN_FRONTEND=noninteractive
  if [ -f /etc/alpine-release ]; then
    apk add zerotier-one || return 31
  else
    apt-get update >/dev/null 2>&1 && apt-get -qq install -y curl gnupg >/dev/null 2>&1 || return 31
    zt_installer=/tmp/guard-os-zerotier-install.sh
    rm -f "$zt_installer"
    curl -fsSL https://install.zerotier.com -o "$zt_installer" || return 32
    [ -s "$zt_installer" ] || return 33
    grep -q 'ZeroTier' "$zt_installer" || { rm -f "$zt_installer"; return 34; }
    bash "$zt_installer" || { rm -f "$zt_installer"; return 35; }
    rm -f "$zt_installer"
  fi
  zerotier-one -d >/var/log/guard-os/zerotier.log 2>&1 &
  command -v zerotier-one >/dev/null 2>&1 || [ -f /usr/sbin/zerotier-one ] || return 77
  set_auto ZEROTIER enabled
  echo -e "\n ${GREEN} ZeroTier installed.${NC}"
  ui_pause
}
install_dnscrypt() {
  echo -e "${CYAN} Installing DNSCrypt...${NC}"
  pkg_install dnscrypt-proxy
  command -v dnscrypt-proxy >/dev/null 2>&1 || [ -f /usr/sbin/dnscrypt-proxy ] || return 76
  mkdir -p /etc/dnscrypt-proxy
  if [ -f /etc/dnscrypt-proxy/dnscrypt-proxy.toml.default ]; then
    cp /etc/dnscrypt-proxy/dnscrypt-proxy.toml.default /etc/dnscrypt-proxy/dnscrypt-proxy.toml
  fi
  sed -i "s/listen_addresses = .*/listen_addresses = ['0.0.0.0:5353']/g" /etc/dnscrypt-proxy/dnscrypt-proxy.toml 2>/dev/null || true
  dnscrypt-proxy -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml >/dev/null 2>&1 &
  set_auto DNSCRYPT enabled
  echo -e "\n ${GREEN} DNSCrypt installed.${NC}"
  ui_pause
}
install_nginx() {
  echo -e "${CYAN} Installing Nginx...${NC}"
  pkg_install nginx
  command -v nginx >/dev/null 2>&1 || return 73
  mkdir -p /etc/nginx/sites-available
  nginx >/dev/null 2>&1 &
  set_auto NGINX enabled
  echo -e "\n ${GREEN} Nginx installed.${NC}"
  ui_pause
}
install_iperf3() {
  echo -e "${CYAN} Installing iPerf3...${NC}"
  pkg_install iperf3 speedtest-cli || pkg_install iperf3
  command -v iperf3 >/dev/null 2>&1 || return 72
  iperf3 -s -p 5201 -D >/dev/null 2>&1 &
  set_auto IPERF3 enabled
  echo -e "\n ${GREEN} iPerf3 installed.${NC}"
  ui_pause
}
install_nodered() {
  echo -e "${CYAN} Installing Node-RED...${NC}"
  pkg_install nodejs npm
  npm install -g --unsafe-perm node-red || return 78
  node-red >/dev/null 2>&1 &
  set_auto NODERED enabled
  echo -e "\n ${GREEN} Node-RED installed.${NC}"
  ui_pause
}
install_hass() {
  echo -e "${CYAN} Installing Home Assistant Core...${NC}"
  
  if command -v apk >/dev/null; then
    OS_TYPE="alpine-latest"
    pkg_install python3 py3-pip python3-dev py3-virtualenv gcc g++ musl-dev libffi-dev make cargo rust tzdata jpeg-dev zlib-dev curl wget tar
  else
    OS_TYPE="ubuntu-24.04"
    pkg_install python3 python3-pip python3-venv python3-dev build-essential libffi-dev libssl-dev libjpeg-dev zlib1g-dev rustc cargo tzdata curl wget tar
  fi

  mkdir -p /opt/homeassistant || return 68
  python3 -m venv /opt/homeassistant || return 70
  /opt/homeassistant/bin/pip install --upgrade pip wheel

  # =========================================================================
  # PRE-COMPILED WHEELS (GITHUB ACTIONS BYPASS FOR LOW RAM DEVICES)
  # =========================================================================
  GITHUB_REPO="YOUR_USERNAME/YOUR_REPO_NAME" # <-- USER MUST CHANGE THIS
  WHEELS_URL="https://github.com/$GITHUB_REPO/releases/download/latest/hass-wheels-${OS_TYPE}-armv7.tar.gz"
  
  echo -e "${YELLOW} Checking for pre-compiled packages from GitHub...${NC}"
  rm -rf /tmp/hass-wheels; mkdir -p /tmp/hass-wheels
  
  if wget -q --spider "$WHEELS_URL"; then
    echo -e "${GREEN} Found pre-compiled wheels. Downloading...${NC}"
    wget -q --show-progress "$WHEELS_URL" -O /tmp/hass-wheels.tar.gz
    tar -xzf /tmp/hass-wheels.tar.gz -C /tmp/hass-wheels >/dev/null 2>&1 || true
    echo -e "${CYAN} Installing Home Assistant (Fast Mode)...${NC}"
    /opt/homeassistant/bin/pip install --no-index --find-links=/tmp/hass-wheels homeassistant || return 70
  else
    echo -e "${YELLOW} No pre-compiled wheels found at $WHEELS_URL${NC}"
    echo -e "${YELLOW} Falling back to source build (May take a long time on ARMv7)...${NC}"
    /opt/homeassistant/bin/pip install homeassistant || return 70
  fi
  
  rm -rf /tmp/hass-wheels /tmp/hass-wheels.tar.gz
  
  set_auto HASS enabled
  echo -e "\n ${GREEN} Home Assistant installed.${NC}"
  ui_pause
}
install_motioneye() {
  echo -e "${CYAN} Installing MotionEye...${NC}"
  if command -v apk >/dev/null; then
    apk add motion ffmpeg v4l-utils python3 py3-pip python3-dev py3-virtualenv gcc musl-dev curl-dev libjpeg-turbo-dev zlib-dev py3-curl py3-pillow py3-tornado py3-jinja2
    python3 -m venv --system-site-packages /opt/motioneye
    /opt/motioneye/bin/pip install motioneye || return 71
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends motion ffmpeg v4l-utils python3 python3-pip python3-venv python3-dev build-essential libssl-dev libcurl4-openssl-dev libjpeg-dev zlib1g-dev python3-pycurl python3-pillow python3-tornado python3-jinja2
    python3 -m venv --system-site-packages /opt/motioneye
    /opt/motioneye/bin/pip install motioneye || return 71
  fi
  
  mkdir -p /etc/motioneye /var/lib/motioneye
  [ -f /etc/motioneye/motioneye.conf ] || cp /opt/motioneye/share/motioneye/extra/motioneye.conf.sample /etc/motioneye/motioneye.conf 2>/dev/null || touch /etc/motioneye/motioneye.conf
  
  set_auto MOTIONEYE enabled
  echo -e "\n ${GREEN} MotionEye installed.${NC}"
  ui_pause
}
install_ttyd() {
  echo -e "${CYAN} Installing ttyd...${NC}"
  pkg_install ttyd
  command -v ttyd >/dev/null 2>&1 || return 74
  set_auto TTYD enabled
  pkill -TERM -x ttyd 2>/dev/null || true
  env TERM=xterm LANG=C.UTF-8 ttyd -t 'theme={"background": "black"}' -p 7681 -c root:tv -W bash -c \"export LANG=C.UTF-8; export TERM=xterm; /usr/local/bin/setup\" >/dev/null 2>&1 &
  ACTIVE_IP=$(get_local_ip)
  echo -e "\n ${GREEN} ttyd running on http://$ACTIVE_IP:7681${NC}"
  ui_pause
}

run_app_installer() {
  func=$(get_svc_field "$1" 8)
  if [ -n "$func" ]; then
    "$func"
  else
    return 64
  fi
}


# ============================================================
# MAIN INTERACTIVE MENUS
# ============================================================
applications_installer_final() {
  while :; do
    print_header "APPLICATIONS INSTALLER"
    i=1
    for k in $OPTIONAL_SERVICES; do
      svc_installed "$k" && st=Installed || st='Not Installed'
      printf '[%s] %-18s %s\n' "$i" "$(svc_name "$k")" "$st"
      i=$((i+1))
    done
    print_line
    print_menu_item U 'Update Package Lists'
    print_menu_item L 'View last installer log'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      U|u) clear_screen; command -v apt-get >/dev/null 2>&1 && apt-get -q update || apk update; ui_pause; continue ;;
      L|l) clear_screen; tail -n120 /var/log/guard-os/installer.log 2>/dev/null || echo 'No log'; ui_pause; continue ;;
      0) return ;;
    esac
        k=""
    j=1
    for s in $OPTIONAL_SERVICES; do
      [ "$x" = "$j" ] && { k="$s"; break; }
      j=$((j+1))
    done
    [ -z "$k" ] && { invalid_choice; continue; }
    if svc_installed "$k"; then
      print_warning 'Already installed. Use Services Manager.'
      ui_pause; continue
    fi
    print_header "INSTALL $(svc_name "$k")"
    print_menu_item 1 'Install only'
    print_menu_item 2 'Install and start'
    print_menu_item 3 'Install, start and enable Autostart'
    print_menu_item 0 Cancel
    read a < /dev/tty
    [ "$a" = 0 ] && continue
    print_header "INSTALLING $(svc_name "$k")"
    APP_INSTALL_MODE=1; export APP_INSTALL_MODE
    run_app_installer "$k"
    install_rc=$?
    unset APP_INSTALL_MODE
    if [ $install_rc -eq 0 ] && svc_installed "$k"; then
      [ "$a" = 1 ] && { svc_stop "$k"; set_auto "$k" disabled; }
      [ "$a" = 2 ] && { svc_start "$k"; set_auto "$k" disabled; }
      [ "$a" = 3 ] && { svc_start "$k"; set_auto "$k" enabled; }
      operation_result "$(svc_name "$k")" SUCCESS
    else
      operation_result "$(svc_name "$k")" "FAILED (code $install_rc)"
    fi
  done
}

sample_cpu() {
  read _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
  t1=$((u1+n1+s1+i1+w1+q1+sq1+st1)); sleep 1
  read _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
  t2=$((u2+n2+s2+i2+w2+q2+sq2+st2)); dt=$((t2-t1)); di=$((i2-i1)); dw=$((w2-w1))
  [ "$dt" -gt 0 ] && CPU_PCT=$((100*(dt-di)/dt)) || CPU_PCT=0
  [ "$dt" -gt 0 ] && IOWAIT_PCT=$((100*dw/dt)) || IOWAIT_PCT=0
}
process_health_counts() {
  KERNEL_D_COUNT=0; ANDROID_ZOMBIE_COUNT=0; GUARD_D_COUNT=0; ZOMBIE_COUNT=0; BAD_COUNT=0
  for p in /proc/[0-9]*; do
    [ -r "$p/status" ] || continue
    state=$(grep '^State:' "$p/status" 2>/dev/null | cut -f2 | cut -c1)
    name=$(grep '^Name:' "$p/status" 2>/dev/null | cut -f2)
    cmd=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null)
    case "$state" in D) KERNEL_D_COUNT=$((KERNEL_D_COUNT+1));; Z) ANDROID_ZOMBIE_COUNT=$((ANDROID_ZOMBIE_COUNT+1));; esac
    is_guard=0
    case "$name $cmd" in
      *tv_autostart.sh*|*tv_watchdog.sh*|*sshd*|*AdGuardHome*|*smbd*|*nmbd*|*zerotier-one*|*dnscrypt-proxy*|*nginx*|*iperf3*|*node-red*|*hass*|*meyectl*|*ttyd*) is_guard=1 ;;
    esac
    [ "$is_guard" -eq 1 ] || continue
    case "$state" in D) GUARD_D_COUNT=$((GUARD_D_COUNT+1)); BAD_COUNT=$((BAD_COUNT+1));; Z) ZOMBIE_COUNT=$((ZOMBIE_COUNT+1)); BAD_COUNT=$((BAD_COUNT+1));; esac
  done
}
health_score_calc() {
  SCORE=100; FINDINGS=""
  for f in /bin/bash /etc/os-release /usr/local/bin/setup /usr/local/bin/tv_autostart.sh /usr/local/bin/tv_watchdog.sh; do [ -e "$f" ] || SCORE=$((SCORE-8)); done
  for m in /dev /dev/pts /proc /sys; do grep -qs " $m " /proc/mounts || SCORE=$((SCORE-7)); done
  /usr/sbin/sshd -t >/dev/null 2>&1 || SCORE=$((SCORE-15))
  svc_running SSH || SCORE=$((SCORE-10))
  pid=$(cat /run/guard-os-autostart.pid 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || SCORE=$((SCORE-10))
  process_health_counts; [ "$BAD_COUNT" -eq 0 ] || SCORE=$((SCORE-10))
  [ "$ZOMBIE_COUNT" -eq 0 ] || SCORE=$((SCORE-5))
  [ "$SCORE" -lt 0 ] && SCORE=0
  [ "$SCORE" -ge 90 ] && HEALTH_CLASS=EXCELLENT || [ "$SCORE" -ge 75 ] && HEALTH_CLASS=GOOD || [ "$SCORE" -ge 50 ] && HEALTH_CLASS='NEEDS ATTENTION' || HEALTH_CLASS=CRITICAL
}
health_dashboard() {
  while :; do
    sample_cpu; health_score_calc
    print_header "HEALTH AND SYSTEM DASHBOARD"
    . /etc/os-release 2>/dev/null || true
    
    printf "  ${CYAN}====== SYSTEM INFO ======${NC}\n"
    print_info 'Guard_OS' "3.1.0"
    print_info 'OS' "${PRETTY_NAME:-Ubuntu}"
    print_info Kernel "$(uname -r)"
    print_info Uptime "$(awk '{print int($1/3600)"h "int(($1%3600)/60)"m"}' /proc/uptime 2>/dev/null)"
    
    printf "\n  ${CYAN}====== NETWORK ======${NC}\n"
    print_info Hostname "$(hostname)"
    print_info 'IP Address' "$(get_local_ip)"
    
    printf "\n  ${CYAN}====== HARDWARE ======${NC}\n"
    print_info Architecture "$(uname -m)"
    print_info Memory "$(free -m 2>/dev/null | awk '/Mem:/{print $3"/"$2" MB"}')"
    print_info Storage "$(df -h / 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f3-5)"
    
    printf "\n  ${CYAN}====== SERVICES ======${NC}\n"
    print_info SSH "$(svc_state SSH)"
    spid=$(cat /run/guard-os-autostart.pid 2>/dev/null || echo none)
    print_info Supervisor "$spid"
    mounts=0; for m in /dev /dev/pts /proc /sys; do grep -qs " $m " /proc/mounts && mounts=$((mounts+1)); done
    print_info Mounts "$mounts/4"
    
    printf "\n  ${CYAN}====== PERFORMANCE ======${NC}\n"
    print_info 'CPU Usage' "$CPU_PCT%"
    print_info 'I/O Wait' "$IOWAIT_PCT%"
    print_info 'Health Score' "$SCORE/100 ($HEALTH_CLASS)"
    
    print_line
    print_menu_item R Refresh
    print_menu_item 0 Back
    printf ' Choice: '; read x < /dev/tty
    case "$x" in R|r) continue ;; 0) return ;; esac
  done
}

export_logs_txt() {
  out=/sdcard/Guard_OS_Full_Logs_$(date +%Y%m%d_%H%M%S).txt
  [ -d /sdcard ] || out=/var/log/guard-os/Guard_OS_Full_Logs_$(date +%Y%m%d_%H%M%S).txt
  {
    echo "GUARD_OS FULL LOG EXPORT"; echo "Generated: $(date)"; echo "Version: 3.1.0"
    for f in /var/log/guard-os/*.log /etc/tv_autostart.conf /etc/ssh/sshd_config /etc/os-release; do
      [ -f "$f" ] || continue; echo; echo "===== $f ====="; cat "$f"
    done
    echo; echo "===== PROCESSES ====="; ps aux 2>/dev/null
    echo; echo "===== MOUNTS ====="; mount
    echo; echo "===== MEMORY ====="; free -m 2>/dev/null
    echo; echo "===== STORAGE ====="; df -h
    echo; echo "===== SSH TEST ====="; /usr/sbin/sshd -t 2>&1; echo "Exit=$?"
  } > "$out" 2>&1
  operation_result 'Export Logs to TXT' SUCCESS "$out"
}
export_logs_tgz() {
  out=/sdcard/Guard_OS_Logs_$(date +%Y%m%d_%H%M%S).tar.gz
  tar -czf "$out" -C /var/log guard-os 2>/dev/null && tar -tzf "$out" >/dev/null 2>&1
  [ $? -eq 0 ] && operation_result 'Export Archive' SUCCESS "$out" || { rm -f "$out"; operation_result 'Export Archive' FAILED; }
}
logs_final() {
  while :; do
    print_header "LOGS AND REPORTS"
    i=1
    for f in base-install ssh-start autostart watchdog installer control repair; do
      printf ' [%s] %-24s %s\n' "$i" "$f" "$([ -f "/var/log/guard-os/$f.log" ] && echo AVAILABLE || echo MISSING)"
      i=$((i+1))
    done
    print_line
    print_menu_item E 'Export All to TXT'
    print_menu_item A 'Export All to TAR.GZ'
    print_menu_item D 'Diagnostic Report'
    print_menu_item R 'Rotate Large Logs'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in E|e) export_logs_txt ;; A|a) export_logs_tgz ;; D|d) full_diagnostic_report ;; R|r) for f in /var/log/guard-os/*.log; do [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 1048576 ] && mv "$f" "$f.1"; done ;; 0) return ;; *) case "$x" in 1) n=base-install;;2) n=ssh-start;;3) n=autostart;;4) n=watchdog;;5) n=installer;;6) n=control;;7) n=repair;;*) n="";; esac; [ -n "$n" ] && { clear_screen; tail -n120 "/var/log/guard-os/$n.log" 2>/dev/null || echo MISSING; ui_pause; } || invalid_choice ;; esac
  done
}

storage_final() {
  while :; do
    print_header "STORAGE AND CLEANUP"
    apt_sz=$(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)
    tmp_sz=$(du -sh /tmp 2>/dev/null | cut -f1)
    log_sz=$(du -sh /var/log/guard-os 2>/dev/null | cut -f1)
    print_info 'APT Cache' "${apt_sz:-0}"
    print_info Temporary "${tmp_sz:-0}"
    print_info Logs "${log_sz:-0}"
    print_line
    print_menu_item 1 'Clean APT Cache'
    print_menu_item 2 'Clean old temporary files'
    print_menu_item 3 'Rotate Logs'
    print_menu_item 4 'Remove failed downloads'
    print_menu_item 5 'List Backups'
    print_menu_item 6 'Safe Cleanup'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) command -v apt-get >/dev/null 2>&1 && apt-get clean || apk cache clean; operation_result 'Clean Cache' SUCCESS ;;
      2) find /tmp -mindepth 1 -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null; operation_result 'Clean old temp' SUCCESS ;;
      3) for f in /var/log/guard-os/*.log; do [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 1048576 ] && { rm -f "$f.1"; mv "$f" "$f.1"; : > "$f"; }; done; operation_result 'Rotate Logs' SUCCESS ;;
      4) rm -f /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part; operation_result 'Remove failed downloads' SUCCESS ;;
      5) clear_screen; ls -lh /sdcard/Guard_OS_backup_*.tar.gz 2>/dev/null || echo 'No backups'; ui_pause ;;
      6) command -v apt-get >/dev/null 2>&1 && apt-get clean || apk cache clean; find /tmp -mindepth 1 -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null; operation_result 'Safe Cleanup' SUCCESS ;;
      0) return ;;
      *) invalid_choice ;;
    esac
  done
}

quick_help() { clear_screen; cat /root/Guard_OS_README.txt 2>/dev/null || echo 'README missing.'; ui_pause; }
about_guard_os() {
  print_header "ABOUT"
  print_info Product Guard_OS
  print_info Version "3.1.0"
  print_info Platform "Android TV Box / ARM"
  print_info RootFS "Ubuntu Base noble / Alpine"
  print_info Creator "Ashraf Saber"
  print_info Runtime Chroot
  print_info Remote Access OpenSSH
  print_info Supervisor "Single Instance"
  ui_pause
}

autostart_manager_final() {
  while :; do
    print_header "AUTOSTART MANAGER"
    i=1
    for k in $SERVICES; do
      printf '[%s] %-15s %s\n' "$i" "$(svc_name "$k")" "$(svc_auto "$k")"
      i=$((i+1))
    done
    print_line
    print_menu_item E 'Enable all installed'
    print_menu_item D 'Disable all optional'
    print_menu_item R 'Run Watchdog now'
    print_menu_item S 'Show Supervisor status'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      E|e) for k in $SERVICES; do svc_installed "$k" && set_auto "$k" enabled; done ;;
      D|d) for k in $OPTIONAL_SERVICES; do set_auto "$k" disabled; done ;;
      R|r) /usr/local/bin/tv_watchdog.sh; operation_result 'Watchdog Run' SUCCESS ;;
      S|s) clear_screen; print_header "SUPERVISOR"; print_info PID "$(cat /run/guard-os-autostart.pid 2>/dev/null || echo Stopped)"; print_info Lock "$([ -d /run/guard-os-autostart.lock ] && echo Present || echo Missing)"; ui_pause ;;
      0) return ;;
      *) k=$(menu_service_by_number "$x"); [ -n "$k" ] || { invalid_choice; continue; }; svc_installed "$k" || { print_warning 'Not installed'; ui_pause; continue; }; [ "$(svc_auto "$k")" = ON ] && set_auto "$k" disabled || set_auto "$k" enabled ;;
    esac
  done
}

services_manager() {
  while :; do
    print_header "SERVICES MANAGER"
    i=1
    for k in $SERVICES; do
      printf '[%s] %-15s %-13s Auto:%-3s Port:%s\n' "$i" "$(svc_name "$k")" "$(svc_state "$k")" "$(svc_auto "$k")" "$(svc_ports "$k")"
      i=$((i+1))
    done
    print_line
    print_menu_item 0 Back
    read x < /dev/tty
    [ "$x" = 0 ] && return
    k=$(menu_service_by_number "$x")
    [ -n "$k" ] && service_detail_menu "$k" || invalid_choice
  done
}

menu_service_by_number() {
  i=1
  for k in $SERVICES; do
    [ "$1" = "$i" ] && { echo "$k"; return 0; }
    i=$((i+1))
  done
}

diagnostics_final() {
  while :; do
    print_header "DIAGNOSTICS AND REPAIR"
    print_menu_item 1 'Quick Health Check'
    print_menu_item 2 'Full Diagnostic Report'
    print_menu_item 3 'Check RootFS Files'
    print_menu_item 4 'Check Mount Points'
    print_menu_item 5 'Check Network and DNS'
    print_menu_item 6 'Check APT'
    print_menu_item 7 'Check SSH'
    print_menu_item 8 'Check Supervisor'
    print_menu_item 9 'Common Repairs'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) quick_health_check ;;
      2) full_diagnostic_report ;;
      3) clear_screen; for f in /bin/bash /etc/os-release /usr/local/bin/setup /usr/local/bin/tv_watchdog.sh /usr/local/bin/tv_autostart.sh; do [ -e "$f" ] && print_success "$f" || print_error "$f missing"; done; ui_pause ;;
      4) clear_screen; mount; ui_pause ;;
      5) clear_screen; ip addr; echo; ping -c 2 1.1.1.1; echo; getent hosts ports.ubuntu.com 2>/dev/null; ui_pause ;;
      6) clear_screen; command -v apt-get >/dev/null 2>&1 && apt-get check || apk audit; ui_pause ;;
      7) clear_screen; /usr/sbin/sshd -t; rc=$?; echo "Exit=$rc"; ui_pause ;;
      8) clear_screen; print_info PID "$(cat /run/guard-os-autostart.pid 2>/dev/null || echo Stopped)"; ls -ld /run/guard-os-autostart.lock 2>/dev/null || true; ui_pause ;;
      9) repair_common ;;
      0) return ;;
      *) invalid_choice ;;
    esac
  done
}

quick_health_check() {
  print_header "QUICK HEALTH"
  bad=0
  for f in /bin/bash /etc/os-release /usr/local/bin/setup /usr/local/bin/tv_watchdog.sh /usr/local/bin/tv_autostart.sh; do
    [ -e "$f" ] && print_success "$f" || { print_error "$f missing"; bad=$((bad+1)); }
  done
  for m in /dev /proc /sys; do grep -qs " $m " /proc/mounts && print_success "$m mounted" || { print_warning "$m not mounted"; bad=$((bad+1)); }; done
  command -v apt-get >/dev/null && print_success "APT available" || { print_error "APT missing"; bad=$((bad+1)); }
  print_info "Disk" "$(df -h / | tail -1 | tr -s ' ' | cut -d' ' -f3-5)"
  [ "$bad" -eq 0 ] && print_success "HEALTHY" || print_warning "NEEDS ATTENTION: $bad findings"
  ui_pause
}
full_diagnostic_report() {
  mkdir -p /var/log/guard-os
  report_file=/var/log/guard-os/diagnostic-report.txt
  {
    echo "Guard_OS diagnostic report"; echo "Generated: $(date)"; echo "Version: 3.1.0"
    echo; echo "===== OS ====="; cat /etc/os-release 2>/dev/null; uname -a
    echo; echo "===== STORAGE ====="; df -h
    echo; echo "===== MEMORY ====="; free -m 2>/dev/null
    echo; echo "===== MOUNTS ====="; mount
    echo; echo "===== PROCESSES ====="; ps aux 2>/dev/null
    echo; echo "===== SSH ====="; /usr/sbin/sshd -t 2>&1
    echo; echo "===== AUTOSTART ====="; cat /etc/tv_autostart.conf 2>/dev/null
    echo; echo "===== PACKAGES ====="; dpkg-query -W 2>/dev/null
  } > "$report_file" 2>&1
  print_success "Diagnostic report saved: $report_file"
  ui_pause
}
repair_common() {
  mkdir -p /run/sshd /var/run/sshd /var/log/guard-os
  chmod 1777 /tmp; chmod 755 /usr/local/bin/setup /usr/local/bin/tv_*.sh 2>/dev/null
  [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key 2>/dev/null
  [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key 2>/dev/null
  [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key 2>/dev/null
  dpkg --configure -a >/var/log/guard-os/repair.log 2>&1 || true
  print_success "Repair completed"
  ui_pause
}
recovery_and_safe_mode() {
  while :; do
    print_header "RECOVERY & SAFE MODE"
    print_menu_item 1 'Start SSH only'
    print_menu_item 2 'Disable all optional Autostart'
    print_menu_item 3 'Remove stale Supervisor lock'
    print_menu_item 4 'Repair SSH directories and keys'
    print_menu_item 5 'Recreate resolv.conf'
    print_menu_item 6 'Export logs'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) svc_start SSH; operation_result 'Safe SSH' "$(svc_state SSH)" ;;
      2) for k in $OPTIONAL_SERVICES; do set_auto "$k" disabled; svc_stop "$k"; done; operation_result 'Disable Optional' SUCCESS ;;
      3) pid=$(cat /run/guard-os-autostart.pid 2>/dev/null); if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then rm -rf /run/guard-os-autostart.lock /run/guard-os-autostart.pid; operation_result 'Remove Stale Lock' SUCCESS; else operation_result 'Remove Stale Lock' 'SKIPPED: Running'; fi ;;
      4) mkdir -p /run/sshd /var/run/sshd; chmod 755 /run/sshd; [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key; [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key; [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key; operation_result 'Repair SSH' SUCCESS ;;
      5) printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf; operation_result 'Recreate DNS' SUCCESS ;;
      6) export_logs_txt ;;
      0) return ;;
    esac
  done
}
verify_core_files() {
  print_header "VERIFY CORE FILES"
  /usr/local/bin/guard-os-verify 2>/dev/null
  rc=$?
  echo; [ "$rc" -eq 0 ] && echo 'RESULT: PASSED' || echo 'RESULT: FAILED'
  ui_pause
}
run_maintenance() {
  /usr/local/bin/guard-os-maintenance
  operation_result 'Maintenance run' SUCCESS
}
login_appearance_menu() {
  while :; do
    current=$(sed -n 's/^WELCOME_LOGO=//p' /etc/guard-os-welcome.conf 2>/dev/null | head -1); [ -n "$current" ] || current=enabled
    print_header "LOGIN APPEARANCE"
    print_info 'Welcome Logo' "$current"
    print_info Style 'Compact Text'
    print_menu_item 1 'Preview Logo'
    print_menu_item 2 'Enable Logo'
    print_menu_item 3 'Disable Logo'
    print_menu_item 0 Back
    read x < /dev/tty
    case "$x" in
      1) clear_screen; GUARD_OS_WELCOME_SHOWN= WELCOME_LOGO=enabled /usr/local/bin/guard-os-welcome; ui_pause ;;
      2) printf 'WELCOME_LOGO=enabled\n' > /etc/guard-os-welcome.conf; operation_result 'Logo' ENABLED ;;
      3) printf 'WELCOME_LOGO=disabled\n' > /etc/guard-os-welcome.conf; operation_result 'Logo' DISABLED ;;
      0) return ;;
    esac
  done
}
backup_information() {
  /usr/local/bin/guard-os-maintenance >/dev/null 2>&1
  print_header "BACKUP INFORMATION"
  latest=$(ls -1t /sdcard/Guard_OS_backup_*.tar.gz 2>/dev/null | head -1)
  print_info Retention "Newest 3 archives"
  print_info Latest "${latest##*/}"
  print_info Count "$(ls /sdcard/Guard_OS_backup_*.tar.gz 2>/dev/null | wc -l)"
  print_menu_item V 'Verify latest'
  print_menu_item 0 Back
  read x < /dev/tty
  case "$x" in V|v) [ -n "$latest" ] && tar -tzf "$latest" >/dev/null 2>&1 && operation_result 'Verify Backup' PASSED "$latest" || operation_result 'Verify Backup' FAILED ;; esac
}

control_center_final() {
  while :; do
    fast_ip=$(get_local_ip)
    fast_ssh=$(svc_running SSH && echo RUNNING || echo STOPPED)
    fast_pid=$(cat /run/guard-os-autostart.pid 2>/dev/null)
    [ -n "$fast_pid" ] && kill -0 "$fast_pid" 2>/dev/null && fast_supervisor="RUNNING PID $fast_pid" || fast_supervisor=STOPPED
    fast_free=$(free -m 2>/dev/null | awk '/Mem:/{print $7" MB"}'); [ -z "$fast_free" ] && fast_free=N/A
    fast_storage=$(df -h / 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f3-5)
    print_header "GUARD_OS CONTROL CENTER"
    print_info Version "3.1.0 Audited"
    print_info 'IP Address' "$fast_ip"
    print_info SSH "$fast_ssh"
    print_info Supervisor "$fast_supervisor"
    print_info 'Memory Free' "$fast_free"
    print_info Storage "$fast_storage"
    print_info Password "tv"
    print_line
    print_menu_item 1 'Services Manager'
    print_menu_item 2 'Applications Installer'
    print_menu_item 3 'Autostart Manager'
    print_menu_item 4 'Diagnostics and Repair'
    print_menu_item 5 'Storage and Cleanup'
    print_menu_item 6 'Logs and Reports'
    print_menu_item 7 'Backup Information'
    print_menu_item H 'Health and System Info'
    print_menu_item S 'Recovery and Safe Mode'
    print_menu_item V 'Verify Core Files'
    print_menu_item M 'Run Maintenance'
    print_menu_item L 'Login Appearance'
    print_menu_item A About
    print_menu_item '?' 'Quick Help'
    print_menu_item R Refresh
    print_menu_item 0 'Exit to Shell'
    printf ' Choice: '; read x < /dev/tty
    case "$x" in
      1) services_manager ;;
      2) applications_installer_final ;;
      3) autostart_manager_final ;;
      4) diagnostics_final ;;
      5) storage_final ;;
      6) logs_final ;;
      7) backup_information ;;
      H|h) health_dashboard ;;
      S|s) recovery_and_safe_mode ;;
      V|v) verify_core_files ;;
      M|m) run_maintenance ;;
      L|l) login_appearance_menu ;;
      A|a) about_guard_os ;;
      \?) quick_help ;;
      R|r) continue ;;
      0) clear_screen; return ;;
      *) invalid_choice ;;
    esac
  done
}

if [ "$1" = "splash" ]; then
  /usr/local/bin/guard-os-welcome 2>/dev/null
fi
case "$1" in
  start) svc_start "$2" ;;
  stop) svc_stop "$2" ;;
  restart) svc_stop "$2"; svc_start "$2" ;;
  state) svc_state "$2" ;;
  "") control_center_final ;;
esac
SETUPMAIN

  chmod 755 "$TARGET_DIR/usr/local/bin/setup"
  ln -sf /usr/local/bin/setup "$TARGET_DIR/usr/local/bin/tv"

  # Generate checksums
  chroot "$TARGET_DIR" /bin/bash -c "
    cd / || exit 1
    /usr/bin/sha256sum \
      usr/local/bin/setup \
      usr/local/bin/tv_autostart.sh \
      usr/local/bin/tv_watchdog.sh \
      etc/ssh/sshd_config \
      > /etc/guard-os-checksums.sha256
  " 2>/dev/null
  chmod 644 "$TARGET_DIR/etc/guard-os-checksums.sha256" 2>/dev/null

  return 0
}

# ============================================================
# MODULE 08: HOST DIAGNOSTICS, CLEANUP, LOGS, RECOVERY
# ============================================================

host_diagnostics() {
  clear_screen
  print_header "GUARD_OS HOST DIAGNOSTICS"
  R="${TARGET_DIR:-/data/Guard_OS}"
  if [ -x "$R/bin/bash" ]; then
    print_success "RootFS ready: $R"
  else
    print_error "RootFS incomplete"
  fi
  if [ -x /system/bin/Guard_OS_start ]; then
    print_success "Launcher ready"
  else
    print_warning "Launcher missing"
  fi
  for m in "$R/dev" "$R/proc" "$R/sys"; do
    if grep -qs " $m " /proc/mounts; then
      print_success "$m mounted"
    else
      print_warning "$m not mounted"
    fi
  done
  print_info "Free /data" "$(human_mib_from_kib "$(free_kib /data)") MiB"
  print_info "Log" "$HOST_LOG"
  ui_pause
}

host_cleanup() {
  clear_screen
  print_header "HOST STORAGE CLEANUP"
  before_kib=$(free_kib /data)
  temp_size=0
  for f in /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part /data/local/tmp/Guard_OS_scan.tmp; do
    [ -f "$f" ] && s=$(du -sk "$f" 2>/dev/null | cut -f1) && temp_size=$((temp_size + s))
  done
  print_info "Failed downloads/temp" "$(human_mib_from_kib "$temp_size") MiB"
  print_info "Current free /data" "$(human_mib_from_kib "$before_kib") MiB"
  print_line
  print_menu_item 1 "Remove failed downloads and temporary files"
  print_menu_item 2 "Remove incomplete /data/Guard_OS installation"
  print_menu_item 3 "Run both"
  print_menu_item 0 "Back"
  ui_prompt "[0-3]" hc
  case "$hc" in
    1)
      rm -f /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part /data/local/tmp/Guard_OS_scan.tmp
      print_success "Temporary installer files removed"
      ;;
    2)
      umount -l /data/Guard_OS/dev/pts 2>/dev/null
      umount -l /data/Guard_OS/dev 2>/dev/null
      umount -l /data/Guard_OS/proc 2>/dev/null
      umount -l /data/Guard_OS/sys 2>/dev/null
      umount -l /data/Guard_OS/sdcard 2>/dev/null
      rm -rf /data/Guard_OS
      print_success "Incomplete default installation removed"
      ;;
    3)
      umount -l /data/Guard_OS/dev/pts 2>/dev/null
      umount -l /data/Guard_OS/dev 2>/dev/null
      umount -l /data/Guard_OS/proc 2>/dev/null
      umount -l /data/Guard_OS/sys 2>/dev/null
      umount -l /data/Guard_OS/sdcard 2>/dev/null
      rm -rf /data/Guard_OS
      rm -f /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part /data/local/tmp/Guard_OS_scan.tmp
      print_success "Incomplete installation and temporary files removed"
      ;;
    0) return ;;
  esac
  sync
  after_kib=$(free_kib /data)
  print_info "Free /data after cleanup" "$(human_mib_from_kib "$after_kib") MiB"
  ui_pause
}

host_export_txt() {
  R="${TARGET_DIR:-/data/Guard_OS}"
  out="/sdcard/Guard_OS_Full_Logs_$(date +%Y%m%d_%H%M%S).txt"
  [ -d /sdcard ] || out="/data/local/tmp/Guard_OS_Full_Logs_$(date +%Y%m%d_%H%M%S).txt"
  {
    echo "GUARD_OS HOST AND CONTAINER REPORT"
    echo "Generated: $(date)"
    echo "Version: $VERSION"
    for f in /system/etc/guard_os_manifest.conf /system/etc/guard_os.conf /system/etc/install-recovery.sh /data/local/tmp/guard_os_installer.log "$R"/var/log/guard-os/*.log "$R"/etc/tv_autostart.conf "$R"/etc/ssh/sshd_config; do
      [ -f "$f" ] && { echo; echo "===== $f ====="; cat "$f"; }
    done
    echo; echo "===== HOST PROCESSES ====="; ps
    echo; echo "===== HOST MOUNTS ====="; cat /proc/mounts
    echo; echo "===== MEMORY ====="; cat /proc/meminfo
  } > "$out" 2>&1
  ui_status ok "Exported: $out"
  ui_pause
}

# ============================================================
# MODULE 09: BACKUP AND RESTORE
# ============================================================

backup_restore_menu() {
  while true; do
    clear_screen
    print_header "SYSTEM BACKUP & RESTORE"
    ui_menu "1" "Backup Guard_OS to /sdcard"
    ui_menu "2" "Restore from latest backup"
    ui_menu "0" "Back"
    ui_prompt "[0-2]" br
    case "$br" in
      1)
        R="${TARGET_DIR:-/data/Guard_OS}"
        BFILE="/sdcard/Guard_OS_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
        activity_start "Creating backup"
        tar -czf "$BFILE" --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --exclude='run/*' --exclude='tmp/*' --exclude='sdcard/*' -C "$(dirname "$R")" "$(basename "$R")" 2>/dev/null
        activity_stop
        if [ -s "$BFILE" ] && tar -tzf "$BFILE" >/dev/null 2>&1; then
          print_success "Backup created and verified: $BFILE"
        else
          rm -f "$BFILE"
          print_error "Backup failed"
        fi
        ui_pause
        ;;
      2)
        bfile=$(ls -1t /sdcard/Guard_OS_backup_*.tar.gz 2>/dev/null | head -n 1)
        if [ -n "$bfile" ] && [ -f "$bfile" ] && tar -tzf "$bfile" >/dev/null 2>&1; then
          printf "${RED} WARNING: Restoring will overwrite current system!${NC}\n"
          printf "${CYAN}Type RESTORE to confirm: ${NC}"
          read confirm < /dev/tty
          if [ "$confirm" = "RESTORE" ]; then
            R="${TARGET_DIR:-/data/Guard_OS}"
            /system/bin/Guard_OS_stop --with-ssh 2>/dev/null
            umount -l "$R/dev/pts" 2>/dev/null
            umount -l "$R/dev" 2>/dev/null
            umount -l "$R/proc" 2>/dev/null
            umount -l "$R/sys" 2>/dev/null
            umount -l "$R/sdcard" 2>/dev/null
            rm -rf "$R"
            activity_start "Restoring"
            tar -xzf "$bfile" -C "$(dirname "$R")" 2>/dev/null
            activity_stop
            print_success "Restore complete. Please reboot."
          else
            print_warning "Restore cancelled"
          fi
        else
          print_error "No valid backup found in /sdcard/"
        fi
        ui_pause
        ;;
      0) return ;;
    esac
  done
}

# ============================================================
# MODULE 10: SAFE UNINSTALL (NO EXTRA CONFIRMATION)
# ============================================================

safe_uninstall() {
  clear_screen
  ui_detect
  TARGET_DIR=""
  MANIFEST_SOURCE="Legacy scan"

  activity_start "Scanning for Guard_OS installation"

  if [ -r "$SYSTEM_MANIFEST" ]; then
    TARGET_DIR=$(grep '^INSTALL_DIR=' "$SYSTEM_MANIFEST" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r\n')
    [ -n "$TARGET_DIR" ] && MANIFEST_SOURCE="$SYSTEM_MANIFEST"
  fi

  if [ -z "$TARGET_DIR" ]; then
    for check_path in /data/Guard_OS /data/*; do
      if [ -f "$check_path/install_manifest.log" ]; then
        TARGET_DIR=$(grep '^INSTALL_DIR=' "$check_path/install_manifest.log" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r\n')
        [ -n "$TARGET_DIR" ] && { MANIFEST_SOURCE="$check_path/install_manifest.log"; break; }
      fi
    done
  fi

  if [ -z "$TARGET_DIR" ]; then
    if [ -d /data/Guard_OS ]; then
      TARGET_DIR="/data/Guard_OS"
    else
      activity_stop
      printf "\n${RED}  No active Linux installation found.${NC}\n"
      ui_pause
      return
    fi
  fi

  activity_stop

  case "$TARGET_DIR" in
    /data/*|/mnt/*|/storage/*) ;;
    *)
      ui_title "UNINSTALLATION BLOCKED"
      ui_status fail "Unsafe installation path: $TARGET_DIR"
      ui_pause
      return 11
      ;;
  esac

  if [ ! -f "$TARGET_DIR/install_manifest.log" ] || [ ! -x "$TARGET_DIR/bin/bash" ]; then
    ui_status fail "Guard_OS ownership markers missing"
    ui_pause
    return 13
  fi

  ui_title "GUARD_OS UNINSTALLATION REVIEW"
  TOTAL_SIZE="Unknown"
  FILE_COUNT=0
  DIR_COUNT=0

  activity_start "Calculating installation size"
  if [ -d "$TARGET_DIR" ]; then
    TOTAL_SIZE=$(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1)
    FILE_COUNT=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    DIR_COUNT=$(find "$TARGET_DIR" -type d 2>/dev/null | wc -l | tr -d ' ')
  fi
  activity_stop

  ui_row "Install Path" "$TARGET_DIR"
  ui_row "Manifest" "$MANIFEST_SOURCE"
  ui_row "Installed Size" "${TOTAL_SIZE:-Unknown}"
  ui_row "Files" "${FILE_COUNT:-0}"
  ui_row "Directories" "${DIR_COUNT:-0}"
  ui_separator '-'
  ui_status del "REMOVE: Guard_OS RootFS and launcher"
  ui_status del "REMOVE: Guard_OS autostart block"
  ui_status ok "KEEP: /system/bin/install"
  ui_status ok "KEEP: Telnet autostart block"
  ui_menu "1" "Start uninstallation"
  ui_menu "0" "Cancel"
  ui_prompt "[0-1]" choice

  case "$choice" in
    1)
      # No additional confirmation: user already pressed 1
      /system/bin/Guard_OS_stop --with-ssh 2>/dev/null

      umount -l "$TARGET_DIR/dev/pts" 2>/dev/null
      umount -l "$TARGET_DIR/dev/shm" 2>/dev/null
      umount -l "$TARGET_DIR/dev" 2>/dev/null
      umount -l "$TARGET_DIR/sys" 2>/dev/null
      umount -l "$TARGET_DIR/proc" 2>/dev/null
      umount -l "$TARGET_DIR/sdcard" 2>/dev/null
      grep "$TARGET_DIR" /proc/mounts | cut -d' ' -f2 | sort -r | while read -r m; do
        umount -l "$m" 2>/dev/null
      done

      remount_system_rw
      rm -f /system/bin/Guard_OS_start /system/bin/Guard_OS_stop /system/bin/Guard_OS_restart /system/bin/tv /system/bin/setup
      rm -f /system/etc/guard_os.conf /system/etc/guard_os_install.state /system/etc/guard_os_manifest.conf
      if [ -f /system/etc/install-recovery.sh ]; then
        sed -i '/# --- Guard_OS Kernel Autostart ---/,/\/system\/bin\/Guard_OS_start &/d' /system/etc/install-recovery.sh 2>/dev/null
      fi
      remount_system_ro

      activity_start "Deleting $TARGET_DIR"
      rm -rf "$TARGET_DIR" 2>/dev/null
      activity_stop

      if [ ! -e "$TARGET_DIR" ]; then
        print_success "Guard_OS removed successfully"
        remount_system_rw
        rm -f "$SYSTEM_MANIFEST" 2>/dev/null
        remount_system_ro
      else
        print_error "Unable to delete all files"
      fi
      ui_pause
      ;;
    *)
      print_warning "Uninstall cancelled"
      ui_pause
      ;;
  esac
}

# ============================================================
# HOST CLI AND MAIN MENU
# ============================================================

get_installed_root() {
  ROOT="/data/Guard_OS"
  [ -r /system/etc/guard_os.conf ] && . /system/etc/guard_os.conf
  echo "$ROOT"
}

host_cli() {
  case "$1" in
    --dry-run) dry_run_report; exit 0 ;;
    --status)
      R=$(get_installed_root)
      [ -x "$R/bin/bash" ] && echo "Ready: $R" || { echo "Not ready"; exit 1; }
      exit 0
      ;;
    --health)
      R=$(get_installed_root)
      [ -x "$R/bin/bash" ] && [ -x /system/bin/Guard_OS_start ] && exit 0 || exit 1
      ;;
    --clean-temp)
      rm -f /data/local/tmp/rootfs.tar.gz /data/local/tmp/rootfs.tar.xz /data/local/tmp/rootfs.tar.gz.part /data/local/tmp/rootfs.tar.xz.part /data/local/tmp/Guard_OS_scan.tmp
      exit 0
      ;;
    --help|-h)
      echo "install [--dry-run|--status|--health|--clean-temp|--help]"
      exit 0
      ;;
  esac
}

host_guard_control() {
  R=$(get_installed_root)
  while :; do
    clear_screen
    ui_title "GUARD_OS HOST CONTROL"
    ui_row "Install Path" "$R"
    [ -x "$R/bin/bash" ] && ready=READY || ready=MISSING
    ui_row "RootFS" "$ready"
    spid=$(cat "$R/run/guard-os-autostart.pid" 2>/dev/null || echo STOPPED)
    ui_row "Supervisor" "$spid"
    ui_separator '-'
    ui_menu 1 "Start Guard_OS"
    ui_menu 2 "Stop optional services, preserve SSH"
    ui_menu 3 "Full stop including SSH and mounts"
    ui_menu 4 "Restart Guard_OS"
    ui_menu 5 "Enter Guard_OS shell"
    ui_menu 6 "Show Guard_OS processes"
    ui_menu 7 "Show active mounts"
    ui_menu 8 "Export full logs to TXT"
    ui_menu 0 "Back"
    ui_prompt "[0-8]" x
    case "$x" in
      1) /system/bin/Guard_OS_start </dev/null >/dev/null 2>&1; sleep 3 ;;
      2) /system/bin/Guard_OS_stop ;;
      3)
        printf "${YELLOW}Type FULL to confirm: ${NC}"
        read c < /dev/tty
        [ "$c" = "FULL" ] && /system/bin/Guard_OS_stop --with-ssh || echo "  Cancelled."
        ;;
      4) /system/bin/Guard_OS_restart </dev/null >/dev/null 2>&1 & sleep 5 ;;
      5) /system/bin/Guard_OS_start ;;
      6)
        for p in /proc/[0-9]*; do
          [ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && {
            echo "${p##*/} $(tr '\000' ' ' < "$p/cmdline" 2>/dev/null)"
          }
        done
        ui_pause
        ;;
      7) grep " $R/" /proc/mounts; ui_pause ;;
      8) host_export_txt ;;
      0) return ;;
    esac
  done
}

host_recovery_menu() {
  R=$(get_installed_root)
  while :; do
    clear_screen
    ui_title "RECOVERY AND SAFE MODE"
    ui_menu 1 "Start Guard_OS normally"
    ui_menu 2 "Start SSH only"
    ui_menu 3 "Disable optional Autostart"
    ui_menu 4 "Remove stale Supervisor lock"
    ui_menu 5 "Repair mount points"
    ui_menu 6 "Export logs"
    ui_menu 0 "Back"
    ui_prompt "[0-6]" x
    case "$x" in
      1) /system/bin/Guard_OS_start </dev/null >/dev/null 2>&1 ;;
      2)
        for m in dev proc sys dev/pts; do mkdir -p "$R/$m"; done
        mount -o bind /dev "$R/dev" 2>/dev/null
        mount -t proc proc "$R/proc" 2>/dev/null
        mount -t sysfs sysfs "$R/sys" 2>/dev/null
        mount -t devpts devpts "$R/dev/pts" 2>/dev/null
        chroot "$R" /bin/bash -c 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; mkdir -p /run/sshd; chmod 755 /run/sshd; [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N "" -f /etc/ssh/ssh_host_rsa_key; [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N "" -f /etc/ssh/ssh_host_ecdsa_key; [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/ssh_host_ed25519_key; /usr/sbin/sshd -t && /usr/sbin/sshd'
        ;;
      3)
        for k in $OPTIONAL_SERVICES; do
          sed -i "/^$k=/d" "$R/etc/tv_autostart.conf"
          echo "$k=disabled" >> "$R/etc/tv_autostart.conf"
        done
        ;;
      4)
        p=$(cat "$R/run/guard-os-autostart.pid" 2>/dev/null)
        [ -z "$p" ] || [ ! -d "/proc/$p" ] && rm -rf "$R/run/guard-os-autostart.lock" "$R/run/guard-os-autostart.pid"
        ;;
      5) /system/bin/Guard_OS_start </dev/null >/dev/null 2>&1 ;;
      6) host_export_txt ;;
      0) return ;;
    esac
  done
}

# ============================================================
# GENERATE HOST LAUNCHERS (Guard_OS_start, stop, restart)
# ============================================================

generate_host_launchers() {
  cat << 'SEOF' > /system/bin/Guard_OS_start
#!/system/bin/sh
export TERM=xterm
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:/vendor/xbin:$PATH
ROOT="/data/Guard_OS"
[ -r /system/etc/guard_os.conf ] && . /system/etc/guard_os.conf
[ -x "$ROOT/bin/bash" ] || { echo "Guard_OS RootFS missing: $ROOT" >&2; exit 1; }
is_mounted() { grep -qs " $1 " /proc/mounts 2>/dev/null; }

[ -e /dev/stdin ] || ln -sf /proc/self/fd/0 /dev/stdin 2>/dev/null
[ -e /dev/stdout ] || ln -sf /proc/self/fd/1 /dev/stdout 2>/dev/null
[ -e /dev/stderr ] || ln -sf /proc/self/fd/2 /dev/stderr 2>/dev/null
[ -d "$ROOT/dev" ] && ! is_mounted "$ROOT/dev" && mount -o bind /dev "$ROOT/dev" 2>/dev/null
[ -d "$ROOT/dev/pts" ] && ! is_mounted "$ROOT/dev/pts" && mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null
[ -d "$ROOT/proc" ] && ! is_mounted "$ROOT/proc" && mount -t proc proc "$ROOT/proc" 2>/dev/null
[ -d "$ROOT/sys" ] && ! is_mounted "$ROOT/sys" && mount -t sysfs sysfs "$ROOT/sys" 2>/dev/null
mkdir -p "$ROOT/dev/shm" 2>/dev/null
[ -d "$ROOT/dev/shm" ] && ! is_mounted "$ROOT/dev/shm" && mount -t tmpfs tmpfs "$ROOT/dev/shm" 2>/dev/null

SD_SRC="/data/media/0"
[ ! -d "$SD_SRC" ] && SD_SRC="/storage/emulated/0"
[ -d "$ROOT/sdcard" ] && [ -d "$SD_SRC" ] && mount -o bind "$SD_SRC" "$ROOT/sdcard" 2>/dev/null
[ -d "$ROOT/mnt" ] && mount -o bind /mnt "$ROOT/mnt" 2>/dev/null || mount -o bind /storage "$ROOT/mnt" 2>/dev/null

chroot "$ROOT" /bin/bash -c "
  unset LD_LIBRARY_PATH
  export TMPDIR=/tmp
  export TERM=xterm
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH
  mkdir -p /run/sshd /var/run/sshd /var/log/guard-os 2>/dev/null
  chmod 0755 /run/sshd /var/run/sshd 2>/dev/null || true
  [ -s /etc/ssh/ssh_host_rsa_key ] || /usr/bin/ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/ssh_host_rsa_key >> /var/log/guard-os/ssh-start.log 2>&1
  [ -s /etc/ssh/ssh_host_ecdsa_key ] || /usr/bin/ssh-keygen -q -t ecdsa -b 256 -N '' -f /etc/ssh/ssh_host_ecdsa_key >> /var/log/guard-os/ssh-start.log 2>&1
  [ -s /etc/ssh/ssh_host_ed25519_key ] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key >> /var/log/guard-os/ssh-start.log 2>&1
  if /usr/sbin/sshd -t >> /var/log/guard-os/ssh-start.log 2>&1; then
    ps aux 2>/dev/null | grep -q '[s]shd' || /usr/sbin/sshd >> /var/log/guard-os/ssh-start.log 2>&1
  fi
  if [ -f /usr/local/bin/tv_autostart.sh ]; then
    nohup /usr/local/bin/tv_autostart.sh </dev/null >/dev/null 2>&1 &
  fi
" 2>/dev/null

if [ -t 0 ]; then
  chroot "$ROOT" /bin/bash -l
fi
SEOF
  chmod 755 /system/bin/Guard_OS_start

  cat << 'TVEOF' > /system/bin/tv
#!/system/bin/sh
ROOT="/data/Guard_OS"
[ -r /system/etc/guard_os.conf ] && . /system/etc/guard_os.conf
if [ -t 0 ]; then
  chroot "$ROOT" /usr/local/bin/setup
else
  echo "Interactive terminal required." >&2
fi
TVEOF
  chmod 755 /system/bin/tv
  ln -sf /system/bin/tv /system/bin/setup 2>/dev/null || true
  ln -sf /system/bin/tv /system/bin/TV 2>/dev/null || true

  cat << 'STOPEOF' > /system/bin/Guard_OS_stop
#!/system/bin/sh
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:/vendor/xbin:$PATH
ROOT="/data/Guard_OS"
MANIFEST="/system/etc/guard_os_manifest.conf"
if [ -r "$MANIFEST" ]; then
  INSTALL_DIR=$(grep '^INSTALL_DIR=' "$MANIFEST" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r\n')
  [ -n "$INSTALL_DIR" ] && ROOT="$INSTALL_DIR"
fi
[ -r /system/etc/guard_os.conf ] && . /system/etc/guard_os.conf

case "$ROOT" in
  /data/*|/mnt/*|/storage/*) ;;
  *) echo "Unsafe Guard_OS path: $ROOT" >&2; exit 11 ;;
esac

FULL_STOP=0
[ "$1" = "--with-ssh" ] && FULL_STOP=1

for pdir in /proc/[0-9]*; do
  [ -d "$pdir" ] || continue
  pid="${pdir##*/}"
  [ "$pid" = "$$" ] && continue
  root_link=$(readlink "$pdir/root" 2>/dev/null)
  [ "$root_link" = "$ROOT" ] || continue
  cmdline=$(tr '\000' ' ' < "$pdir/cmdline" 2>/dev/null)
  case "$cmdline" in
    *tv_autostart.sh*|*tv_watchdog.sh*|*AdGuardHome*|*smbd*|*nmbd*|*zerotier-one*|*dnscrypt-proxy*|*nginx*|*iperf3*|*node-red*|*hass*|*meyectl*|*ttyd*)
      kill -TERM "$pid" 2>/dev/null || true
      ;;
  esac
done
sleep 1
rm -rf "$ROOT/run/guard-os-autostart.lock" "$ROOT/run/guard-os-autostart.pid" 2>/dev/null || true

if [ "$FULL_STOP" -eq 1 ]; then
  for pdir in /proc/[0-9]*; do
    [ -d "$pdir" ] || continue
    pid="${pdir##*/}"
    [ "$pid" = "$$" ] && continue
    root_link=$(readlink "$pdir/root" 2>/dev/null)
    [ "$root_link" = "$ROOT" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pdir in /proc/[0-9]*; do
    [ -d "$pdir" ] || continue
    pid="${pdir##*/}"
    [ "$pid" = "$$" ] && continue
    root_link=$(readlink "$pdir/root" 2>/dev/null)
    [ "$root_link" = "$ROOT" ] && kill -KILL "$pid" 2>/dev/null || true
  done
  grep " $ROOT/" /proc/mounts 2>/dev/null | cut -d' ' -f2 | sort -r | while read -r mount_point; do
    [ -n "$mount_point" ] && umount -l "$mount_point" 2>/dev/null || true
  done
  for mount_point in "$ROOT/sdcard" "$ROOT/dev/pts" "$ROOT/dev/shm" "$ROOT/dev" "$ROOT/proc" "$ROOT/sys"; do
    while grep -qs " $mount_point " /proc/mounts 2>/dev/null; do
      umount -l "$mount_point" 2>/dev/null || break
    done
  done
  echo "Guard_OS fully stopped"
else
  echo "Guard_OS optional services stopped; SSH preserved"
fi
exit 0
STOPEOF
  chmod 755 /system/bin/Guard_OS_stop

  cat << 'RESTARTEOF' > /system/bin/Guard_OS_restart
#!/system/bin/sh
export PATH=/system/bin:/system/xbin:/sbin:/vendor/bin:/vendor/xbin:$PATH
if [ ! -x /system/bin/Guard_OS_stop ] || [ ! -x /system/bin/Guard_OS_start ]; then
  echo "Guard_OS start or stop command is missing." >&2
  exit 1
fi
/system/bin/Guard_OS_stop --with-ssh || exit $?
sleep 2
exec /system/bin/Guard_OS_start
RESTARTEOF
  chmod 755 /system/bin/Guard_OS_restart
}

# ============================================================
# UPDATE AUTOSTART FILE
# ============================================================

update_autostart() {
  remount_system_rw || return 1
  touch /system/etc/install-recovery.sh
  if [ ! -s /system/etc/install-recovery.sh ]; then
    echo '#!/system/bin/sh' > /system/etc/install-recovery.sh
  fi
  chmod 755 /system/etc/install-recovery.sh

  if ! grep -q 'Guard_OS_start' /system/etc/install-recovery.sh 2>/dev/null; then
    if grep -q 'telnetd' /system/etc/install-recovery.sh 2>/dev/null; then
      sed -i '/telnetd/a \
\
# --- Guard_OS Kernel Autostart ---\
sleep 20\
/system/bin/Guard_OS_start &' /system/etc/install-recovery.sh
    elif grep -q '/system/etc/install-recovery-2.sh' /system/etc/install-recovery.sh 2>/dev/null; then
      sed -i '/\/system\/etc\/install-recovery-2.sh/a \
\
# --- TELNET Kernel Autostart ---\
busybox telnetd -l /system/bin/sh -p 23 &\
\
# --- Guard_OS Kernel Autostart ---\
sleep 20\
/system/bin/Guard_OS_start &' /system/etc/install-recovery.sh
    else
      echo '' >> /system/etc/install-recovery.sh
      echo '# --- TELNET Kernel Autostart ---' >> /system/etc/install-recovery.sh
      echo 'busybox telnetd -l /system/bin/sh -p 23 &' >> /system/etc/install-recovery.sh
      echo '' >> /system/etc/install-recovery.sh
      echo '# --- Guard_OS Kernel Autostart ---' >> /system/etc/install-recovery.sh
      echo 'sleep 20' >> /system/etc/install-recovery.sh
      echo '/system/bin/Guard_OS_start &' >> /system/etc/install-recovery.sh
    fi
  fi

  if ! ps | grep -v grep | grep -q telnetd; then
    busybox telnetd -l /system/bin/sh -p 23 2>/dev/null || true
  fi

  remount_system_ro
  return 0
}

# ============================================================
# MAIN INSTALLATION FUNCTION
# ============================================================

install_Guard_OS() {
  clear_screen
  preflight_check || { ui_pause; return 3; }
  set_install_stage "STORAGE_SELECTION" "starting" || return 1

  select_target_dir || { ui_pause; return 4; }
  detect_architecture || { ui_pause; return 2; }
  select_channel || { ui_pause; return 4; }

  if [ -x /system/bin/Guard_OS_stop ]; then
    /system/bin/Guard_OS_stop --with-ssh 2>/dev/null || true
  fi

  download_and_extract_rootfs || { ui_pause; return 5; }

  prepare_rootfs_dirs
  mount_chroot
  setup_network_config

  install_base_packages || { ui_pause; return 9; }

  create_control_center_scripts || { ui_pause; return 10; }

  generate_host_launchers

  update_autostart || { ui_pause; return 11; }

  remount_system_rw || return 1
  mkdir -p /system/etc
  cat > "$SYSTEM_MANIFEST" <<EOF
MANIFEST_VERSION=1
GUARD_OS_VERSION=$VERSION
BUILD_TYPE=clean-rebuild
PROJECT_STATUS=complete
DEFAULT_PASSWORD=tv
BACKUP_RETENTION=3
LOG_ROTATION=enabled
SSH_KEY_POLICY=RSA,ECDSA,ED25519
INSTALL_DIR=$TARGET_DIR
ROOTFS_ARCH=$ROOTFS_ARCH
ROOTFS_CHANNEL=$RELEASE_CHANNEL
ROOTFS_SOURCE=$ROOTFS_SOURCE
ROOTFS_SIZE=$ROOTFS_SIZE
HOST_START=/system/bin/Guard_OS_start
HOST_STOP=/system/bin/Guard_OS_stop
HOST_RESTART=/system/bin/Guard_OS_restart
HOST_CONFIG=/system/etc/guard_os.conf
HOST_STATE=/system/etc/guard_os_install.state
HOST_AUTOSTART=/system/etc/install-recovery.sh
CONTAINER_SETUP=/usr/local/bin/setup
OPTIONAL_SERVICES=ADGUARD,SAMBA,ZEROTIER,DNSCRYPT,NGINX,IPERF3,NODERED,HASS,MOTIONEYE,TTYD
BACKUP_RESTORE=enabled
RELEASE_CHANNEL=stable
CONTAINER_AUTOSTART=/usr/local/bin/tv_autostart.sh
CONTAINER_WATCHDOG=/usr/local/bin/tv_watchdog.sh
CONTAINER_AUTOSTART_PID=/run/guard-os-autostart.pid
CONTAINER_AUTOSTART_LOCK=/run/guard-os-autostart.lock
CONTAINER_AUTOSTART_LOG=/var/log/guard-os/autostart.log
CONTAINER_INSTALL_MANIFEST=$TARGET_DIR/install_manifest.log
BASE_LOG=$TARGET_DIR/var/log/guard-os/base-install.log
SSH_LOG=$TARGET_DIR/var/log/guard-os/ssh-start.log
CREATED_AT=$(now)
EOF
  chmod 600 "$SYSTEM_MANIFEST"

  cat > /system/etc/guard_os.conf <<EOF
ROOT='$TARGET_DIR'
VERSION='$VERSION'
ROOTFS_ARCH='$ROOTFS_ARCH'
ROOTFS_CHANNEL='$RELEASE_CHANNEL'
ROOTFS_SOURCE='$ROOTFS_SOURCE'
ROOTFS_SIZE='$ROOTFS_SIZE'
EOF
  chmod 644 /system/etc/guard_os.conf

  complete_install_state

  # Guard_OS_start will handle starting sshd safely in a clean environment

  /system/bin/Guard_OS_start </dev/null >/dev/null 2>&1

  clear_screen
  ui_title "INSTALLATION COMPLETED"
  ui_status ok "Guard_OS $VERSION installed successfully"
  ui_row "Install Path" "$TARGET_DIR"
  ui_row "RootFS" "$ROOTFS_SOURCE"
  ip_addr=$(ip addr 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | head -1 | sed 's/.*inet \([0-9\.]*\).*/\1/')
  [ -z "$ip_addr" ] && ip_addr="Unknown"
  ui_row "IP" "$ip_addr"
  ui_row "SSH" "root@<IP>:22, password: tv"
  ui_row "Control" "type 'tv' or 'setup'"
  ui_separator '-'
  ui_status info "install preserved"
  ui_status info "Telnet autostart preserved"
  ui_pause
  return 0
}

# ============================================================
# MAIN MENU
# ============================================================

show_splash_screen() {
  clear_screen
  ui_detect
  ui_title "GUARD_OS INSTALLER v$VERSION"
  ui_row "Author" "Ashraf Saber"
  ui_row "Platform" "Android TV Box / ARM"
  ui_row "RootFS" "Ubuntu Base noble / Alpine Minimal"
  ui_separator '-'
  ui_status info "Integrated installation and control suite"
  ui_pause
}

# ============================================================
# ENTRY POINT
# ============================================================

host_cli "$1"

show_splash_screen

while true; do
  clear_screen
  ui_detect
  ui_title "GUARD_OS INSTALLATION CENTER"
  MR=$(get_installed_root 2>/dev/null)
  if [ -x "$MR/bin/bash" ]; then
    MS="Installed"
  else
    MS="Not Installed"
  fi
  ui_row "Version" "$VERSION"
  ui_row "Architecture" "$(uname -m)"
  ui_row "Installation" "$MS"
  ui_row "Install Path" "$MR"
  ui_row "Free /data" "$(human_mib_from_kib "$(free_kib /data)") MiB"
  ui_row "Free /data/local/tmp" "$(human_mib_from_kib "$(free_kib /data/local/tmp)") MiB"
  ui_separator '='
  ui_menu 1 "Install or Repair Guard_OS"
  ui_menu 2 "Uninstall Guard_OS"
  ui_menu 3 "Backup and Restore"
  ui_menu 4 "Guard_OS Host Control"
  ui_menu 5 "Host Diagnostics"
  ui_menu 6 "Logs and Reports"
  ui_menu 7 "Storage Cleanup"
  ui_menu 8 "Recovery and Safe Mode"
  ui_menu 9 "Dry Run Report"
  ui_menu R "Reboot Android"
  ui_menu 0 "Exit"
  ui_prompt "[0-9/R]" choice
  case $choice in
    1) install_Guard_OS ;;
    2) safe_uninstall ;;
    3) backup_restore_menu ;;
    4) host_guard_control ;;
    5) host_diagnostics ;;
    6) host_export_txt ;;
    7) host_cleanup ;;
    8) host_recovery_menu ;;
    9) dry_run_report ;;
    R|r) busybox reboot -f 2>/dev/null || reboot -f 2>/dev/null || setprop sys.powerctl reboot ;;
    0) clear_screen; exit 0 ;;
  esac
done
GUARD_OS_install_EOF
rc=$?
if [ "$rc" -ne 0 ]; then
  rm -f "$TARGET"
  remount_ro
  printf '%s\n' "Failed to create $TARGET" >&2
  exit "$rc"
fi
chmod 755 "$TARGET" || { rm -f "$TARGET"; remount_ro; exit 1; }
if ! /system/bin/sh -n "$TARGET" 2>/dev/null; then
  rm -f "$TARGET"
  remount_ro
  printf '%s\n' "Generated installer failed syntax validation." >&2
  exit 1
fi
remount_ro
exec "$TARGET" "$@"
