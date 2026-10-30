# TestDeck Probe Agent
# Drive inventory and benchmark agent

param(
    [int]$Port = 8321
)

$ErrorActionPreference = "Stop"

# Global variables
$script:DriveCache = $null
$script:DriveCacheTime = [datetime]::MinValue

# Helper function to escape special characters in strings for JSON
function Escape-JsonString($str) {
    if ($null -eq $str) { return "null" }
    
    $str = [string]$str
    # Escape backslashes first, then other special characters
    $str = $str -replace '\\', '\\\\'
    $str = $str -replace '"', '\"'
    $str = $str -replace "`n", '\n'
    $str = $str -replace "`r", '\r'
    $str = $str -replace "`t", '\t'
    # Remove other control characters (ASCII 0-31 except those already handled)
    $str = $str -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    
    return "`"$str`""
}

# Convert object to JSON safely (handles hashtables correctly in PS 5.1)
function ConvertTo-SafeJson($obj) {
    if ($null -eq $obj) { return "null" }
    
    # Handle ArrayList
    if ($obj -is [System.Collections.ArrayList]) {
        $items = @()
        foreach ($item in $obj) {
            $items += (ConvertTo-SafeJson $item)
        }
        return "[" + ($items -join ",") + "]"
    }
    
    # Handle Array
    if ($obj -is [array]) {
        $items = @()
        foreach ($item in $obj) {
            $items += (ConvertTo-SafeJson $item)
        }
        return "[" + ($items -join ",") + "]"
    }
    
    # Handle Hashtable
    if ($obj -is [hashtable]) {
        $pairs = @()
        foreach ($key in $obj.Keys) {
            $value = $obj[$key]
            $escapedKey = Escape-JsonString $key
            $escapedValue = ConvertTo-SafeJson $value
            $pairs += "$escapedKey`:$escapedValue"
        }
        return "{" + ($pairs -join ",") + "}"
    }
    
    # Handle PSCustomObject
    if ($obj -is [PSCustomObject]) {
        $pairs = @()
        foreach ($prop in $obj.PSObject.Properties) {
            $key = $prop.Name
            $value = $prop.Value
            $escapedKey = Escape-JsonString $key
            $escapedValue = ConvertTo-SafeJson $value
            $pairs += "$escapedKey`:$escapedValue"
        }
        return "{" + ($pairs -join ",") + "}"
    }
    
    # Handle primitive types
    if ($obj -is [string]) {
        return Escape-JsonString $obj
    }
    
    if ($obj -is [bool]) {
        return $obj.ToString().ToLower()
    }
    
    if ($obj -is [int] -or $obj -is [long] -or $obj -is [double] -or $obj -is [float] -or $obj -is [decimal]) {
        return $obj.ToString()
    }
    
    # Fallback: convert to string
    return Escape-JsonString $obj.ToString()
}

# Get drive inventory
function Get-DriveInventory {
    Write-Host "[INVENTORY] Starting drive inventory scan..." -ForegroundColor Cyan
    
    # Check cache (2 second TTL)
    if ($null -ne $script:DriveCache -and ((Get-Date) - $script:DriveCacheTime).TotalSeconds -lt 2) {
        Write-Host "[INVENTORY] Using cached data" -ForegroundColor Gray
        return $script:DriveCache
    }
    
    $results = New-Object System.Collections.ArrayList
    
    Write-Host "[INVENTORY] Calling Get-Disk..." -ForegroundColor Gray
    try {
        $disks = Get-Disk -ErrorAction SilentlyContinue
        Write-Host "[INVENTORY] Get-Disk returned $($disks.Count) disk(s)" -ForegroundColor Green
    } catch {
        Write-Host "[INVENTORY] ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return ,$results
    }
    
    foreach ($disk in $disks) {
        Write-Host "[INVENTORY] Processing disk #$($disk.Number): $($disk.FriendlyName)" -ForegroundColor Cyan
        
        $info = @{
            diskNumber = $disk.Number
            model = $disk.FriendlyName
            serial = $disk.SerialNumber
            firmware = $disk.FirmwareVersion
            capacityGB = [math]::Round($disk.Size / 1GB, 2)
            bus = $disk.BusType
            media = $disk.MediaType
            healthStatus = $disk.HealthStatus
            operationalStatus = $disk.OperationalStatus
            letters = @()
            wear = $null
            tempC = $null
            readErrors = $null
            writeErrors = $null
            relOk = $false
            relErr = ""
            letSrc = ""
            fwSrc = ""
        }
        
        # Get drive letters
        try {
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
            foreach ($part in $partitions) {
                if ($part.DriveLetter) {
                    $info.letters += $part.DriveLetter
                }
            }
            $info.letSrc = "Storage"
        } catch {
            $info.letSrc = "none"
        }
        
        # Get reliability counter (may require elevation)
        try {
            $relCounter = Get-StorageReliabilityCounter -Disk $disk -ErrorAction Stop
            $info.wear = $relCounter.Wear
            $info.tempC = $relCounter.Temperature
            $info.readErrors = $relCounter.ReadErrorsTotal
            $info.writeErrors = $relCounter.WriteErrorsTotal
            $info.relOk = $true
        } catch {
            $info.relOk = $false
            $info.relErr = "Requires elevation: $($_.Exception.Message)"
        }
        
        Write-Host "[INVENTORY] Added drive: $($info.model) | Bus: $($info.bus) | Media: $($info.media) | Letters: $($info.letters -join ',')" -ForegroundColor Green
        [void]$results.Add($info)
    }
    
    Write-Host "[INVENTORY] Total drives found: $($results.Count)" -ForegroundColor Green
    $script:DriveCache = $results
    $script:DriveCacheTime = Get-Date
    return ,$results
}

