#!/usr/bin/env pwsh
[string] $ip = ((terraform output instance_ip) | Out-String).Trim().Trim('"')
$user = "$ip\Administrator"
@"
full address:s:$ip
username:s:$user
"@ | Out-File -Encoding ASCII  -FilePath "aws-cloud-gaming.rdp"
Invoke-Item "aws-cloud-gaming.rdp"
.\copy_administrator_password.ps1
