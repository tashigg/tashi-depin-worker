#!/bin/bash

IMAGE_TAG='ghcr.io/tashigg/tashi-depin-worker:0'
TROUBLESHOOT_LINK='https://docs.tashi.gg/resources/depin/worker-node-install-docker#troubleshooting'
NEXT_STEP_LINK='http://localhost:9000/'
COMMAND_CENTER_URL='https://depin.tashi.dev/'
RUST_LOG='info,tashi_depin_worker=debug,tashi_depin_common=debug'

AGENT_PORT=39065

# Color codes
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"
CHECKMARK="${GREEN}✓${RESET}"
CROSSMARK="${RED}✗${RESET}"
WARNING="${YELLOW}⚠${RESET}"

WARNINGS=0
ERRORS=0

SCRIPT_ARGS="$@"

# Logging function with timestamps
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    printf "[${timestamp}] [${level}] ${message}\n" 1>&2
}

# Detect OS safely
detect_os() {
    OS=$(source /etc/os-release >/dev/null 2>&1; echo "${ID:-unknown}")
    if [[ "$OS" == "unknown" && "$(uname -s)" == "Darwin" ]]; then
        OS="macos"
    fi
}

# Suggest package installation securely
suggest_install() {
    local package=$1
    case "$OS" in
        debian|ubuntu) echo "    sudo apt update && sudo apt install -y $package" ;;
        fedora) echo "    sudo dnf install -y $package" ;;
        arch) echo "    sudo pacman -S --noconfirm $package" ;;
        opensuse) echo "    sudo zypper install -y $package" ;;
        macos) echo "    brew install $package" ;;
        *) echo "    Please install '$package' manually for your OS." ;;
    esac
}

# Resolve commands dynamically
NPROC_CMD=$(command -v nproc || echo "")
GREP_CMD=$(command -v grep || echo "")
DF_CMD=$(command -v df || echo "")
DOCKER_CMD=$(command -v docker || echo "")
PODMAN_CMD=$(command -v podman || echo "")

# Check if a command exists
check_command() {
    command -v "$1" >/dev/null 2>&1
}

# CPU Check
check_cpu() {
    case "$OS" in
        "macos")
            threads=$(sysctl -n hw.ncpu)
        ;;
        *)
            if [[ -z "$NPROC_CMD" ]]; then
                log "WARNING" "'nproc' not found. Install coreutils:"
                suggest_install "coreutils"
                ((ERRORS++))
                return
            fi
            threads=$("$NPROC_CMD")
        ;;
    esac

    if [[ "$threads" -ge 4 ]]; then
        log "INFO" "CPU Check: ${CHECKMARK} Found $threads threads (>= 4 recommended)"
    elif [[ "$threads" -ge 2 ]]; then
        log "WARNING" "CPU Check: ${WARNING} Found $threads threads (>= 2 required, 4 recommended)"
        ((WARNINGS++))
    else
        log "ERROR" "CPU Check: ${CROSSMARK} Only $threads threads found (Minimum: 2 required)"
        ((ERRORS++))
    fi
}

# Memory Check
check_memory() {
    if [[ -z "$GREP_CMD" ]]; then
        log "ERROR" "Memory Check: ${WARNING} 'grep' not found. Install grep:"
        suggest_install "grep"
        ((ERRORS++))
        return
    fi

    case "$OS" in
      "macos")
        total_mem_bytes=$(sysctl -n hw.memsize)
        total_mem_kb=$((total_mem_bytes / 1024))        
      ;;
      *)
        total_mem_kb=$("$GREP_CMD" MemTotal /proc/meminfo | awk '{print $2}')
      ;;
    esac
    
    total_mem_gb=$((total_mem_kb / 1024 / 1024))

    if [[ "$total_mem_gb" -ge 4 ]]; then
        log "INFO" "Memory Check: ${CHECKMARK} Found ${total_mem_gb}GB RAM (>= 4GB recommended)"
    elif [[ "$total_mem_gb" -ge 2 ]]; then
        log "WARNING" "Memory Check: ${WARNING} Found ${total_mem_gb}GB RAM (>= 2GB required, 4GB recommended)"
        ((WARNINGS++))
    else
        log "ERROR" "Memory Check: ${CROSSMARK} Only ${total_mem_gb}GB RAM found (Minimum: 2GB required)"
        ((ERRORS++))
    fi
}