# HTTP server
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "TestDeck Probe running on http://127.0.0.1:$Port" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        
        # Read request
        $requestLine = $reader.ReadLine()
        $parts = $requestLine -split " "
        $method = $parts[0]
        $path = $parts[1]
        
        # Read headers
        $headers = @{}
        while ($true) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            $colonIdx = $line.IndexOf(":")
            if ($colonIdx -gt 0) {
                $key = $line.Substring(0, $colonIdx).Trim()
                $value = $line.Substring($colonIdx + 1).Trim()
                $headers[$key] = $value
            }
        }
        
        # Read body if present
        $body = ""
        if ($headers.ContainsKey("Content-Length")) {
            $contentLen = [int]$headers["Content-Length"]
            if ($contentLen -gt 0) {
                $bodyBuf = New-Object char[] $contentLen
                $reader.Read($bodyBuf, 0, $contentLen) | Out-Null
                $body = New-Object string($bodyBuf)
            }
        }
        
        Write-Host "[API] $method $path" -ForegroundColor Cyan
        
        # Route handling
        $responseBody = ""
        $statusCode = 200
        
        try {
            if ($path -eq "/ping" -and $method -eq "GET") {
                $responseBody = ConvertTo-SafeJson @{ status = "ok"; time = (Get-Date -Format "o") }
            }
            elseif ($path -eq "/drives" -and $method -eq "GET") {
                Write-Host "[API] /drives request received" -ForegroundColor Cyan
                $drives = Get-DriveInventory
                Write-Host "[API] Returning $($drives.Count) drive(s)" -ForegroundColor Green
                $responseBody = ConvertTo-SafeJson $drives
            }
            elseif ($path -eq "/bench/seq" -and $method -eq "POST") {
                $data = $body | ConvertFrom-Json
                Write-Host "[BENCH-SEQ] Running SEQ benchmark on drive $($data.drive)" -ForegroundColor Cyan
                # Simulate benchmark result (replace with actual benchmark code)
                $result = @{ readMbps = 425.3; writeMbps = 412.8 }
                Write-Host "[BENCH-SEQ] Result: readMbps=$($result.readMbps), writeMbps=$($result.writeMbps)" -ForegroundColor Green
                $responseBody = ConvertTo-SafeJson $result
            }
            else {
                $statusCode = 404
                $responseBody = ConvertTo-SafeJson @{ error = "Not found" }
            }
        } catch {
            $statusCode = 500
            $responseBody = ConvertTo-SafeJson @{ error = $_.Exception.Message }
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
        
        # Send response
        $response = "HTTP/1.1 $statusCode OK`r`n"
        $response += "Content-Type: application/json`r`n"
        $response += "Content-Length: $($responseBody.Length)`r`n"
        $response += "Access-Control-Allow-Origin: *`r`n"
        $response += "Connection: close`r`n"
        $response += "`r`n"
        $response += $responseBody
        
        $writer.Write($response)
        $writer.Flush()
        
        $client.Close()
    }
} finally {
    $listener.Stop()
}
