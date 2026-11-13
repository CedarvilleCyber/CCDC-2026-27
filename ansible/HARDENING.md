# Ansible hardening reference

This reference describes the controls performed by the common role on Linux and Windows managed endpoints. The playbook applies them in ordered phases while allowing all hosts to progress concurrently.

## Execution order

[site.yml](./site.yml) runs:

1. Fact discovery for every host in managed_endpoints.
2. Critical controls: package updates, management access, firewall rules, banners, and rollback copies.
3. Operating-system hardening: permissions, authentication, logging, service cleanup, protocol hardening, and optional controls.
4. Service-aware work: preserving scored services and applying optional application hardening.

The plays use strategy free and the controller uses 50 forks. A host's tasks remain ordered, but one slow host does not serialize the others.

## Linux hardening

Linux controls are implemented in [linux_critical.yml](./roles/common/tasks/linux_critical.yml), [linux_hardening.yml](./roles/common/tasks/linux_hardening.yml), and [linux_services.yml](./roles/common/tasks/linux_services.yml).

### Critical controls

#### Rollback copies

When linux_create_backups is enabled, the role creates /var/backups/ccdc-ansible with mode 0700. It copies existing versions of these files before modification, without replacing an existing backup:

- /etc/ssh/sshd_config
- /etc/sudoers
- /etc/hosts
- /etc/passwd
- /etc/shadow

Backups are owned by root with mode 0600.

#### Package updates and prerequisites

When linux_upgrade_packages is enabled:

- Debian systems refresh APT metadata, perform a dist upgrade, autoremove packages, and autoclean.
- Red Hat systems update installed packages with DNF using update_only.

All Linux hosts ensure these packages are present:

- sudo
- openssh-server
- chrony
- auditd
- rsyslog

The role verifies that the staged ansible account exists.

#### Host firewall

Debian systems install UFW. UFW is temporarily enabled with an allow policy so the existing SSH connection survives while explicit rules are installed. Role TCP and UDP ports are allowed, then the final inbound policy is deny with low logging. Outbound traffic remains allowed.

Red Hat systems install and start firewalld. Role TCP and UDP ports are permanently and immediately allowed in the public zone.

Role port lists are defined in [group_vars/linux.yml](./group_vars/linux.yml), [group_vars/ecomm.yml](./group_vars/ecomm.yml), [group_vars/email.yml](./group_vars/email.yml), [group_vars/splunk.yml](./group_vars/splunk.yml), [group_vars/wkst.yml](./group_vars/wkst.yml), and [group_vars/kali.yml](./group_vars/kali.yml).

#### Login banners

The authorized-use banner is written to:

- /etc/issue
- /etc/issue.net
- /etc/ssh/sshd-banner

The text is controlled by ccdc_banner in [group_vars/all/main.yml](./group_vars/all/main.yml). The tasks also have a safe fallback banner if the variable is unavailable.

#### SSH hardening

A validated managed block is inserted at the beginning of /etc/ssh/sshd_config:

- PasswordAuthentication yes, retaining password access for Ansible.
- PermitEmptyPasswords no.
- PermitRootLogin no.
- PubkeyAuthentication yes.
- X11Forwarding no.
- MaxAuthTries 4.
- LoginGraceTime 30.
- Banner /etc/ssh/sshd-banner.

The proposed configuration is validated with sshd -t before installation. A handler reloads SSH, and the critical phase flushes that handler before continuing.

### Operating-system hardening

#### Sensitive file permissions

The role attempts to enforce:

| File | Owner | Group | Mode |
| --- | --- | --- | --- |
| /etc/passwd | root | root | 0644 |
| /etc/shadow | root | shadow | 0640 |
| /etc/sudoers | root | root | 0440 |

These tasks use failed_when: false so an unsupported platform detail does not stop the complete run.

#### Environment injection cleanup

The role removes global exports for LD_PRELOAD, LD_LIBRARY_PATH, http_proxy, https_proxy, HTTP_PROXY, and HTTPS_PROXY from /etc/profile and /etc/environment, keeping backups of changed files.

#### Unnecessary services

When present, these units are stopped, disabled, and masked:

- avahi-daemon.service
- bluetooth.service
- cups.service
- ModemManager.service
- rpcbind.service
- rpcbind.socket
- rexec.socket
- rlogin.socket
- rsh.socket
- telnet.socket

The workstation group narrows this list. The Kali group sets it empty.

#### Automatic updates and timers

When linux_disable_unattended_upgrades is true, unattended-upgrades is stopped and disabled, and unattended-upgrades.timer is masked when present.

Additional timers are only disabled when linux_disable_timers is true:

- dnf-makecache.timer
- unattended-upgrades.timer
- phpsessionclean.timer

#### Audit and system logging

When installed, auditd and rsyslog are started and enabled. Audit changes can trigger an auditd restart handler.

#### Time synchronization

If linux_ntp_servers is nonempty and the configured chrony file exists, a managed block adds each source as:

    server ADDRESS iburst

Chrony is restarted after a change and enabled when installed. The playbook does not guess a private competition NTP server.

#### SUID and SGID cleanup

The role searches /usr/bin, /usr/sbin, /bin, and /sbin for these named files and removes SUID/SGID bits when present:

- bash
- chown
- curl
- find
- nmap
- perl
- php
- python
- ruby
- wget

The task reports a change only when a special permission bit is removed.

#### Optional interactive-account locking

When linux_lock_unlisted_accounts is true, accounts with UID 1000 or higher and interactive shells are locked except root, ansible, and sysadmin. This option is false by default because competition injects may require additional accounts.

### Service-aware Linux work

The role gathers service facts and starts/enables only already-installed services listed for the role:

