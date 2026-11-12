#requires -Version 5.1
#requires -RunAsAdministrator

<##
.SYNOPSIS
    Stage a Windows Server 2019/Windows 10 or newer host for Ansible over PSRP.

.DESCRIPTION
    The password is collected as a SecureString from the console. It is not a
    parameter, so it cannot appear in command history, process arguments, or
    this script's output. The first run prompts for a password when the account
    is absent. Later runs preserve the existing password unless
    -ResetPassword is explicitly supplied.

    Run from an elevated 64-bit Windows PowerShell 5.1 prompt:

      powershell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1
      powershell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1 -ResetPassword
      powershell.exe -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Check

    Member servers and Windows clients receive a local administrator named
    ansible. A domain controller receives an account in the current domain and
    adds it to the built-in Administrators group. PSRP uses the default WinRM
    HTTP listener on TCP 5985 with NTLM; PSRP message encryption remains on.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9._-]{0,31}$')]
    [string]$UserName = 'ansible',

    [ValidateRange(8, 128)]
    [int]$MinimumPasswordLength = 8,

    [switch]$Check,

    [switch]$ResetPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'FAIL')]
        [string]$State,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $color = switch ($State) {
        'OK' { 'Green' }
        'INFO' { 'Cyan' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
    }
    Write-Host ("[{0}] {1}" -f $State, $Message) -ForegroundColor $color
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Read-AnsiblePassword {
    param([Parameter(Mandatory)][int]$MinimumLength)

    while ($true) {
        $first = Read-Host -Prompt 'New password for the Ansible user' -AsSecureString
        $second = Read-Host -Prompt 'Retype password' -AsSecureString
        $firstText = $null
        $secondText = $null
        $accepted = $false

        try {
            if ($first.Length -lt $MinimumLength) {
                Write-Status WARN "Password must be at least $MinimumLength characters."
                continue
            }

            $firstText = Convert-SecureStringToPlainText -SecureString $first
            $secondText = Convert-SecureStringToPlainText -SecureString $second
            if ($firstText -ne $secondText) {
                Write-Status WARN 'Passwords did not match; try again.'
                continue
            }

            $accepted = $true
            return $first
        }
        finally {
            $firstText = $null
            $secondText = $null
            $second.Dispose()
            if (-not $accepted) { $first.Dispose() }
        }
    }
}

function Get-LocalAdministratorsGroupName {
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $account = $adminSid.Translate([System.Security.Principal.NTAccount]).Value
    return ($account -split '\\', 2)[1]
}

function Test-SidMembership {
    param(
        [AllowEmptyCollection()][object[]]$Members,
        [Parameter(Mandatory)][string]$Sid
    )

    foreach ($member in @($Members)) {
        if ($null -ne $member -and $null -ne $member.SID -and $member.SID.Value -eq $Sid) {
            return $true
        }
    }
    return $false
}

function Get-LocalAccountTokenFilterPolicy {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $key = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }

    $property = $key.PSObject.Properties['LocalAccountTokenFilterPolicy']
    if ($null -eq $property) { return $null }
    return [int]$property.Value
}

function Test-HttpWinRmListener {
    $output = (& winrm.cmd enumerate winrm/config/listener 2>&1 | Out-String)
    return $output -match '(?im)^\s*Transport\s*=\s*HTTP\s*$'
}

function Ensure-WinRmAndPsrp {
    Write-Status INFO 'Enabling PowerShell remoting and the WinRM service.'
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service -Name WinRM -StartupType Automatic
    if ((Get-Service -Name WinRM).Status -ne 'Running') {
        Start-Service -Name WinRM
    }

    if (-not (Test-HttpWinRmListener)) {
        Write-Status INFO 'Creating the default HTTP WinRM listener.'
        & winrm.cmd quickconfig -quiet | Out-Null
    }
    if (-not (Test-HttpWinRmListener)) {
        throw 'WinRM HTTP listener was not found after remoting configuration.'
    }

    $endpoint = Get-PSSessionConfiguration -Name Microsoft.PowerShell -ErrorAction SilentlyContinue
    if ($null -eq $endpoint) {
        throw 'The Microsoft.PowerShell PSRP session endpoint is not available.'
    }

    $ruleName = 'CCDC-WinRM-HTTP-In-TCP'
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule -Name $ruleName `
            -DisplayName 'CCDC Ansible PSRP - WinRM HTTP' `
            -Direction Inbound -Protocol TCP -LocalPort 5985 `
            -Action Allow -Profile Any | Out-Null
    }
    else {
        Set-NetFirewallRule -Name $ruleName -Enabled True -Action Allow -Profile Any
    }
}

function Ensure-LocalAccount {
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [AllowNull()][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$AdministratorsGroup
    )

    Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    $user = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        if ($null -eq $Password) {
            throw "Local user '$AccountName' does not exist and no password was supplied."
        }
        New-LocalUser -Name $AccountName `
            -Password $Password `
            -Description 'CCDC Ansible automation account' `
            -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Write-Status OK "Created local user '$AccountName'."
    }
    else {
        if ($null -ne $Password) {
            Set-LocalUser -Name $AccountName -Password $Password -PasswordNeverExpires
            Write-Status OK "Updated the password for local user '$AccountName'."
        }
        else {
            Set-LocalUser -Name $AccountName -PasswordNeverExpires
        }
        Enable-LocalUser -Name $AccountName
        Write-Status OK "Verified and enabled local user '$AccountName'."
    }

    $user = Get-LocalUser -Name $AccountName
    $members = @(Get-LocalGroupMember -Group $AdministratorsGroup -ErrorAction SilentlyContinue)
    if (-not (Test-SidMembership -Members $members -Sid $user.SID.Value)) {
        Add-LocalGroupMember -Group $AdministratorsGroup -Member $AccountName
        Write-Status OK "Added '$AccountName' to '$AdministratorsGroup'."
    }
    else {
        Write-Status OK "'$AccountName' is already in '$AdministratorsGroup'."
    }

    [pscustomobject]@{
        DomainController = $false
        AdministratorsGroup = $AdministratorsGroup
    }
}

