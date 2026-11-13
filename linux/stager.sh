#!/bin/bash
#
# stager.sh
#
# Stage 0 - get a fresh Linux box ready to be managed by Ansible.
#
# When this finishes the box has:
#   1. Python, so Ansible modules can run
#   2. an "ansible" user whose password is typed at the terminal
#      (never an argument, never in shell history, never written to disk)
#   3. full sudo for that user, WITH a password (no NOPASSWD)
#   4. sshd accepting password logins for that user
#
# Every step checks the live, effective state first and only changes what is
# actually wrong, so it is safe to re-run. It ends with a readiness report
# built from fresh checks plus an inventory entry (YAML) to paste into
# inventory.yml on the controller, under the appropriate Linux role group.
#
#   sudo ./stager.sh                  set up this box (interactive)
#   sudo ./stager.sh --check          audit only, change nothing
#   sudo ./stager.sh --user <name>    set up a different username
#   curl -sL <raw url> | sudo bash    also works, prompts read from /dev/tty
#
# Oct. 2026

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
umask 077

ANSIBLE_USER="ansible"
CHECK_ONLY=0
MIN_PW_LEN=8
SSHD_CONFIG="/etc/ssh/sshd_config"
SUDOERS_DROPIN="/etc/sudoers.d/zz-ansible-stage0"
LOG="/var/log/stage0-ansible.log"
BACKUP_DIR="/var/backups/stage0-$(date +%Y%m%d-%H%M%S)"
MARK_BEGIN="# >>> stage0-ansible >>>"
MARK_END="# <<< stage0-ansible <<<"
STEP=0
STEPS=5
FAILS=0
RELOCK=()


# ---------------------------------------------------------------- output ----

# Colors only on a terminal, unicode marks only on a UTF-8 locale
if [[ -t 1 ]]
then
    c_ok=$'\e[32m' c_err=$'\e[31m' c_warn=$'\e[33m' c_dim=$'\e[2m' c_bold=$'\e[1m' c_reset=$'\e[0m'
else
    c_ok="" c_err="" c_warn="" c_dim="" c_bold="" c_reset=""
fi
if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]]
then
    i_ok="✔" i_err="✘" i_warn="!" i_arrow="›"
else
    i_ok="+" i_err="x" i_warn="!" i_arrow=">"
fi

log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$c_bold" "$STEP" "$STEPS" "$1" "$c_reset"; log "== $1"; }
ok()   { printf '  %s%s%s %s\n' "$c_ok" "$i_ok" "$c_reset" "$*"; log "ok: $*"; }
warn() { printf '  %s%s%s %s\n' "$c_warn" "$i_warn" "$c_reset" "$*"; log "warn: $*"; }
bad()  { printf '  %s%s%s %s\n' "$c_err" "$i_err" "$c_reset" "$*"; log "FAIL: $*"; }
note() {
    local line
    while IFS= read -r line
    do
        printf '    %s%s %s%s\n' "$c_dim" "$i_arrow" "$line" "$c_reset"
    done <<< "$*"
    log "$*"
}
die()  { printf '%sERROR:%s %s\n' "$c_err" "$c_reset" "$*" >&2; exit 1; }

# run <cmd...>: run a command non-interactively, output to the log instead of the screen
run() { log "\$ $*"; "$@" < /dev/null >> "$LOG" 2>&1; }

# row ok|warn|bad <label> <detail>: one line of the final report
row() {
    local icon color
    case $1 in
        ok)   icon=$i_ok   color=$c_ok ;;
        warn) icon=$i_warn color=$c_warn ;;
        *)    icon=$i_err  color=$c_err; FAILS=$((FAILS + 1)) ;;
    esac
    printf '  %s%s%s %-10s %s\n' "$color" "$icon" "$c_reset" "$2" "$3"
}

# ask_yn <question> <y|n>: yes/no prompt on the terminal, second arg is the default
ask_yn() {
    local ans hint="[y/N]"
    [[ $2 == y ]] && hint="[Y/n]"
    printf '  %s?%s %s %s ' "$c_warn" "$c_reset" "$1" "$hint" >&3
    IFS= read -r ans <&3 || ans=""
    [[ ${ans:-$2} == [Yy]* ]]
}

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Stage 0 for Ansible: install Python, create the '$ANSIBLE_USER' user (password
prompted), give it sudo (password required) and let it SSH in with a password.

  -c, --check         audit only: change nothing, exit 1 if not ready
  -u, --user <name>   username to set up (default: ansible)
  -h, --help          show this help

There is deliberately no --password option. The password is only ever read
from the terminal, so it never shows up in argv, ps output or shell history.
EOF
}


# --------------------------------------------------------------- helpers ----

