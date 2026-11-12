#!/usr/bin/env bash
#
# Controller stager for CCDC Ansible automation.
#
# This script prepares the Ubuntu controller, but does not change any remote
# host. It is safe to run repeatedly: the virtual environment, packages,
# collections, and existing encrypted vault are preserved when already ready.
#
# The remote Ansible password is never a command-line argument. It is read from
# the terminal without echo, written only to a mode-600 temporary file, and
# encrypted in place before the temporary file is removed.

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VENV_DIR="$SCRIPT_DIR/.venv"
VAULT_FILE="$SCRIPT_DIR/group_vars/all/vault.yml"
PYTHON_BIN_OVERRIDE="${PYTHON_BIN:-}"
PYTHON_BIN=''
PYTHON_MINOR=''
ANSIBLE_PACKAGE=()
CHECK_ONLY=0
UPDATE_VAULT=0
USE_ANSIBLE_PASSWORD_AS_VAULT_PASSWORD=0
OPEN_SHELL=0

usage() {
    cat <<'EOF'
Usage: ./stager.sh [options]

Prepare the Ubuntu Ansible controller and create the encrypted shared-password
vault. The remote ansible-user password is always entered interactively.

  --check                         Audit controller setup without changes
  --update-vault                  Replace the existing encrypted vault value
  --use-ansible-password-as-vault Use the remote password as the vault key
  --shell                         Open a new shell with the venv activated
  -h, --help                      Show this help

Normal first run:
  bash ./stager.sh

Afterward:
  source .venv/bin/activate
  ansible-playbook site.yml --ask-vault-pass
EOF
}

status() { printf '[%s] %s\n' "$1" "$2"; }
die() { status FAIL "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --update-vault) UPDATE_VAULT=1; shift ;;
        --use-ansible-password-as-vault) USE_ANSIBLE_PASSWORD_AS_VAULT_PASSWORD=1; shift ;;
        --shell) OPEN_SHELL=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done

[[ $CHECK_ONLY -eq 0 || $OPEN_SHELL -eq 0 ]] \
    || die '--shell cannot be combined with --check'

[[ -r /etc/os-release ]] || die '/etc/os-release is missing'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "This controller stager supports Ubuntu/Debian, found '${ID:-unknown}'" ;;
esac

if [[ $EUID -eq 0 ]]; then
    SUDO=()
elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
else
    die 'sudo is required when this script is not run as root'
fi

install_controller_packages() {
    status INFO 'Installing controller prerequisites'
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" apt-get install -y -q \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
        sshpass
}