function Ensure-DomainAccount {
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [AllowNull()][Security.SecureString]$Password
    )

    Import-Module ActiveDirectory -ErrorAction Stop
    $domain = Get-ADDomain
    $user = Get-ADUser -Identity $AccountName -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        if ($null -eq $Password) {
            throw "Domain user '$AccountName' does not exist and no password was supplied."
        }
        New-ADUser -Name $AccountName `
            -SamAccountName $AccountName `
            -Path $domain.UsersContainer `
            -AccountPassword $Password `
            -Enabled $true `
            -PasswordNeverExpires $true | Out-Null
        Write-Status OK "Created domain user '$AccountName'."
    }
    else {
        if ($null -ne $Password) {
            Set-ADAccountPassword -Identity $user -Reset -NewPassword $Password
            Write-Status OK "Updated the password for domain user '$AccountName'."
        }
        Set-ADUser -Identity $user -Enabled $true -PasswordNeverExpires $true
        Write-Status OK "Verified and enabled domain user '$AccountName'."
    }

    $user = Get-ADUser -Identity $AccountName
    # RID 544 is the built-in Administrators group, independent of OS locale.
    $administrators = Get-ADGroup -Identity ($domain.DomainSID.Value + '-544')
    $members = @(Get-ADGroupMember -Identity $administrators -Recursive -ErrorAction SilentlyContinue)
    if (-not (Test-SidMembership -Members $members -Sid $user.SID.Value)) {
        Add-ADGroupMember -Identity $administrators -Members $user
        Write-Status OK "Added '$AccountName' to the built-in Administrators group."
    }
    else {
        Write-Status OK "'$AccountName' is already in the built-in Administrators group."
    }

    [pscustomobject]@{
        DomainController = $true
        AdministratorsGroup = $administrators.Name
    }
}

function Get-Readiness {
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][bool]$DomainController,
        [Parameter(Mandatory)][string]$AdministratorsGroup
    )

    $failures = 0
    if ($DomainController) {
        $user = Get-ADUser -Identity $AccountName -Properties Enabled -ErrorAction SilentlyContinue
        if ($null -eq $user -or -not $user.Enabled) {
            Write-Status FAIL "Domain user '$AccountName' is missing or disabled."
            $failures++
        }
        else {
            Write-Status OK "Domain user '$AccountName' exists and is enabled."
        }

        $domain = Get-ADDomain
        $admin = Get-ADGroup -Identity ($domain.DomainSID.Value + '-544')
        $members = @(Get-ADGroupMember -Identity $admin -Recursive -ErrorAction SilentlyContinue)
        if ($null -ne $user -and (Test-SidMembership -Members $members -Sid $user.SID.Value)) {
            Write-Status OK "'$AccountName' is in the built-in Administrators group."
        }
        else {
            Write-Status FAIL "'$AccountName' is not in the built-in Administrators group."
            $failures++
        }
    }
    else {
        $user = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
        if ($null -eq $user -or -not $user.Enabled) {
            Write-Status FAIL "Local user '$AccountName' is missing or disabled."
            $failures++
        }
        else {
            Write-Status OK "Local user '$AccountName' exists and is enabled."
        }

        if ($null -ne $user) {
            $members = @(Get-LocalGroupMember -Group $AdministratorsGroup -ErrorAction SilentlyContinue)
            if (Test-SidMembership -Members $members -Sid $user.SID.Value) {
                Write-Status OK "'$AccountName' is a member of '$AdministratorsGroup'."
            }
            else {
                Write-Status FAIL "'$AccountName' is not a member of '$AdministratorsGroup'."
                $failures++
            }
        }
    }

    $winrm = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($null -ne $winrm -and $winrm.Status -eq 'Running') {
        Write-Status OK 'WinRM service is running.'
    }
    else {
        Write-Status FAIL 'WinRM service is not running.'
        $failures++
    }

    if (Test-HttpWinRmListener) {
        Write-Status OK 'WinRM HTTP listener is available on TCP 5985.'
    }
    else {
        Write-Status FAIL 'WinRM HTTP listener is not available on TCP 5985.'
        $failures++
    }

    $endpoint = Get-PSSessionConfiguration -Name Microsoft.PowerShell -ErrorAction SilentlyContinue
    if ($null -ne $endpoint) {
        Write-Status OK 'Microsoft.PowerShell PSRP endpoint is available.'
    }
    else {
        Write-Status FAIL 'Microsoft.PowerShell PSRP endpoint is missing.'
        $failures++
    }

    $rule = Get-NetFirewallRule -Name 'CCDC-WinRM-HTTP-In-TCP' -ErrorAction SilentlyContinue
    if ($null -ne $rule -and [bool]$rule.Enabled -and $rule.Action -eq 'Allow') {
        Write-Status OK 'CCDC PSRP firewall rule is enabled.'
    }
    else {
        Write-Status FAIL 'CCDC PSRP firewall rule is missing or disabled.'
        $failures++
    }

    if (-not $DomainController) {
        $tokenFilter = Get-LocalAccountTokenFilterPolicy
        if ($tokenFilter -eq 1) {
            Write-Status OK 'Local administrator remote token filtering is disabled for PSRP management.'
        }
        else {
            Write-Status FAIL 'LocalAccountTokenFilterPolicy is not set to 1.'
            $failures++
        }
    }
    else {
        Write-Status INFO 'Domain controller detected; local-account token filtering is not applicable.'
    }

    return $failures
}

$password = $null
try {
    if (-not [Environment]::Is64BitProcess) {
        throw 'Run this script from 64-bit Windows PowerShell, not SysWOW64 PowerShell.'
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    if ($build -lt 10240) {
        throw "Unsupported Windows build $build. Windows 10/Server 2019 or newer is required."
    }

    $isDomainController = ([int]$os.ProductType -eq 2)
    if ($isDomainController) {
        Import-Module ActiveDirectory -ErrorAction Stop
        $administratorsGroup = 'Administrators'
    }
    else {
        Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
        $administratorsGroup = Get-LocalAdministratorsGroupName
    }

    Write-Host ''
    Write-Status INFO ("Windows bootstrap for {0} ({1}, build {2})" -f $os.CSName, $os.Caption, $build)
    Write-Status INFO ("Target account: {0} ({1})" -f $UserName, $(if ($isDomainController) { 'domain' } else { 'local' }))

    if (-not $Check) {
        if ($isDomainController) {
            $accountExists = $null -ne (Get-ADUser -Identity $UserName -ErrorAction SilentlyContinue)
        }
        else {
            $accountExists = $null -ne (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)
        }

        $needsPassword = (-not $accountExists) -or $ResetPassword
        if ($needsPassword) {
            if ($accountExists) {
                Write-Status INFO "-ResetPassword supplied; accepting a replacement password for '$UserName'."
            }
            else {
                Write-Status INFO "Account '$UserName' does not exist; accepting its initial password."
            }
            $password = Read-AnsiblePassword -MinimumLength $MinimumPasswordLength
        }
        else {
            Write-Status OK "Account '$UserName' already exists; preserving its password. Use -ResetPassword to rotate it."
        }

        if ($isDomainController) {
            $context = Ensure-DomainAccount -AccountName $UserName -Password $password
        }
        else {
            $context = Ensure-LocalAccount -AccountName $UserName -Password $password -AdministratorsGroup $administratorsGroup
            $lsaPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            $currentTokenFilter = Get-LocalAccountTokenFilterPolicy
            if ($currentTokenFilter -ne 1) {
                New-ItemProperty -Path $lsaPath -Name LocalAccountTokenFilterPolicy -PropertyType DWord -Value 1 -Force | Out-Null
                Write-Status OK 'Enabled full remote administrative tokens for the local Ansible account.'
            }
            else {
                Write-Status OK 'Remote administrative token policy is already correct.'
            }
        }

        Ensure-WinRmAndPsrp
    }
    else {
        Write-Status INFO 'Check-only mode: no account, registry, service, or firewall changes will be made.'
        $context = [pscustomobject]@{
            DomainController = $isDomainController
            AdministratorsGroup = $administratorsGroup
        }
    }

    if ($isDomainController) {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    else {
        Import-Module Microsoft.PowerShell.LocalAccounts -ErrorAction Stop
    }

    Write-Host ''
    Write-Status INFO 'Readiness report'
    $failureCount = Get-Readiness `
        -AccountName $UserName `
        -DomainController $context.DomainController `
        -AdministratorsGroup $context.AdministratorsGroup

    if ($failureCount -eq 0) {
        Write-Host ''
        Write-Status OK 'Windows host is ready for Ansible PSRP.'
        exit 0
    }

    Write-Host ''
    Write-Status FAIL "$failureCount readiness check(s) failed."
    exit 1
}
catch {
    Write-Status FAIL $_.Exception.Message
    exit 1
}
finally {
    if ($null -ne $password) {
        $password.Dispose()
        $password = $null
    }
}