# backup <file>: copy a file into $BACKUP_DIR once per run, path left in BACKUP_LAST
backup() {
    local name=${1#/}
    BACKUP_LAST="$BACKUP_DIR/${name//\//_}"
    [[ -e $1 && ! -e $BACKUP_LAST ]] || return 0
    mkdir -p "$BACKUP_DIR" && cp -a "$1" "$BACKUP_LAST" && note "backup: $BACKUP_LAST"
}

# unlock <file...>: drop chattr +i/+a (old hardening scripts set these) until exit
unlock() {
    local f attrs
    command -v lsattr >/dev/null 2>&1 || return 0
    for f in "$@"
    do
        [[ -e $f ]] || continue
        attrs=$(lsattr -d "$f" 2>/dev/null | awk '{ print $1 }' | tr -cd 'ia')
        [[ -n $attrs ]] || continue
        if chattr -ia "$f" 2>/dev/null
        then
            RELOCK+=("$attrs:$f")
            warn "$f was immutable (+$attrs), unlocked until this script exits"
        fi
    done
}

cleanup() {
    local e
    { stty echo <&3; } 2>/dev/null
    for e in "${RELOCK[@]}"
    do
        chattr "+${e%%:*}" "${e#*:}" 2>/dev/null
    done
    [[ -n $RMDIR_ON_EXIT ]] && rmdir "$RMDIR_ON_EXIT" 2>/dev/null
    [[ -n $TMPD ]] && rm -rf "$TMPD"
}

detect_pkg() {
    local pm
    PKG=""
    for pm in apt-get dnf yum zypper apk pacman
    do
        command -v "$pm" >/dev/null 2>&1 && { PKG=$pm; return; }
    done
}

# pkg_name python|sshd: the package that provides it on this distro
pkg_name() {
    case "$1:$PKG" in
        python:pacman) echo python ;;
        python:*)      echo python3 ;;
        sshd:pacman)   echo openssh ;;
        sshd:*)        echo openssh-server ;;
        *)             echo "$1" ;;
    esac
}

pkg_install() {
    local rc
    note "installing $* with ${PKG:-no package manager}"
    case $PKG in
        apt-get)
            [[ -n $APT_FRESH ]] || { run apt-get update -q; APT_FRESH=1; }
            run apt-get install -y -q --no-install-recommends "$@" ;;
        dnf|yum) run "$PKG" install -y -q "$@" ;;
        zypper)  run zypper -n -q install "$@" ;;
        apk)     run apk add -q "$@" ;;
        pacman)  run pacman -Sy --noconfirm --needed "$@" ;;
        *)       return 1 ;;
    esac
    rc=$?
    if (( rc != 0 ))
    then
        tail -n 4 "$LOG" | sed "s/^/      ${c_dim}/; s/\$/${c_reset}/"
    fi
    return $rc
}

short_host() {
    local h
    h=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)
    echo "${h%%.*}"
}


# ---------------------------------------------------------------- python ----

# find_python: sets PY / PY_VER to the best interpreter Ansible would discover
find_python() {
    local c
    PY="" PY_VER=""
    for c in python3 /usr/libexec/platform-python python
    do
        command -v "$c" >/dev/null 2>&1 || continue
        PY=$(command -v "$c")
        PY_VER=$("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) && return 0
    done
    PY="" PY_VER=""
    return 1
}

# ver_ge <a.b.c> <x.y>: major.minor comparison
ver_ge() {
    local -a a b
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    (( a[0] > b[0] || (a[0] == b[0] && a[1] >= b[1]) ))
}

do_python() {
    step "Python"
    if find_python && [[ $PY_VER == 3.* ]]
    then
        ok "$PY ($PY_VER)"
    else
        [[ -n $PY ]] && warn "only $PY ($PY_VER) found, Ansible wants Python 3"
        if (( CHECK_ONLY ))
        then
            bad "python3 is not installed"
            return
        fi
        if pkg_install "$(pkg_name python)" && find_python && [[ $PY_VER == 3.* ]]
        then
            ok "installed $PY ($PY_VER)"
        else
            bad "could not install python3 (no internet? EOL distro with dead mirrors?)"
            return
        fi
    fi
    if ! ver_ge "$PY_VER" 3.7
    then
        warn "Python $PY_VER < 3.7: ansible-core 2.17+ cannot manage this box"
        note "use ansible-core <= 2.16 on the controller, or install a newer python (e.g. python39 on EL8)"
    fi
}


# ------------------------------------------------------------------ user ----

shadow_field() { awk -F: -v u="$ANSIBLE_USER" -v f="$1" '$1 == u { print $f }' /etc/shadow 2>/dev/null; }
passwd_shell() { awk -F: -v u="$ANSIBLE_USER" '$1 == u { print $7 }' /etc/passwd; }
login_shell()  { if [[ -x /bin/bash ]]; then echo /bin/bash; else echo /bin/sh; fi; }

# A hash starting with ! or * (or no hash at all) means password login is impossible
password_usable() {
    case "$(shadow_field 2)" in
        ''|'!'*|'*'*) return 1 ;;
    esac
    return 0
}

# account_issues: one line per account problem that would break an Ansible login
account_issues() {
    local today last max expire
    case "$(passwd_shell)" in
        ''|*/nologin|*/false) echo "login shell is '$(passwd_shell)'" ;;
    esac
    today=$(( $(date +%s) / 86400 ))
    last=$(shadow_field 3) max=$(shadow_field 5) expire=$(shadow_field 8)
    [[ $last == 0 ]] && echo "password change is forced at next login"
    [[ -n $expire && $expire -ge 0 && $expire -le $today ]] && echo "account has expired"
    [[ -n $last && -n $max && $max -ge 0 && $max -lt 99999 && $((last + max)) -lt $today ]] && echo "password has expired"
}