find_supported_python() {
    local candidate path version major minor
    local -a candidates=()
    [[ -n "$PYTHON_BIN_OVERRIDE" ]] && candidates+=("$PYTHON_BIN_OVERRIDE")
    candidates+=(python3.13 python3.12 python3.11 python3)

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == */* ]]; then
            path=$candidate
        else
            path=$(command -v "$candidate" 2>/dev/null || true)
        fi
        [[ -x "$path" ]] || continue
        version=$("$path" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || true)
        major=${version%%.*}
        minor=${version#*.}
        [[ "$major" == 3 && "$minor" =~ ^[0-9]+$ ]] || continue
        (( minor >= 11 )) || continue
        PYTHON_BIN=$path
        PYTHON_MINOR=$minor
        return 0
    done
    return 1
}

ensure_controller_python() {
    if ! find_supported_python; then
        status INFO 'Python 3.11+ was not found; trying supported Ubuntu packages'
        install_supported_python_packages || {
            [[ "${ID:-}" == ubuntu ]] || die 'Python 3.11+ is unavailable in the configured repositories. Use Ubuntu or add a trusted Python repository, then rerun this script.'
            status INFO 'Ubuntu repositories did not provide Python 3.11+; enabling the Deadsnakes PPA'
            "${SUDO[@]}" apt-get install -y -q software-properties-common
            "${SUDO[@]}" add-apt-repository -y ppa:deadsnakes/ppa
            "${SUDO[@]}" apt-get update -qq
            install_supported_python_packages || die 'Could not install Python 3.11, 3.12, or 3.13 from Ubuntu or Deadsnakes.'
        }
        find_supported_python || die 'Python installation completed but no supported interpreter was found.'
    fi

    case "$PYTHON_MINOR" in
        12|13) ANSIBLE_PACKAGE=(ansible) ;;
        11)    ANSIBLE_PACKAGE=('ansible>=12,<13') ;;
        *)     die "Unsupported controller Python minor version: $PYTHON_MINOR" ;;
    esac
    status OK "Using controller Python $PYTHON_MINOR at $PYTHON_BIN"
}

install_supported_python_packages() {
    local package
    for package in python3.13 python3.12 python3.11; do
        if "${SUDO[@]}" apt-get install -y -q "$package" "${package}-venv"; then
            return 0
        fi
    done
    return 1
}

setup_virtualenv() {
    if [[ -x "$VENV_DIR/bin/python" ]]; then
        local existing_minor
        existing_minor=$("$VENV_DIR/bin/python" -c 'import sys; print(sys.version_info[1])' 2>/dev/null || true)
        if [[ "$existing_minor" != "$PYTHON_MINOR" ]]; then
            local old_venv="$VENV_DIR-old-$(date +%Y%m%d-%H%M%S)"
            status WARN "Existing virtual environment uses Python $existing_minor; moving it to $old_venv"
            mv -- "$VENV_DIR" "$old_venv"
        fi
    fi

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        status INFO "Creating $VENV_DIR"
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    else
        status OK 'Controller virtual environment already exists'
    fi

    status INFO 'Installing Ansible and PSRP dependencies'
    "$VENV_DIR/bin/python" -m pip install --upgrade pip "${ANSIBLE_PACKAGE[@]}" pypsrp

    status INFO 'Installing Ansible collections'
    "$VENV_DIR/bin/ansible-galaxy" collection install \
        -r "$SCRIPT_DIR/requirements.yml"
}

read_secret_confirm() {
    local label="$1" first second
    while true; do
        IFS= read -r -s -p "$label: " first
        printf '\n'
        IFS= read -r -s -p 'Retype: ' second
        printf '\n'
        if [[ -z "$first" ]]; then
            status WARN 'The value cannot be empty'
        elif [[ "$first" != "$second" ]]; then
            status WARN 'Values did not match; try again'
        else
            REPLY=$first
            unset first second
            return 0
        fi
        unset first second
    done
}

setup_vault() {
    if [[ -f "$VAULT_FILE" && $UPDATE_VAULT -eq 0 ]]; then
        if head -n 1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT;'; then
            status OK 'Encrypted vault already exists; preserving it'
            return 0
        fi
        die "$VAULT_FILE exists but is not an Ansible Vault file; use --update-vault after reviewing it"
    fi

    local ansible_password vault_password plaintext vault_key escaped_password
    status INFO 'Enter the shared password already assigned to the remote ansible user'
    read_secret_confirm 'Remote ansible-user password'
    ansible_password=$REPLY

    if [[ $USE_ANSIBLE_PASSWORD_AS_VAULT_PASSWORD -eq 1 ]]; then
        vault_password=$ansible_password
    else
        status INFO 'Enter a separate password for encrypting the Ansible Vault'
        read_secret_confirm 'Ansible Vault password'
        vault_password=$REPLY
    fi

    plaintext=$(mktemp "$SCRIPT_DIR/.vault-plaintext.XXXXXX")
    vault_key=$(mktemp "$SCRIPT_DIR/.vault-key.XXXXXX")
    trap 'rm -f -- "$plaintext" "$vault_key"' RETURN
    chmod 600 "$plaintext" "$vault_key"

    # YAML single-quoted scalars escape a literal apostrophe by doubling it.
    escaped_password=${ansible_password//\'/\'\'}
    printf -- "---\nvault_ansible_password: '%s'\n" "$escaped_password" > "$plaintext"
    printf '%s' "$vault_password" > "$vault_key"

    "$VENV_DIR/bin/ansible-vault" encrypt \
        --vault-password-file "$vault_key" "$plaintext" >/dev/null
    mkdir -p "$(dirname -- "$VAULT_FILE")"
    chmod 700 "$(dirname -- "$VAULT_FILE")"
    mv -f -- "$plaintext" "$VAULT_FILE"
    chmod 600 "$VAULT_FILE"
    rm -f -- "$vault_key"
    trap - RETURN
    unset ansible_password vault_password escaped_password plaintext vault_key
    status OK "Encrypted vault written to $VAULT_FILE"
}

check_controller() {
    local failures=0
    if [[ -x "$VENV_DIR/bin/ansible-playbook" ]]; then
        status OK 'ansible-playbook is installed in the controller virtual environment'
        "$VENV_DIR/bin/ansible-playbook" --version | sed -n '1,3p'
    else
        status FAIL 'ansible-playbook is not installed'
        failures=$((failures + 1))
    fi
    "$VENV_DIR/bin/python" -c 'import pypsrp' >/dev/null 2>&1 \
        && status OK 'pypsrp is installed' \
        || { status FAIL 'pypsrp is not installed'; failures=$((failures + 1)); }
    [[ -f "$VAULT_FILE" ]] \
        && head -n 1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT;' \
        && status OK 'encrypted vault exists' \
        || { status FAIL 'encrypted vault is missing'; failures=$((failures + 1)); }
    return "$failures"
}

main() {
    if [[ $CHECK_ONLY -eq 1 ]]; then
        [[ -x "$VENV_DIR/bin/python" ]] || die "Missing $VENV_DIR; run ./stager.sh first"
        check_controller
        return $?
    fi

    install_controller_packages
    ensure_controller_python
    setup_virtualenv
    setup_vault
    status OK 'Controller staging complete'
    printf '\nActivate the controller environment with:\n  source %s/bin/activate\n' "$VENV_DIR"

    if [[ $OPEN_SHELL -eq 1 ]]; then
        [[ -t 0 && -t 1 ]] || die '--shell requires an interactive terminal'
        # The parent shell cannot be modified by a child script. Activating
        # here and replacing this process provides an interactive activated
        # shell; type exit to return to the original shell.
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
        status OK 'Opening an interactive shell with the Ansible venv active; type exit to return'
        exec "${SHELL:-/bin/bash}" -i
    fi
}

main "$@"