# Disk Space Check
check_disk() {
    case "$OS" in
      "macos")
        available_disk_kb=$(
            "$DF_CMD" -kcI 2>/dev/null \
                | tail -1 \
                | awk '{print $4}'
        )
        total_mem_bytes=$(sysctl -n hw.memsize)
      ;;
      *)
        available_disk_kb=$(
            "$DF_CMD" -kx tmpfs --total 2>/dev/null \
                | tail -1 \
                | awk '{print $4}'
        )
      ;;
    esac

    available_disk_gb=$((available_disk_kb / 1024 / 1024))

    if [[ "$available_disk_gb" -ge 20 ]]; then
        log "INFO" "Disk Space Check: ${CHECKMARK} Found ${available_disk_gb}GB free (>= 20GB required)"
    else
        log "ERROR" "Disk Space Check: ${CROSSMARK} Only ${available_disk_gb}GB free space (Minimum: 20GB required)"
        ((ERRORS++))
    fi
}

# Docker or Podman Check

check_container_runtime() {
    if check_command "docker"; then
        log "INFO" "Container Runtime Check: ${CHECKMARK} Docker is installed"
        CONTAINER_RT=docker
    elif check_command "podman"; then
        log "INFO" "Container Runtime Check: ${CHECKMARK} Podman is installed"
        CONTAINER_RT=podman
    else
        log "ERROR" "Container Runtime Check: ${CROSSMARK} Neither Docker nor Podman is installed."
        suggest_install "docker.io"
        suggest_install "podman"
        ((ERRORS++))
    fi
}

get_local_ip() {
  if check_command hostname; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
  elif check_command ip; then
    # Use `ip route` to find what IP address connects to the internet
    LOCAL_IP=$(ip route get '1.0.0.0' | grep -Po "src \K(\S+)")
  fi
}

get_public_ip() {
    PUBLIC_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
}

# Check network connectivity & NAT status
check_nat() {
    # Step 1: Confirm Public Internet Access (No ICMP Required)
    if curl -s --head --connect-timeout 3 https://google.com | grep "HTTP" >/dev/null 2>&1; then
        log "INFO" "Internet Connectivity: ${CHECKMARK} Device has public Internet access."
    elif wget --spider --timeout=3 --quiet https://google.com; then
        log "INFO" "Internet Connectivity: ${CHECKMARK} Device has public Internet access."
    else
        log "ERROR" "Internet Connectivity: ${CROSSMARK} No internet access detected!"
        ((ERRORS++))
        return
    fi

    # Step 2: Get local & public IP
    get_local_ip
    get_public_ip

    if [[ -z "$LOCAL_IP" ]]; then
        log "WARNING" "NAT Check: ${WARNING} Could not determine local IP."
        ((WARNINGS++))
        return
    fi

    if [[ -z "$PUBLIC_IP" ]]; then
        log "WARNING" "NAT Check: ${WARNING} Could not determine public IP."
        ((WARNINGS++))
        return
    fi

    # Step 3: Determine NAT Type
    if [[ "$LOCAL_IP" == "$PUBLIC_IP" ]]; then
        log "INFO" "NAT Check: ${CHECKMARK} Open NAT / Publicly accessible (Public IP: $PUBLIC_IP)"
        return
    fi

    log "WARNING" "NAT Check: ${WARNING} NAT detected (Local: $LOCAL_IP, Public: $PUBLIC_IP)"
    log "WARNING" "If this device is not accessible from the Internet, some DePIN services will be disabled; earnings may be less than a publicly accessible node."
    log "WARNING" "Ensure port forwarding of UDP port $AGENT_PORT is properly configured, or otherwise expose this device to the Internet."
    ((WARNINGS++))
}

check_root_required() {
  if [[ "$CONTAINER_RT" == "docker" ]]; then
    if (groups "$USER" | grep docker >/dev/null); then
      log "INFO" "Privilege Check: ${CHECKMARK} User is in 'docker' group."
      log "INFO" "Worker container can be started without needing superuser privileges."
    elif [[ -w "$DOCKER_HOST" ]] || [[ -w "/var/run/docker.sock" ]]; then
      log "INFO" "Privilege Check: ${CHECKMARK} User has access to the Docker daemon socket."
      log "INFO" "Worker container can be started without needing superuser privileges."
    else
      SUDO_CMD="sudo -g docker"
      log "WARNING" "Privilege Check: ${WARNING} User is not in 'docker' group."
      log "WARNING" "${WARNING} 'docker run' command will be executed using '${SUDO_CMD}'"
      log "WARNING" "For more information, see https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user"
      ((WARNINGS++))
    fi
  elif [[ "$CONTAINER_RT" == "podman" ]]; then
    # Check that the user and their login group are assigned substitute ID ranges
    if (grep "^$USER:" /etc/subuid >/dev/null) && (grep "^$(id -gn):" /etc/subgid >/dev/null); then
      log "INFO" "Privilege Check: ${CHECKMARK} User can create Podman containers without root."
      log "INFO" "Worker container can be started without needing superuser privileges."
    else
      SUDO_CMD="sudo"
      log "WARNING" "Privilege Check: ${WARNING} User cannot create rootless Podman containers."
      log "WARNING" "${WARNING} 'podman run' command will be executed using '${SUDO_CMD}'"
      log "WARNING" "For more information, see https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md"
      ((WARNINGS++))
    fi
  fi
}

