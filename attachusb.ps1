# Check if we have Admin right to bind and attach usb
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Configuration
$deviceNames = @("USB Serial Device")
$attachedBusIds = @()

try {
    $usbList = usbipd list

    # Grep the device that needs to be bind and attach
    foreach ($name in $deviceNames) {
        $match = $usbList | Select-String -Pattern $name
        if ($match) {
            foreach ($line in $match) {
                if ($line -match '^(\s*)(\d+-\d+)\s+') {
                    $busid = $matches[2].Trim()

                    if ($attachedBusIds -contains $busid) { continue }

                    Write-Host "Found $name at $busid. Binding and Attaching..."

                    usbipd bind --busid $busid --force
                    usbipd attach --wsl --busid $busid

                    $attachedBusIds += $busid
                }
            }
        }
    }

    # Launch WSL
    if ($attachedBusIds.Count -gt 0) {

        # Create background watcher to clean up on exit
        $busIdsString = $attachedBusIds -join ','
        $deviceNamesString = $deviceNames -join ','

        $watcherCode = "
            Wait-Process -Id $PID

            # BUSID cleanup
            `$busIds = '$busIdsString' -split ','
            foreach (`$b in `$busIds) {
                if (`$b) {
                    usbipd detach --busid `$b 2>`$null
                    usbipd unbind --busid `$b 2>`$null
                }
            }

            # GUID Cleanup
            `$devNames = '$deviceNamesString' -split ','
            `$usbList = usbipd list
            `$inPersisted = `$false
            foreach (`$line in `$usbList) {
                if (`$line -match '^Persisted:') { `$inPersisted = `$true; continue }
                if (`$inPersisted -and `$line -match '^([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\s+(.*)$') {
                    `$guid = `$matches[1]
                    `$devName = `$matches[2]
                    foreach (`$name in `$devNames) {
                        if (`$name -and `$devName -match `$name) {
                            usbipd unbind --guid `$guid 2>`$null
                        }
                    }
                }
            }
        "

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($watcherCode)
        $encodedCommand = [Convert]::ToBase64String($bytes)

        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

        Write-Host "`nAll devices attached. Launching WSL..."
        wsl --cd ~
    } else {
        Write-Host "No devices were found to attach."
    }
}
finally {
    Write-Host "`nExiting. Running cleanup..."

    # Clean up known BUSID
    if ($attachedBusIds.Count -gt 0) {
        foreach ($busid in $attachedBusIds) {
            usbipd detach --busid $busid 2>$null
            usbipd unbind --busid $busid 2>$null
            Write-Host "Released BusID: $busid"
        }
    }

    # Clean up any Persisted GUID
    $postUsbList = usbipd list
    $inPersisted = $false
    foreach ($line in $postUsbList) {
        if ($line -match '^Persisted:') {
            $inPersisted = $true
            continue
        }
        # Regex parse standard GUID format followed by device name
        if ($inPersisted -and $line -match '^([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\s+(.*)$') {
            $guid = $matches[1]
            $devName = $matches[2]

            foreach ($name in $deviceNames) {
                if ($devName -match $name) {
                    Write-Host "Found orphaned device ($name). Unbinding GUID: $guid"
                    usbipd unbind --guid $guid 2>$null
                }
            }
        }
    }

    Write-Host "`nDone."
}
