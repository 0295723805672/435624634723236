$host.UI.RawUI.WindowTitle = "USBIMODOFF MADE BY @fynn718"

$GLOBAL_INTERVAL = 0x0
$GLOBAL_COUNTER  = 0x0

$INDIVIDUAL_INTERVALS = @{}
$INDIVIDUAL_COUNTERS  = @{}

$RWE_PATH = "C:\Program Files\RwPortableX64V1.7\Win64\Portable\Rw.exe"

function GetValueFromAddress($address) {
    $addressHex = "0x{0:X}" -f $address
    $stdout = & $RWE_PATH /Min /NoLogo /Stdout /Command="R32 $addressHex" | Out-String
    $split_string = $stdout -split " "
    return [uint32]$split_string[-1]
}

function WriteValueToAddress($address, $value) {
    $addressHex = "0x{0:X}" -f $address
    $valueHex = ("0x{0:X8}" -f $value)
    & $RWE_PATH /Min /NoLogo /Stdout /Command="W32 $addressHex $valueHex" | Out-Null
    return $value
}

function Is-Admin() {
    $current_principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $current_principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function main {
    if (-not (Is-Admin)) {
        Write-Host "error: administrator privileges required"
        return 1
    }

    if (-not (Test-Path $RWE_PATH -PathType Leaf)) {
        Write-Host "error: invalid RWEverything path"
        return 1
    }

    Stop-Process -Name "Rw" -ErrorAction SilentlyContinue

    $device_map = @{}
    foreach ($i in Get-CimInstance Win32_PNPAllocatedResource) {
        $device_ID = $i.Dependent.DeviceID
        $physical_address = $i.Antecedent.StartingAddress
        if ($device_ID -and $physical_address) {
            $device_map[$device_ID] = $physical_address
        }
    }

    foreach ($xhci_controller in Get-WmiObject Win32_USBController) {
        $device_ID = $xhci_controller.DeviceID
        if (-not $device_map.Contains($device_ID)) { continue }

        Write-Host "=== Tuning xHCI IMOD Registers ==="

        $capability_address = $device_map[$device_ID]
        $HCSPARAMS_value = GetValueFromAddress($capability_address + 0x4)
        $HCSPARAMS_bitmask = [Convert]::ToString($HCSPARAMS_value, 2).PadLeft(32, '0')
        $max_intrs = [Convert]::ToInt32($HCSPARAMS_bitmask.Substring($HCSPARAMS_bitmask.Length - 16, 8), 2)

        $RTSOFF_value = GetValueFromAddress($capability_address + 0x18)
        $runtime_address = $capability_address + $RTSOFF_value

        $desired_interval = $GLOBAL_INTERVAL
        $desired_counter  = $GLOBAL_COUNTER

        foreach ($hwid in $INDIVIDUAL_INTERVALS.Keys) {
            if ($device_ID -match $hwid) { $desired_interval = $INDIVIDUAL_INTERVALS[$hwid] }
        }
        foreach ($hwid in $INDIVIDUAL_COUNTERS.Keys) {
            if ($device_ID -match $hwid) { $desired_counter = $INDIVIDUAL_COUNTERS[$hwid] }
        }

        $imod_value = ($desired_counter -shl 16) -bor ($desired_interval -band 0xFFFF)

        for ($i = 0; $i -lt $max_intrs; $i++) {
            $imod_address = $runtime_address + 0x24 + (0x20 * $i)
            
            $current_val = GetValueFromAddress($imod_address)
            $curr_interval = $current_val -band 0xFFFF
            $curr_counter  = ($current_val -shr 16) -band 0xFFFF
            
            Write-Host ("IMOD Found at: 0x{0:X8} with value 0x{1:X4} (Interval: {2}, Counter: {3})" -f $imod_address, $current_val, $curr_interval, $curr_counter) -ForegroundColor White
            Write-Host ("IMOD at 0x{0:X8}: 0x{1:X4} -> Setting to 0x{2:X4}" -f $imod_address, $curr_interval, $desired_interval) -ForegroundColor White
            
            $null = WriteValueToAddress $imod_address $imod_value
            
            Write-Host ("SUCCESS: IMOD set to 0x{0:X4}" -f $desired_interval) -ForegroundColor Green
        }
        Write-Host
    }

    return 0
}

exit main