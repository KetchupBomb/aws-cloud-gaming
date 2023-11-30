<powershell>

function Set-LoginScript ($taskname, $action) {
    $trigger = New-ScheduledTaskTrigger -AtLogon -RandomDelay $(New-TimeSpan -seconds 30)
    $trigger.Delay = "PT30S"
    if (-not ($action -is [array])) { $action = @($action) }
    $action += New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-WindowStyle Hidden -Command `"Disable-ScheduledTask -TaskName $taskname`""
    Register-ScheduledTask -TaskName $taskname -Trigger $trigger -Action $action -RunLevel Highest
}

function Install-Chocolatey {
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
}

function Invoke-ParsecCloudPreparationScript {
    # https://github.com/parsec-cloud/Parsec-Cloud-Preparation-Tool.git
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $downloadPath = "C:\Parsec-Cloud-Preparation-Tool.zip"
    $extractPath = "C:\Parsec-Cloud-Preparation-Tool"
    $repoPath = Join-Path $extractPath "Parsec-Cloud-Preparation-Tool-master"
    $copyPath = Join-Path $desktopPath "ParsecTemp"
    $scriptEntrypoint = Join-Path $repoPath "PostInstall\PostInstall.ps1"

    if (!(Test-Path -Path $extractPath)) {
        [Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"
        (New-Object System.Net.WebClient).DownloadFile("https://github.com/parsec-cloud/Parsec-Cloud-Preparation-Tool/archive/master.zip", $downloadPath)
        New-Item -Path $extractPath -ItemType Directory
        Expand-Archive $downloadPath -DestinationPath $extractPath
        Remove-Item $downloadPath

        New-Item -Path $copyPath -ItemType Directory
        Copy-Item $repoPath/* $copyPath -Recurse -Container

        # https://github.com/parsec-cloud/Parsec-Cloud-Preparation-Tool/issues/102
        (Get-Content $scriptEntrypoint -Raw) -replace '\\vigem\\10\\x64\\', '\\vdd\\' | Set-Content $scriptEntrypoint

        # Setup scheduled task to run Parsec-Cloud-Preparation-Tool once at logon
        $actions = @()
        $actions += New-ScheduledTaskAction -Execute 'Powershell.exe' -WorkingDirectory $repoPath -Argument ('-Command "{0} -DontPromptPasswordUpdateGPU"' -f $scriptEntrypoint)
        $actions += New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument "-WindowStyle Hidden -Command `"Disable-ScheduledTask -TaskName 'Setup Team Machine'`""
        Set-LoginScript "Parsec-Cloud-Preparation-Tool" $actions
    }
}

function Set-AdminPassword {
    $password = (Get-SSMParameter -WithDecryption $true -Name '${password_ssm_parameter}').Value
    net user Administrator "$password"
}

function Set-AutoLogin {
    Install-Module -Name DSCR_AutoLogon -Force
    Import-Module -Name DSCR_AutoLogon
    $password = (Get-SSMParameter -WithDecryption $true -Name '${password_ssm_parameter}').Value
    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    [microsoft.win32.registry]::SetValue($regPath, "AutoAdminLogon", "1")
    [microsoft.win32.registry]::SetValue($regPath, "DefaultUserName", "Administrator")
    Remove-ItemProperty -Path $regPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    (New-Object PInvoke.LSAUtil.LSAutil -ArgumentList "DefaultPassword").SetSecret($password)
}

function Install-GpuDriver() {
    function Get-Driver() {
        param(
            $Bucket,
            $KeyPrefix,
            $ExtractionPath
        )
        $Objects = Get-S3Object -BucketName $Bucket -KeyPrefix $KeyPrefix -Region us-east-1
        foreach ($Object in $Objects) {
            $LocalFileName = $Object.Key
            if ($LocalFileName -ne '' -and $Object.Size -ne 0) {
                $LocalFilePath = Join-Path $ExtractionPath $LocalFileName
                Copy-S3Object -BucketName $Bucket -Key $Object.Key -LocalFile $LocalFilePath -Region us-east-1

                if ($LocalFileName -like "*.zip") {
                    Expand-Archive -Path $LocalFilePath -DestinationPath $ExtractionPath
                    return
                }
            }
        }
    }
    if (Test-Path -Path "C:\Program Files\NVIDIA Corporation\NVSMI") {
        return
    }
    [string]$ExtractionPath = "C:\nvidia-driver\driver"
    [string]$InstallerFilter = "*win10*"
    %{ if regex("^g[0-9]+", var.instance_type) == "g3" }
    Get-Driver -bucket "ec2-windows-nvidia-drivers" -KeyPrefix "latest" -ExtractionPath $ExtractionPath
    # disable licencing page in control panel
    New-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\GridLicensing" -Name "NvCplDisableManageLicensePage" -PropertyType "DWord" -Value "1"
    %{ else }
    %{ if regex("^g[0-9]+", var.instance_type) == "g4" }
    Get-Driver -bucket "nvidia-gaming" -KeyPrefix "windows/latest" -ExtractionPath $ExtractionPath
    # install licence
    Copy-S3Object -BucketName "nvidia-gaming" -Key "GridSwCert-Archive/GridSwCert-Windows_2020_04.cert" -LocalFile "C:\Users\Public\Documents\GridSwCert.txt" -Region us-east-1
    [microsoft.win32.registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\NVIDIA Corporation\Global", "vGamingMarketplace", 0x02)
    %{ endif }
    %{ endif }

    if (Test-Path -Path $ExtractionPath) {
        # install driver
        $InstallerFile = Get-ChildItem -path $ExtractionPath -Include $InstallerFilter -Recurse | ForEach-Object { $_.FullName }
        Start-Process -FilePath $InstallerFile -ArgumentList "/s /n" -Wait

        # install task to disable second monitor on login
        $trigger = New-ScheduledTaskTrigger -AtLogon
        $action = New-ScheduledTaskAction -Execute displayswitch.exe -Argument "/internal"
        Register-ScheduledTask -TaskName "disable-second-monitor" -Trigger $trigger -Action $action -RunLevel Highest
    }
    else {
        $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-WindowStyle Hidden -Command `"(New-Object -ComObject Wscript.Shell).Popup('Automatic GPU driver installation is unsupported for this instance type: ${var.instance_type}. Please install them manually.')`""
        Set-LoginScript "gpu-driver-warning" $action
    }
}

Install-Chocolatey
Install-PackageProvider -Name NuGet -Force
choco install awstools.powershell
Set-AdminPassword

%{ if var.install_parsec }
Invoke-ParsecCloudPreparationScript
%{ endif }

%{ if var.install_auto_login }
Set-AutoLogin
%{ endif }

%{ if var.install_graphic_card_driver }
Install-GpuDriver
%{ endif }

%{  for package in var.choco_packages ~}
choco install ${package} -y
%{ endfor ~}

</powershell>
