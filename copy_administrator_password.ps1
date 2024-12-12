#!/usr/bin/env pwsh

[string] $password = ((terraform output instance_password) | Out-String).Trim().Trim('"')
Set-Clipboard -Value "$password"
Start-Sleep -Seconds 30
Set-Clipboard -Value "password removed"
