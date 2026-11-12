# CCDC Ansible automation

This directory automates the 2026 Midwest Invitational CCDC Team 1 topology
from [`2026MWCCDCITeamPack.pdf`](../2026MWCCDCITeamPack.pdf) and consolidates
the repeatable portions of the legacy Linux and Windows scripts.

The playbook is intentionally split into three phases:

1. package/management access, SSH or PSRP access, and host firewall rules;
2. audit logging, banners, service cleanup, authentication policy, SMBv1, and
   selected SUID/SGID cleanup;
3. role-aware service preservation and optional PHP hardening.

The inventory targets the eight Linux/Windows endpoints and lists the packet's
Palo Alto firewall and VyOS router under `network_appliances` for topology
reference. Those appliances are not in `managed_endpoints`: the legacy
firewall scripts use appliance-specific/API credentials and even target
Firepower FDM endpoints in places. Their Ansible connection method and
credential vault entries must be confirmed before adding a network-device role.

Each play targets all managed endpoints together. `ansible.cfg` uses 50 forks
and the `free` strategy, so one slow host does not serialize the rest. A host
still executes its own tasks in the order shown above.

## One-time setup

Run [`stager.sh`](stager.sh) on the Ubuntu controller first. It installs the
controller prerequisites, creates an isolated Python environment with current
Ansible and `pypsrp`, installs the collections from
[`requirements.yml`](requirements.yml), and creates the encrypted
`group_vars/all/vault.yml` containing `vault_ansible_password`. The remote
password and the vault encryption password are entered without echo and never
appear in command arguments. Use `--update-vault` only when rotating the
stored remote password; use `--check` for an audit-only run.

```bash
bash ./stager.sh
source .venv/bin/activate
which ansible-playbook
ansible-playbook --version
```

Alternatively, use `bash ./stager.sh --shell` to have the stager activate the
venv and open a nested interactive shell automatically. Type `exit` to return
to the original shell.

The stager does not replace Ubuntu's system `/usr/bin/python3`. It selects
Python 3.11, 3.12, or 3.13 for the controller virtual environment and installs
a compatible Ansible release there. Always activate `.venv` or invoke
`.venv/bin/ansible-playbook`; otherwise Ubuntu's older system Ansible may be
used.

The Linux systems must first be prepared with
[`linux/stager.sh`](../linux/stager.sh). It creates the `ansible` user, Python,
password-required sudo, and SSH password access. The Windows systems already
have an `ansible` account and PSRP over NTLM on TCP 5985 reachable from the
Ubuntu workstation. To prepare or repair a Windows host, run
[`windows/bootstrap.ps1`](../windows/bootstrap.ps1) from an elevated 64-bit
Windows PowerShell 5.1 prompt. It prompts for the password as a SecureString;
the password is never a script parameter. Use `-Check` for an audit-only run.
On the 2022 AD domain controller it creates a domain account; on other hosts it
creates or updates a local account. Install the controller dependency with
`python3 -m pip install pypsrp`. The packet's initial Windows credentials are
not copied into this repository.

The bootstrap is safe to rerun: existing passwords are preserved, group
membership and PSRP configuration are repaired if needed, and no password
prompt appears unless the account is missing. Use `-ResetPassword` when a
password rotation is intentional.

Replace `REPLACE_WITH_WINDOWS_11_WKST_DHCP_IP` in
[`host_vars/win11-wkst.yml`](host_vars/win11-wkst.yml) after DHCP assigns that
workstation before running the playbook. Ansible does not inspect, resolve, or
skip the placeholder automatically.

## Variables to review

The stager creates the required encrypted
[`group_vars/all/vault.yml`](group_vars/all/vault.yml) containing
`vault_ansible_password`. The remaining user-editable values are:

- `host_vars/win11-wkst.yml`: replace the DHCP placeholder in `ansible_host`.
- `group_vars/all.yml`: customize `ccdc_banner` if needed and set
  `linux_ntp_servers` if the competition supplies a private NTP source.
- `group_vars/windows.yml`: change PSRP protocol, authentication, or port only
  if the Windows listener is configured differently from HTTP/NTLM/5985.
- `group_vars/ecomm.yml`: populate `linux_php_ini_files` if PHP hardening should
  be applied to known PHP configuration files.
- [`group_vars/customization.yml.example`](group_vars/customization.yml.example):
  optional copyable placeholders for those overrides.

## Run

From this directory on the Ubuntu workstation:

```bash
ansible-inventory --graph
ansible managed_endpoints -m ping --ask-vault-pass
ansible-playbook site.yml --ask-vault-pass
```

If the team changes the supplied NTP service, set `linux_ntp_servers` in
[`group_vars/all.yml`](group_vars/all.yml) or a more-specific group/host vars
file. The playbook does not invent a private NTP address.

The playbook keeps public/scored service ports open per role, preserves the
current service configuration, and does not flush existing raw iptables rules.
Review any competition inject before enabling optional account locking,
additional timer removal, or more restrictive firewall policy.