fix_account() {
    local issue
    command -v faillock  >/dev/null 2>&1 && run faillock --user "$ANSIBLE_USER" --reset
    command -v pam_tally2 >/dev/null 2>&1 && run pam_tally2 --user "$ANSIBLE_USER" --reset
    [[ -n $(account_issues) ]] || return 0

    while IFS= read -r issue
    do
        warn "$issue, fixing"
    done <<< "$(account_issues)"
    case "$(passwd_shell)" in
        ''|*/nologin|*/false) run usermod -s "$(login_shell)" "$ANSIBLE_USER" ;;
    esac
    if command -v chage >/dev/null 2>&1
    then
        run chage -E -1 -M 99999 "$ANSIBLE_USER"
        [[ $(shadow_field 3) == 0 ]] && run chage -d "$(date +%Y-%m-%d)" "$ANSIBLE_USER"
    fi
}

# set_password: read twice from the terminal and hand it to chpasswd on stdin.
# printf is a builtin, so the password never appears in argv, ps or history.
set_password() {
    while :
    do
        printf '  %s New password for %s: ' "$i_arrow" "$ANSIBLE_USER" >&3
        IFS= read -rs PW1 <&3 || die "no input on the terminal"
        printf '\n' >&3
        if (( ${#PW1} < MIN_PW_LEN ))
        then
            warn "must be at least $MIN_PW_LEN characters"
            continue
        fi
        printf '  %s Retype password: ' "$i_arrow" >&3
        IFS= read -rs PW2 <&3 || die "no input on the terminal"
        printf '\n' >&3
        if [[ $PW1 != "$PW2" ]]
        then
            warn "passwords do not match, try again"
            continue
        fi
        if printf '%s:%s\n' "$ANSIBLE_USER" "$PW1" | chpasswd >> "$LOG" 2>&1
        then
            unset PW1 PW2
            ok "password set (not logged anywhere)"
            return 0
        fi
        warn "chpasswd rejected that password (see $LOG), try another"
    done
}

do_user() {
    local new_pw=0 issues issue
    step "User '$ANSIBLE_USER'"
    (( CHECK_ONLY )) || unlock /etc/passwd /etc/shadow /etc/group /etc/gshadow

    if id "$ANSIBLE_USER" >/dev/null 2>&1
    then
        ok "exists (uid $(id -u "$ANSIBLE_USER"), groups: $(id -Gn "$ANSIBLE_USER" | tr ' ' ','))"
    elif (( CHECK_ONLY ))
    then
        bad "does not exist"
        return
    else
        if command -v useradd >/dev/null 2>&1
        then
            run useradd -m -s "$(login_shell)" -c "Ansible automation" "$ANSIBLE_USER"
        else
            run adduser -D -s "$(login_shell)" -g "Ansible automation" "$ANSIBLE_USER"
        fi || { bad "could not create the user (see $LOG)"; return; }
        ok "created (uid $(id -u "$ANSIBLE_USER"), home $(awk -F: -v u="$ANSIBLE_USER" '$1 == u { print $6 }' /etc/passwd))"
        new_pw=1
    fi

    if password_usable
    then
        ok "has a password"
        if (( ! CHECK_ONLY )) && ask_yn "Set a new password for '$ANSIBLE_USER'?" n
        then
            new_pw=1
        fi
    elif (( CHECK_ONLY ))
    then
        bad "has no usable password (empty or locked)"
    else
        (( new_pw )) || warn "has no usable password (empty or locked)"
        new_pw=1
    fi
    (( new_pw )) && set_password

    (( CHECK_ONLY )) || fix_account
    issues=$(account_issues)
    if [[ -z $issues ]]
    then
        ok "account is active (shell $(passwd_shell), not expired)"
    else
        while IFS= read -r issue
        do
            bad "$issue"
        done <<< "$issues"
    fi
}


# ------------------------------------------------------------------ sudo ----

# sudo_eval: ask sudo itself what the user may do. Sets:
#   SUDO_FULL      1 if some rule grants (ALL) ALL
#   SUDO_NOPASS    rule lines carrying NOPASSWD (for diagnostics)
#   SUDO_DEFAULTS  net effect of Defaults that break become: !authenticate rootpw targetpw runaspw
sudo_eval() {
    local out
    SUDO_FULL=0 SUDO_NOPASS="" SUDO_DEFAULTS=""
    command -v sudo >/dev/null 2>&1 || return 1
    out=$(sudo -l -U "$ANSIBLE_USER" 2>&1)
    grep -qE '^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+([A-Z_]+:[[:space:]]*)*ALL[[:space:]]*$' <<< "$out" && SUDO_FULL=1
    SUDO_NOPASS=$(grep -E '^[[:space:]]*\(.*\).*NOPASSWD' <<< "$out")
    # Defaults are listed in parse order and later ones win, so replay them
    SUDO_DEFAULTS=$(sed -n '/^Matching Defaults/,/may run the following/p' <<< "$out" | tr ',' '\n' | awk '
        { gsub(/^[ \t]+|[ \t]+$/, "") }
        $0 == "!authenticate" { on["!authenticate"] = 1 }
        $0 == "authenticate"  { on["!authenticate"] = 0 }
        /^!?(rootpw|targetpw|runaspw)$/ { f = $0; sub(/^!/, "", f); on[f] = (substr($0, 1, 1) != "!") }
        END { for (k in on) if (on[k]) printf "%s ", k }')
    SUDO_DEFAULTS=${SUDO_DEFAULTS% }
}

# sudo_passwordless: ground truth, not parsing. Can the user sudo right now
# without a password? (-k ignores cached credentials, -n never prompts)
sudo_passwordless() {
    if command -v runuser >/dev/null 2>&1
    then
        runuser -u "$ANSIBLE_USER" -- sudo -nk true >/dev/null 2>&1
    else
        su -s /bin/sh -c 'sudo -nk true' "$ANSIBLE_USER" >/dev/null 2>&1
    fi
}

# group_granted <group>: does sudoers give %group full sudo with a password?
group_granted() {
    grep -qsE "^[[:space:]]*%$1[[:space:]]+ALL[[:space:]]*=[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]*ALL[[:space:]]*\$" \
        /etc/sudoers /etc/sudoers.d/*
}

# write_sudo_rule: our own rule for the user, validated with visudo before it
# goes live. sudo applies the LAST matching rule and Defaults:user beat global
# Defaults, so this also overrides NOPASSWD / !authenticate / rootpw from
# elsewhere - for this one user only. The zz- name sorts after everything else
# in sudoers.d (e.g. cloud-init's 90-cloud-init-users).
write_sudo_rule() {
    local tmp="$TMPD/sudoers" rule
    rule=$(printf '%s\n' \
        "# Ansible become: full sudo, always asking for $ANSIBLE_USER's own password." \
        "# Managed by stager.sh" \
        "Defaults:$ANSIBLE_USER authenticate, !rootpw, !targetpw, !runaspw" \
        "$ANSIBLE_USER ALL=(ALL:ALL) PASSWD: ALL")
    unlock /etc/sudoers /etc/sudoers.d "$SUDOERS_DROPIN"

    if grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers
    then
        printf '%s\n' "$rule" > "$tmp"
        chmod 0440 "$tmp"
        visudo -cqf "$tmp" >> "$LOG" 2>&1 || { bad "generated sudoers rule failed visudo, nothing changed"; return 1; }
        backup "$SUDOERS_DROPIN"
        install -m 0440 -o root -g root "$tmp" "$SUDOERS_DROPIN" || return 1
        ok "wrote $SUDOERS_DROPIN"
        warn "the old secure-os.sh comments out everything in /etc/sudoers.d, re-run stage 0 after it"
    else
        # No includedir: append to the end of sudoers itself (end = wins)
        strip_block /etc/sudoers > "$tmp"
        printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$rule" "$MARK_END" >> "$tmp"
        chmod 0440 "$tmp"
        visudo -cqf "$tmp" >> "$LOG" 2>&1 || { bad "edited sudoers failed visudo, nothing changed"; return 1; }
        backup /etc/sudoers
        cat "$tmp" > /etc/sudoers
        ok "added a stage0 block to the end of /etc/sudoers (no includedir found)"
    fi
    sudo_eval
}

grant_sudo() {
    local g
    unlock /etc/group /etc/gshadow

    # Preferred: the distro admin group. Survives anything that wipes sudoers.d.
    for g in sudo wheel admin
    do
        getent group "$g" >/dev/null 2>&1 || continue
        group_granted "$g" || continue
        if command -v usermod >/dev/null 2>&1
        then
            run usermod -aG "$g" "$ANSIBLE_USER"
        else
            run addgroup "$ANSIBLE_USER" "$g"
        fi
        sudo_eval
        if (( SUDO_FULL ))
        then
            ok "added to group '$g'"
            return 0
        fi
    done
    write_sudo_rule
}

do_sudo() {
    step "sudo (password required)"
    if ! command -v sudo >/dev/null 2>&1
    then
        if (( CHECK_ONLY ))
        then
            bad "sudo is not installed"
            return
        fi
        pkg_install sudo || { bad "could not install sudo"; return; }
        ok "installed sudo"
    fi
    if ! id "$ANSIBLE_USER" >/dev/null 2>&1
    then
        bad "user '$ANSIBLE_USER' does not exist"
        return
    fi

    sudo_eval
    (( SUDO_FULL || CHECK_ONLY )) || grant_sudo
    if (( SUDO_FULL ))
    then
        ok "'$ANSIBLE_USER' may run ALL commands"
    else
        bad "'$ANSIBLE_USER' does not have full sudo"
        return
    fi

    # Passwordless sudo, or Defaults that make become want root's password
    if (( ! CHECK_ONLY )) && { sudo_passwordless || [[ -n $SUDO_DEFAULTS ]]; }
    then
        sudo_passwordless && warn "sudo works WITHOUT a password for '$ANSIBLE_USER', overriding"
        [[ -n $SUDO_DEFAULTS ]] && warn "sudoers Defaults '$SUDO_DEFAULTS' break become, overriding"
        write_sudo_rule
    fi

    if sudo_passwordless
    then
        bad "sudo works WITHOUT a password for '$ANSIBLE_USER'"
        [[ -n $SUDO_NOPASS ]] && note "$(head -n 3 <<< "$SUDO_NOPASS" | awk '{ $1 = $1; print }')"
        note "find it with: grep -rn 'NOPASSWD\|authenticate' /etc/sudoers /etc/sudoers.d"
    else
        ok "sudo asks for a password (tested with sudo -nk as $ANSIBLE_USER)"
    fi
    [[ -z $SUDO_DEFAULTS ]] || bad "sudoers Defaults '$SUDO_DEFAULTS' make become want root's password"
}


# ------------------------------------------------------------------- ssh ----

find_sshd() {
    SSHD=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
    [[ -x $SSHD ]]
}

# sshd_key <keyword>: value(s) of a keyword from the last sshd -T dump
sshd_key() {
    awk -v k="$1" '$1 == k { for (i = 2; i <= NF; i++) v = v (v == "" ? "" : " ") $i } END { print v }' <<< "$SSH_T"
}

# sshd_eval <config>: the EFFECTIVE settings sshd would apply to our user,
# after Include files, drop-ins and Match blocks. Straight from sshd -T.
sshd_eval() {
    local cfg=$1 spec good=0
    SSH_PORT=$("$SSHD" -T -f "$cfg" 2>/dev/null | awk '$1 == "port" { print $2; exit }')
    SSH_PORT=${SSH_PORT:-22}
    # Newer sshd insists on laddr/lport when the config has Match LocalPort etc.
    for spec in "user=$ANSIBLE_USER,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$SSH_PORT" \
                "user=$ANSIBLE_USER,host=localhost,addr=127.0.0.1"
    do
        SSH_T=$("$SSHD" -T -f "$cfg" -C "$spec" 2> "$TMPD/sshd.err") && { good=1; break; }
    done
    if (( ! good ))
    then
        SSH_ERR=$(head -n 3 "$TMPD/sshd.err")
        return 1
    fi
    SSH_PWAUTH=$(sshd_key passwordauthentication)
    SSH_AUTHM=$(sshd_key authenticationmethods)
    SSH_ALLOWU=$(sshd_key allowusers)
    SSH_ALLOWG=$(sshd_key allowgroups)
    SSH_DENYU=$(sshd_key denyusers)
    SSH_DENYG=$(sshd_key denygroups)
}

# matches_any "<names>" "<sshd patterns>": any name matches any pattern? (space-separated)
matches_any() {
    local -a names pats
    local n p
    read -ra names <<< "$1"
    read -ra pats <<< "$2"
    for n in "${names[@]}"
    do
        for p in "${pats[@]}"
        do
            # shellcheck disable=SC2053  # unquoted on purpose: sshd patterns are globs
            [[ $n == ${p%%@*} ]] && return 0
        done
    done
    return 1
}

# ssh_needs: from the last sshd_eval, which Match-block lines would let our user in
ssh_needs() {
    local m groups=""
    NEED=() SSH_DENIED=""
    [[ $SSH_PWAUTH == yes ]] || NEED+=("PasswordAuthentication yes")

    # AuthenticationMethods: fine if unset, "any", or one alternative is plain "password"
    if [[ -n $SSH_AUTHM && $SSH_AUTHM != any ]]
    then
        m=" $SSH_AUTHM "
        # ("any" is rejected inside Match once a global value exists)
        [[ $m == *" password "* ]] || NEED+=("AuthenticationMethods publickey password")
    fi

    id "$ANSIBLE_USER" >/dev/null 2>&1 && groups=$(id -Gn "$ANSIBLE_USER")
    if [[ -n $SSH_ALLOWU ]] && ! matches_any "$ANSIBLE_USER" "$SSH_ALLOWU"
    then
        NEED+=("AllowUsers $ANSIBLE_USER")
    fi
    if [[ -n $SSH_ALLOWG && -n $groups ]] && ! matches_any "$groups" "$SSH_ALLOWG"
    then
        NEED+=("AllowGroups $(id -gn "$ANSIBLE_USER")")
    fi
    matches_any "$ANSIBLE_USER" "$SSH_DENYU" && SSH_DENIED="DenyUsers"
    matches_any "$groups" "$SSH_DENYG" && SSH_DENIED="DenyGroups"
    return 0
}

strip_block() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$1"
}

# insert_block <file>: put our Match block right before the first Match line.
# sshd uses the first value it finds, so being above other Match blocks matters.
insert_block() {
    local blk line
    blk=$(
        printf '%s\n' "$MARK_BEGIN" \
            "# Password SSH for the Ansible user only. Managed by stager.sh." \
            "# Keep this above other Match blocks: sshd uses the first value it finds." \
            "Match User $ANSIBLE_USER"
        for line in "${NEED[@]}"
        do
            printf '    %s\n' "$line"
        done
        printf '%s' "$MARK_END"
    )
    BLK=$blk awk '!done && tolower($1) == "match" { print ENVIRON["BLK"]; done = 1 } { print } END { if (!done) print ENVIRON["BLK"] }' "$1"
}

# sshd_listening: yes|no|unknown. Reads the kernel table directly so it works
# on minimal boxes without ss/netstat: local address is hex "IP:PORT", 0A = LISTEN
sshd_listening() {
    [[ -r /proc/net/tcp ]] || { echo unknown; return; }
    awk -v p="$(printf ':%04X' "${SSH_PORT:-22}")" \
        '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { print (f ? "yes" : "no") }' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# sshd_service reload|ensure: talk to whatever init system this box has
sshd_service() {
    local unit=""
    if [[ -d /run/systemd/system ]]
    then
        for unit in ssh sshd ""
        do
            [[ -n $unit ]] && systemctl cat "$unit.service" >/dev/null 2>&1 && break
        done
    fi

    if [[ -n $unit ]]
    then
        if [[ $1 == reload ]]
        then
            systemctl -q is-active "$unit.service" && run systemctl reload "$unit.service"
            return
        fi
        # Ubuntu 22.10+ may run sshd through ssh.socket instead of the service
        if ! systemctl -q is-enabled "$unit.service" 2>/dev/null && ! systemctl -q is-enabled ssh.socket 2>/dev/null
        then
            run systemctl enable "$unit.service" && ok "enabled $unit.service at boot"
        fi
        if ! systemctl -q is-active "$unit.service" && ! systemctl -q is-active ssh.socket 2>/dev/null
        then
            run systemctl start "$unit.service" && ok "started $unit.service"
        fi
    elif command -v rc-service >/dev/null 2>&1
    then
        if [[ $1 == reload ]]
        then
            rc-service sshd status >/dev/null 2>&1 && run rc-service sshd reload
            return
        fi
        rc-update show default 2>/dev/null | grep -qw sshd || run rc-update add sshd default
        rc-service sshd status >/dev/null 2>&1 || { run rc-service sshd start && ok "started sshd"; }
    elif [[ -x /etc/init.d/ssh || -x /etc/init.d/sshd ]]
    then
        unit=sshd
        [[ -x /etc/init.d/ssh ]] && unit=ssh
        if [[ $1 == reload ]]
        then
            run "/etc/init.d/$unit" status && run "/etc/init.d/$unit" reload
            return
        fi
        run "/etc/init.d/$unit" status || { run "/etc/init.d/$unit" start && ok "started $unit"; }
    else
        # No init system (containers, odd rescue boxes): drive the daemon directly
        if [[ $1 == reload ]]
        then
            if [[ -f /run/sshd.pid ]]
            then
                kill -HUP "$(cat /run/sshd.pid)" 2>/dev/null
            else
                pkill -HUP -o -x sshd 2>/dev/null
            fi
            return
        fi
        [[ $(sshd_listening) == no ]] && run "$SSHD" && ok "started $SSHD (no init system found)"
    fi
}

do_ssh() {
    local cand="$TMPD/sshd_config" base="$TMPD/sshd_base" line
    step "SSH password login"

    if ! find_sshd
    then
        if (( CHECK_ONLY ))
        then
            bad "OpenSSH server is not installed"
            return
        fi
        if pkg_install "$(pkg_name sshd)" && find_sshd
        then
            ok "installed OpenSSH server"
        else
            bad "could not install the OpenSSH server"
            return
        fi
    fi

    # Debian-family sshd -T refuses to run without its runtime dir, which only
    # exists while sshd runs. Create it (in check mode just for this run).
    if [[ -f /etc/debian_version && ! -d /run/sshd ]]
    then
        mkdir -m 0755 /run/sshd && (( CHECK_ONLY )) && RMDIR_ON_EXIT=/run/sshd
    fi

    if (( ! CHECK_ONLY ))
    then
        compgen -G '/etc/ssh/ssh_host_*_key' >/dev/null || { run ssh-keygen -A && ok "generated SSH host keys"; }
        unlock "$SSHD_CONFIG"

        # Evaluate the config as it would be WITHOUT our block, so the block only
        # ever holds what is actually needed and re-runs never stack copies.
        strip_block "$SSHD_CONFIG" > "$base"
        if ! sshd_eval "$base"
        then
            bad "sshd cannot parse its own config, fix that first (nothing changed):"
            note "${SSH_ERR//$base/$SSHD_CONFIG}"
            return
        fi
        ssh_needs
        if (( ${#NEED[@]} ))
        then
            insert_block "$base" > "$cand"
        elif grep -qxF "$MARK_BEGIN" "$SSHD_CONFIG"
        then
            cp "$base" "$cand"
        else
            cp "$SSHD_CONFIG" "$cand"
        fi

        if [[ $(cksum < "$cand") != $(cksum < "$SSHD_CONFIG") ]]
        then
            if ! "$SSHD" -t -f "$cand" 2> "$TMPD/sshd.err"
            then
                bad "the new sshd_config failed 'sshd -t', nothing changed:"
                note "$(head -n 3 "$TMPD/sshd.err")"
                return
            fi
            backup "$SSHD_CONFIG"
            cat "$cand" > "$SSHD_CONFIG"
            # Belt and braces: never leave sshd with a config it can't load
            if ! "$SSHD" -t 2> "$TMPD/sshd.err"
            then
                cat "$BACKUP_LAST" > "$SSHD_CONFIG"
                bad "sshd -t failed after the edit, original config restored"
                return
            fi
            for line in "${NEED[@]}"
            do
                ok "sshd_config: 'Match User $ANSIBLE_USER' -> $line"
            done
            (( ${#NEED[@]} )) || ok "sshd_config: removed the stage0 block, no longer needed"
            sshd_service reload && ok "reloaded sshd (existing sessions keep running)"
        fi
        sshd_service ensure
    fi

    # Verify against the live file, whatever we did or didn't change
    if ! sshd_eval "$SSHD_CONFIG"
    then
        bad "sshd cannot parse $SSHD_CONFIG:"
        note "$SSH_ERR"
        return
    fi
    ssh_needs
    if (( ${#NEED[@]} == 0 ))
    then
        ok "sshd lets '$ANSIBLE_USER' log in with a password on tcp/$SSH_PORT (checked with sshd -T)"
    else
        for line in "${NEED[@]}"
        do
            bad "for '$ANSIBLE_USER' sshd still needs: $line"
        done
        (( CHECK_ONLY )) || note "something earlier overrides us (an Include'd Match block?), inspect with: sshd -T -C user=$ANSIBLE_USER,host=x,addr=1.2.3.4"
    fi
    [[ -n $SSH_DENIED ]] && bad "'$ANSIBLE_USER' is blocked by $SSH_DENIED in the sshd config, remove that by hand"
    case $(sshd_listening) in
        yes) ok "sshd is listening on tcp/$SSH_PORT" ;;
        no)  bad "nothing is listening on tcp/$SSH_PORT" ;;
    esac
}


# -------------------------------------------------------------- firewall ----

do_firewall() {
    local port=${SSH_PORT:-22} rules
    step "Host firewall"
    FW_STATE=ok FW_NOTE="no active host firewall"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
    then
        FW_NOTE="ufw allows tcp/$port"
        if ufw status | grep -qE "^(${port}(/tcp)?|OpenSSH)[[:space:]]+ALLOW"
        then
            ok "$FW_NOTE"
        elif (( ! CHECK_ONLY )) && run ufw allow "$port/tcp"
        then
            ok "ufw: opened tcp/$port"
        else
            FW_STATE=bad FW_NOTE="ufw blocks tcp/$port"
            bad "$FW_NOTE"
        fi
        return
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && [[ $(firewall-cmd --state 2>/dev/null) == running ]]
    then
        FW_NOTE="firewalld allows tcp/$port"
        if firewall-cmd -q --query-port="$port/tcp" || { [[ $port == 22 ]] && firewall-cmd -q --query-service=ssh; }
        then
            ok "$FW_NOTE"
        elif (( ! CHECK_ONLY )) && run firewall-cmd --add-port="$port/tcp" && run firewall-cmd --permanent --add-port="$port/tcp"
        then
            ok "firewalld: opened tcp/$port (runtime + permanent)"
        else
            FW_STATE=bad FW_NOTE="firewalld blocks tcp/$port"
            bad "$FW_NOTE"
        fi
        return
    fi

    # Raw iptables/nftables belong to the team's firewall scripts: warn, don't touch
    if command -v iptables >/dev/null 2>&1
    then
        rules=$(iptables -S INPUT 2>/dev/null)
        if grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)' <<< "$rules"
        then
            if grep -E -- '-j ACCEPT' <<< "$rules" | grep -qE -- "--dports? ([0-9:,]*,)?$port([,:][0-9:,]*)?( |\$)"
            then
                FW_NOTE="iptables accepts tcp/$port"
                ok "$FW_NOTE"
            else
                FW_STATE=warn FW_NOTE="iptables INPUT drops traffic, no ACCEPT for tcp/$port seen"
                warn "$FW_NOTE"
                note "if the controller can't connect: iptables -I INPUT -p tcp --dport $port -j ACCEPT"
            fi
            return
        fi
    fi
    if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qE 'hook input.*policy drop'
    then
        FW_STATE=warn FW_NOTE="nftables input policy is drop, make sure tcp/$port is allowed"
        warn "$FW_NOTE"
        return
    fi
    ok "$FW_NOTE"
}


# ---------------------------------------------------------------- report ----

next_steps() {
    local host yhost addrs ips first others port_opt="" k
    host=$(short_host)
    # Quote anything that isn't a plain hostname so it can't break the YAML
    yhost=$host
    [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || yhost="'${host//\'/\'\'}'"
    addrs=$(ip -4 -o addr show scope global 2>/dev/null)
    ips=$(awk '{ sub(/\/.*/, "", $4); print $4 }' <<< "$addrs")
    [[ -n $ips ]] || ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$')
    # Last resort on minimal boxes with neither: the kernel's own routing table
    [[ -n $ips ]] || ips=$(awk '/32 host/ { print f } { f = $2 }' /proc/net/fib_trie 2>/dev/null | grep -v '^127\.' | sort -u)
    first=$(head -n 1 <<< "$ips")
    others=$(tail -n +2 <<< "$ips" | tr '\n' ' ')
    [[ ${SSH_PORT:-22} != 22 ]] && port_opt=" ansible_port=$SSH_PORT"

    # No colors or prefixes on the YAML itself, so it copies out of the terminal cleanly.
    # This is a generic host entry; the controller operator chooses the role
    # group in inventory.yml.
    printf '\n%sInventory entry (YAML)%s paste into inventory.yml under:\n' "$c_bold" "$c_reset"
    printf '  all > children > managed_endpoints > linux > children > <role> > hosts:\n\n'
    printf '            %s:\n' "$yhost"
    printf '              ansible_host: %s\n' "${first:-<ip>}"
    printf '              ansible_user: %s\n' "$ANSIBLE_USER"
    [[ -n $PY ]] && printf '              ansible_python_interpreter: %s\n' "$PY"
    [[ ${SSH_PORT:-22} != 22 ]] && printf '              ansible_port: %s\n' "$SSH_PORT"
    printf '\n'
    [[ -n $others ]] && note "other addresses on this box: $others"
    if [[ -n $first ]] && awk -v ip="$first" '{ a = $4; sub(/\/.*/, "", a) } a == ip && / dynamic / { f = 1 } END { exit !f }' <<< "$addrs"
    then
        warn "$first came from DHCP and may change, re-check it before running playbooks"
    fi

    printf '\n%sTest from the controller%s (needs sshpass; -k ssh password, -K sudo password)\n' "$c_bold" "$c_reset"
    printf "  before adding it:  ansible all -i '%s,' -u %s -k -K -b -m ping%s\n" "${first:-<ip>}" "$ANSIBLE_USER" \
        "${port_opt:+ -e$port_opt}"
    printf '  after adding it:   ansible %s -i inventory.yml -k -K -b -m ping\n' "$host"

    if compgen -G '/etc/ssh/ssh_host_*_key.pub' >/dev/null && command -v ssh-keygen >/dev/null 2>&1
    then
        printf '\n%sHost key fingerprints%s (check these on first connect)\n' "$c_bold" "$c_reset"
        for k in /etc/ssh/ssh_host_*_key.pub
        do
            ssh-keygen -lf "$k" 2>/dev/null | awk '{ printf "  %-10s %s\n", $NF, $2 }'
        done
    fi
}

report() {
    FAILS=0
    printf '\n%sReady for Ansible?%s\n' "$c_bold" "$c_reset"

    if find_python && [[ $PY_VER == 3.* ]]
    then
        if ver_ge "$PY_VER" 3.7; then row ok Python "$PY $PY_VER"; else row warn Python "$PY $PY_VER (old)"; fi
    else
        row bad Python "python3 missing"
    fi

    if ! id "$ANSIBLE_USER" >/dev/null 2>&1
    then
        row bad User "'$ANSIBLE_USER' does not exist"
    elif password_usable && [[ -z $(account_issues) ]]
    then
        row ok User "$ANSIBLE_USER, password set, account active"
    else
        row bad User "$ANSIBLE_USER exists but cannot log in"
    fi

    sudo_eval
    if (( ! SUDO_FULL ))
    then
        row bad sudo "no full sudo"
    elif sudo_passwordless
    then
        row bad sudo "works but is passwordless"
    elif [[ -n $SUDO_DEFAULTS ]]
    then
        row bad sudo "Defaults $SUDO_DEFAULTS breaks become"
    else
        row ok sudo "ALL commands, password required"
    fi

    if find_sshd && sshd_eval "$SSHD_CONFIG" && ssh_needs && (( ${#NEED[@]} == 0 )) && [[ -z $SSH_DENIED ]]
    then
        row ok SSH "password auth for $ANSIBLE_USER on tcp/$SSH_PORT"
    else
        row bad SSH "password auth for $ANSIBLE_USER not allowed"
    fi

    case $(sshd_listening) in
        yes) row ok Listening "sshd on tcp/${SSH_PORT:-22}" ;;
        no)  row bad Listening "nothing on tcp/${SSH_PORT:-22}" ;;
        *)   row warn Listening "unknown (/proc/net/tcp unreadable)" ;;
    esac
    row "${FW_STATE:-ok}" Firewall "${FW_NOTE:-not checked}"

    if (( FAILS == 0 ))
    then
        next_steps
        printf '\n%s%s Stage 0 done, this box is ready for Ansible.%s\n' "$c_ok" "$i_ok" "$c_reset"
    else
        printf '\n%s%s %d check(s) failed.%s Fix the items above and re-run, it is safe to repeat.\n' \
            "$c_err" "$i_err" "$FAILS" "$c_reset"
    fi
    if (( ! CHECK_ONLY ))
    then
        note "log: $LOG"
        [[ -d $BACKUP_DIR ]] && note "backups: $BACKUP_DIR"
    fi
    (( FAILS == 0 ))
}


# ------------------------------------------------------------------ main ----

main() {
    while [[ $# -gt 0 ]]
    do
        case $1 in
            -c|--check) CHECK_ONLY=1; shift ;;
            -u|--user)  [[ -n $2 ]] || die "$1 needs a username"; ANSIBLE_USER=$2; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; echo >&2; die "unknown option: $1" ;;
        esac
    done
    [[ $ANSIBLE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: $ANSIBLE_USER"
    [[ $(id -u) -eq 0 ]] || die "must be run as root (sudo $0)"

    TMPD=$(mktemp -d) || die "mktemp failed"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    if (( CHECK_ONLY ))
    then
        LOG=/dev/null
    else
        # Read prompts from the terminal, not stdin, so "curl ... | sudo bash" works
        ( : <> /dev/tty ) 2>/dev/null || die "no terminal for the password prompt (use ssh -t, or run it directly)"
        exec 3<> /dev/tty
        { : >> "$LOG" && chmod 600 "$LOG"; } 2>/dev/null || LOG=/dev/null
        log "==== stager.sh start, user=$ANSIBLE_USER ===="
    fi

    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && . /etc/os-release
    detect_pkg

    printf '\n%sCCDC stage 0%s: Ansible bootstrap%s\n' "$c_bold" "$c_reset" "$( (( CHECK_ONLY )) && echo " (check only, no changes)")"
    printf '%s  host %s  |  %s  |  pkg %s  |  user %s%s\n' "$c_dim" "$(short_host)" "${PRETTY_NAME:-unknown OS}" \
        "${PKG:-none}" "$ANSIBLE_USER" "$c_reset"

    do_python
    do_user
    do_sudo
    do_ssh
    do_firewall
    report
}

main "$@"