continue_prompt() {
    if [[ "$SCRIPT_ARGS" == *'--ignore-warnings'* ]]; then
        return 0
    elif [[ ! (-t 2) ]]; then # If stderr is not connected to a TTY, we can't prompt.
        log "ERROR" "Script not running in interactive mode. Re-run script with flag '--ignore-warnings'"
        exit 1
    fi

    # Always read from TTY even if piped in
    read -r -p "Do you want to continue anyway? (y/N) " choice </dev/tty
    case "$choice" in
        y|Y ) log "INFO" "Continuing..." ;;
        * ) log "ERROR" "Exiting."; exit 1 ;;
    esac
}

# User confirmation if warnings exist
ask_continue() {
    if [[ "$ERRORS" -gt 0 ]]; then
        log "ERROR" "System does not meet minimum requirements. Exiting."
        exit 1
    elif [[ "$WARNINGS" -gt 0 ]]; then
        log "WARNING" "System meets minimum but not recommended requirements."
        continue_prompt
    fi
}

# Display ASCII Art (Tashi Logo)
display_logo() {
    echo -e "\n
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
#-:::::::::::::::::::::::::::::=%@@@@@@@@@@@@@@%=:::::::::::::::::::::::::::::-#
@@*::::::::::::::::::::::::::::::+%@@@@@@@@@@%+::::::::::::::::::::::::::::::*@@
@@@@+::::::::::::::::::::::::::::::+%@@@@@@%+::::::::::::::::::::::::::::::+@@@@
@@@@@%=::::::::::::::::::::::::::::::+%@@%+::::::::::::::::::::::::::::::=%@@@@@
@@@@@@@#-::::::::::::::::::::::::::::::@@::::::::::::::::::::::::::::::-#@@@@@@@
@@@@@@@@@*:::::::::::::::::::::::::::::@@:::::::::::::::::::::::::::::*@@@@@@@@@
@@@@@@@@@@%+:::::::::::::::::::::::::::@@:::::::::::::::::::::::::::+%@@@@@@@@@@
@@@@@@@@@@@@%++++++++++++-:::::::::::::@@:::::::::::::-++++++++++++%@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@#-:::::::::::@@:::::::::::-#@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@*::::::::::@@::::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@#:::::::::@@:::::::::#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%+:::::::@@:::::::+%@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-::::@@::::-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-::@@::-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@#=@@=#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" 1>&2
}

# Detect OS before running checks
detect_os

# Run all checks
display_logo
log "INFO" "Starting system checks..."
check_cpu
check_memory
check_disk
check_container_runtime
check_root_required
check_nat  # <- Integrated NAT check

ask_continue

log "INFO" "All checks passed or user chose to continue."

RUN_COMMAND=$(
cat << EOF
${SUDO_CMD:+"$SUDO_CMD "}${CONTAINER_RT} run -d -p "$AGENT_PORT:$AGENT_PORT" -p 127.0.0.1:9000:9000 \
--name tashi-depin-worker -e RUST_LOG="$RUST_LOG" \
$([[ $CONTAINER_RT == "docker" ]] && echo "--restart=always") \
--pull=always $IMAGE_TAG \
--license-authorized-account-key-path=./license-key \
--generate-license-authorized-account-key \
--token-id-save-path=./token-id \
--command-center-url "$COMMAND_CENTER_URL" \
${PUBLIC_IP:+"--agent-public-addr=$PUBLIC_IP:$AGENT_PORT"}
EOF
)

sh -c "set -ex; $RUN_COMMAND"

if [[ $? -ne 0 ]]; then
    log "ERROR" "Worker failed to start: ${CROSSMARK} Please see the following page for troubleshooting instructions: ${TROUBLESHOOT_LINK}."
    exit 1
fi

log "INFO" "Worker is running: ${CHECKMARK} Next step is to assign the worker a license token."

OPEN_COMMAND=$(command -v xdg-open || command -v open || echo "")

if [[ -n "$OPEN_COMMAND" && -t 2 ]]; then
  read -r -p "Open the following page in your browser? <${NEXT_STEP_LINK}> (Y/n) " choice </dev/tty
  case "$choice" in
      n|N ) ;;
      * )
        $OPEN_COMMAND "${NEXT_STEP_LINK}"
        log "INFO" "See the web page in your browser for the next step."
        exit 0
      ;;
  esac
fi

log "INFO" "Please navigate to <${NEXT_STEP_LINK}> in your browser to continue."