- Ecomm: apache2 and httpd.
- Email: postfix, dovecot, and apache2.
- Splunk: Splunkd and splunk.

Missing optional services do not fail the task.

If linux_php_ini_files contains paths, PHP disable_functions is set to block exec, shell_exec, system, passthru, popen, proc_open, pcntl_exec, pcntl_fork, curl_exec, phpinfo, mail, mb_send_mail, and dl. Configured role services are restarted afterward.

## Windows hardening

Windows controls are implemented in [windows_critical.yml](./roles/common/tasks/windows_critical.yml), [windows_hardening.yml](./roles/common/tasks/windows_hardening.yml), and [windows_services.yml](./roles/common/tasks/windows_services.yml).

### Critical controls

#### Firewall rollback

The role creates C:\CCDC-Backup and exports the current Windows Firewall policy to C:\CCDC-Backup\firewall-before.wfw when that export does not already exist.

#### Firewall baseline

Domain, Private, and Public profiles are enabled with:

- Inbound default: Block.
- Outbound default: Allow.
- Allowed and blocked connection logging enabled.
- Log path: C:\Windows\System32\LogFiles\Firewall\pfirewall.log.
- Maximum log size: 8192 KB by default.

The role permits:

- PSRP/WinRM TCP 5985.
- Role-specific scored TCP ports.
- Role-specific scored UDP ports.

Ports are defined in [group_vars/ad.yml](./group_vars/ad.yml), [group_vars/mssql.yml](./group_vars/mssql.yml), and [group_vars/win_wkst.yml](./group_vars/win_wkst.yml).

#### Outbound LOLBin blocks

Explicit outbound TCP block rules are created for:

- C:\Windows\System32\notepad.exe
- C:\Windows\System32\regsvr32.exe
- C:\Windows\System32\calc.exe
- C:\Windows\System32\mshta.exe
- C:\Windows\System32\wscript.exe
- C:\Windows\System32\cscript.exe
- C:\Windows\System32\hh.exe

Normal outbound traffic remains allowed.

### Operating-system hardening

#### SMBv1 removal

SMBv1 feature variants are disabled when present. The legacy mrxsmb10 driver start value is set to 4.

#### Password policy

The role applies this net accounts baseline:

- Minimum password length: 8.
- Maximum password age: 30 days.
- Minimum password age: 1 day.
- Password history: 3 passwords.
- Forced logoff: 30 minutes.

Values are controlled by windows_password_* variables in [group_vars/windows.yml](./group_vars/windows.yml).

#### Authentication, SMB, and RPC registry controls

The role sets these DWORD values:

- LmCompatibilityLevel = 5.
- NoLMHash = 1.
- RestrictAnonymous = 1.
- RestrictAnonymousSAM = 1.
- EveryoneIncludesAnonymous = 0.
- LimitBlankPasswordUse = 1.
- LSA\MSV1_0\allownullsessionfallback = 0.
- LanmanWorkstation\Parameters\EnablePlainTextPassword = 0.
- LanmanWorkstation\Parameters\EnableSecuritySignature = 1.
- LanmanWorkstation\Parameters\AllowInsecureGuestAuth = 0.
- LanmanServer\Parameters\RequireSecuritySignature = 1.
- LanmanServer\Parameters\SMB1 = 0.
- LanmanServer\Parameters\RestrictNullSessAccess = 1.
- Policies\System\LocalAccountTokenFilterPolicy = 1, preserving full remote administrative tokens for the local Ansible account.
- Netlogon\Parameters\RequireSignOrSeal = 1.
- LDAP\LDAPClientIntegrity = 1.
- Rpc\RestrictRemoteClients = 1.
- Policies\System\ConsentPromptBehaviorAdmin = 2.

#### Legacy tunnels

Teredo, 6to4, and ISATAP are disabled using netsh.

#### Guest account

The built-in Guest account is disabled.

#### Interactive logon notice

legalnoticecaption and legalnoticetext are written under:

    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System

#### Microsoft Defender

When windows_enable_defender is enabled and Set-MpPreference exists, real-time monitoring, IOAV protection, and script scanning are enabled.

#### RDP

RDP is disabled only when windows_disable_rdp is true. It is false by default to avoid interrupting a workstation or scored service without an explicit role decision.

#### Windows auditing

Success and failure auditing is enabled for:

- Logon
- Logoff
- Account Lockout
- User Account Management
- Security Group Management
- Process Creation
- Audit Policy Change
- System Integrity

### Service-aware Windows work

When present, these services are stopped and disabled:

- TlntSvr
- RemoteRegistry
- SSDPSRV
- upnphost
- Fax
- WerSvc
- DiagTrack
- MapsBroker
- lfsvc

The role checks for each service before changing it. It finishes by ensuring WinRM is running and configured for automatic startup.

## Variables and limits

The primary inputs are:

- group_vars/all/vault.yml, generated by [stager.sh](./stager.sh), containing vault_ansible_password.
- [host_vars/win11-wkst.yml](./host_vars/win11-wkst.yml), where the DHCP address must be entered manually.
- [group_vars/all/main.yml](./group_vars/all/main.yml), for ccdc_banner and optional linux_ntp_servers.
- [group_vars/ecomm.yml](./group_vars/ecomm.yml), for optional PHP paths.
- [group_vars/windows.yml](./group_vars/windows.yml), for PSRP, Windows policy, and firewall defaults.
- [customization.yml.example](./group_vars/customization.yml.example), for copyable overrides.

The role does not manage the Palo Alto firewall or VyOS router. Those devices are listed in inventory for topology reference but are outside managed_endpoints.

The Linux role configures UFW or firewalld and does not flush raw iptables rules. The Windows role keeps outbound traffic allowed and adds explicit high-risk program blocks instead of applying a blanket outbound deny policy.

