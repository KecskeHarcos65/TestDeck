# TestDeck Server - PowerShell 5.1 compatible HTTP server
# Raw TcpListener + manual HTTP/1.1 parsing (no admin required)
param(
    [int]$Port = 8080,
    [int]$TlsPort = 8443,
    [switch]$NoTls,
    [string]$CertFile = "",
    [string]$CertPass = ""
)

$ErrorActionPreference = "Continue"
$script:DataDir = Join-Path $PSScriptRoot "data"
if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

# --- PS 5.1 Safe JSON Helpers ---
function Read-JsonList($path) {
    Write-Host "[JSON-READ] Reading file: $path" -ForegroundColor Gray
    if (-not (Test-Path $path)) {
        Write-Host "[JSON-READ] File does not exist, returning empty ArrayList" -ForegroundColor Yellow
        $emptyList = New-Object System.Collections.ArrayList
        return ,$emptyList  # Comma prevents unwrapping
    }
    $raw = Get-Content $path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "[JSON-READ] File is empty, returning empty ArrayList" -ForegroundColor Yellow
        $emptyList = New-Object System.Collections.ArrayList
        return ,$emptyList  # Comma prevents unwrapping
    }
    Write-Host "[JSON-READ] File content length: $($raw.Length) chars" -ForegroundColor Gray
    try {
        $parsed = $raw | ConvertFrom-Json
        Write-Host "[JSON-READ] JSON parsed successfully" -ForegroundColor Gray

        # Always return ArrayList, even if parsed is a single object
        $list = New-Object System.Collections.ArrayList

        if ($parsed -is [System.Array]) {
            Write-Host "[JSON-READ] Parsed as array with $($parsed.Length) items" -ForegroundColor Gray
            foreach ($item in $parsed) {
                [void]$list.Add($item)
            }
        } elseif ($null -ne $parsed) {
            Write-Host "[JSON-READ] Parsed as single object, wrapping in ArrayList" -ForegroundColor Gray
            [void]$list.Add($parsed)
        }

        Write-Host "[JSON-READ] Returning ArrayList with $($list.Count) items" -ForegroundColor Green
        return ,$list  # Comma prevents unwrapping
    } catch {
        Write-Host "[JSON-READ] ERROR parsing JSON: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[JSON-READ] Returning empty ArrayList" -ForegroundColor Yellow
        $emptyList = New-Object System.Collections.ArrayList
        return ,$emptyList  # Comma prevents unwrapping
    }
}

function Write-JsonList($path, $list) {
    Write-Host "[JSON-WRITE] Writing to file: $path" -ForegroundColor Gray
    Write-Host "[JSON-WRITE] List type: $($list.GetType().Name)" -ForegroundColor Gray
    Write-Host "[JSON-WRITE] List count: $($list.Count)" -ForegroundColor Gray

    try {
        # Convert ArrayList to array for proper JSON serialization
        $items = @()
        foreach ($item in $list) {
            $items += $item
        }

        Write-Host "[JSON-WRITE] Items array count: $($items.Count)" -ForegroundColor Gray

        if ($items.Count -eq 0) {
            $json = "[]"
        } else {
            # Always wrap in array brackets for consistent JSON format
            $jsonParts = @()
            foreach ($item in $items) {
                $jsonParts += ($item | ConvertTo-Json -Depth 20 -Compress)
            }
            $json = "[" + ($jsonParts -join ",") + "]"
        }

        Write-Host "[JSON-WRITE] JSON length: $($json.Length) chars" -ForegroundColor Gray

        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-Host "[JSON-WRITE] WARNING: JSON is null/empty, using '[]'" -ForegroundColor Yellow
            $json = "[]"
        }

        [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        Write-Host "[JSON-WRITE] File written successfully" -ForegroundColor Green
    } catch {
        Write-Host "[JSON-WRITE] ERROR: $_" -ForegroundColor Red
        Write-Host "[JSON-WRITE] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
        throw
    }
}

function Get-Mutex($name) {
    return New-Object System.Threading.Mutex($false, $name)
}

# --- Crypto ---
function New-PasswordHash($password) {
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($salt)
    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($password, $salt, 60000)
    $hash = $pbkdf2.GetBytes(32)
    $combined = New-Object byte[] ($salt.Length + $hash.Length)
    [Array]::Copy($salt, 0, $combined, 0, $salt.Length)
    [Array]::Copy($hash, 0, $combined, $salt.Length, $hash.Length)
    return [Convert]::ToBase64String($combined)
}

function Test-PasswordHash($password, $stored) {
    # Explicit type conversion to handle PSCustomObject properties
    $storedString = [string]$stored
    $passwordString = [string]$password

    Write-Host "[PASSWORD] Testing password (password length: $($passwordString.Length), hash length: $($storedString.Length))" -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($storedString)) {
        Write-Host "[PASSWORD] WARNING: stored hash is null or empty after conversion" -ForegroundColor Yellow
        return $false
    }

    try {
        Write-Host "[PASSWORD] Decoding base64 hash..." -ForegroundColor Gray
        $combined = [Convert]::FromBase64String($storedString)
        Write-Host "[PASSWORD] Decoded hash length: $($combined.Length) bytes" -ForegroundColor Gray

        Write-Host "[PASSWORD] Extracting salt (16 bytes)..." -ForegroundColor Gray
        $salt = New-Object byte[] 16
        [Array]::Copy($combined, 0, $salt, 0, 16)

        Write-Host "[PASSWORD] Creating PBKDF2 with 60000 iterations..." -ForegroundColor Gray
        $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($passwordString, $salt, 60000)

        Write-Host "[PASSWORD] Generating 32-byte hash..." -ForegroundColor Gray
        $hash = $pbkdf2.GetBytes(32)

        Write-Host "[PASSWORD] Comparing hashes..." -ForegroundColor Gray
        for ($i = 0; $i -lt 32; $i++) {
            if ($combined[16 + $i] -ne $hash[$i]) {
                Write-Host "[PASSWORD] Hash mismatch at position $i" -ForegroundColor Yellow
                return $false
            }
        }

        Write-Host "[PASSWORD] Hash match successful!" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[PASSWORD] ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[PASSWORD] Exception type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
        Write-Host "[PASSWORD] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
        return $false
    }
}

function New-SessionToken() {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

function New-RandomPassword($length = 12) {
    $chars = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$"
    $bytes = New-Object byte[] $length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $pwd = ""
    foreach ($b in $bytes) { $pwd += $chars[$b % $chars.Length] }
    return $pwd
}

# --- Data Files ---
$script:UsersFile = Join-Path $script:DataDir "users.json"
$script:SessionsFile = Join-Path $script:DataDir "sessions.json"
$script:DrivesFile = Join-Path $script:DataDir "drives.json"
$script:ProfilesFile = Join-Path $script:DataDir "profiles.json"
$script:LabelsFile = Join-Path $script:DataDir "labels.json"
$script:ModelsFile = Join-Path $script:DataDir "models.json"
$script:LifecycleFile = Join-Path $script:DataDir "lifecycle.json"

# --- Seed Data ---
function Initialize-Data {
    if (-not (Test-Path $script:UsersFile)) {
        $adminPwd = New-RandomPassword
        $users = [System.Collections.ArrayList]@()
        [void]$users.Add(@{
            name = "admin"
            role = "admin"
            passwordHash = (New-PasswordHash $adminPwd)
            createdAt = (Get-Date -Format "o")
        })
        Write-JsonList $script:UsersFile $users
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host "  TESTDECK FIRST RUN - Admin Credentials" -ForegroundColor Yellow
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host "  Username: admin" -ForegroundColor Cyan
        Write-Host "  Password: $adminPwd" -ForegroundColor Green
        Write-Host "============================================" -ForegroundColor Yellow
        Write-Host "  SAVE THIS PASSWORD! It is not stored in plaintext." -ForegroundColor Red
        Write-Host ""
    }
    if (-not (Test-Path $script:SessionsFile)) { Write-JsonList $script:SessionsFile ([System.Collections.ArrayList]@()) }
    if (-not (Test-Path $script:DrivesFile)) { Write-JsonList $script:DrivesFile ([System.Collections.ArrayList]@()) }
    if (-not (Test-Path $script:LifecycleFile)) { Write-JsonList $script:LifecycleFile ([System.Collections.ArrayList]@()) }

    if (-not (Test-Path $script:ProfilesFile)) {
        $profiles = [System.Collections.ArrayList]@(
            @{ id="prof-sata"; name="Generic SATA SSD"; matchSubstring=""; bus="SATA"; media="SSD"; minSeqR=500; minSeqW=450; min4kR=25; min4kW=60; tolerancePct=15; ratedTBW=0 },
            @{ id="prof-nvme"; name="Generic NVMe SSD"; matchSubstring=""; bus="NVMe"; media="SSD"; minSeqR=2000; minSeqW=1500; min4kR=50; min4kW=100; tolerancePct=15; ratedTBW=0 },
            @{ id="prof-usb"; name="USB External SSD"; matchSubstring=""; bus="USB"; media="SSD"; minSeqR=400; minSeqW=350; min4kR=15; min4kW=30; tolerancePct=20; ratedTBW=0 },
            @{ id="prof-samsung970"; name="Samsung 970 EVO"; matchSubstring="970 EVO"; bus="NVMe"; media="SSD"; minSeqR=3400; minSeqW=2500; min4kR=60; min4kW=120; tolerancePct=12; ratedTBW=600 }
        )
        Write-JsonList $script:ProfilesFile $profiles
    }
    if (-not (Test-Path $script:LabelsFile)) {
        $labels = [System.Collections.ArrayList]@(
            @{ id="lbl-100x25"; name="Standard 100x25"; widthMm=100; heightMm=25 },
            @{ id="lbl-50x25"; name="Small 50x25"; widthMm=50; heightMm=25 },
            @{ id="lbl-75x25"; name="Medium 75x25"; widthMm=75; heightMm=25 },
            @{ id="lbl-100x50"; name="Large 100x50"; widthMm=100; heightMm=50 }
        )
        Write-JsonList $script:LabelsFile $labels
    }
    if (-not (Test-Path $script:ModelsFile)) {
        $models = [System.Collections.ArrayList]@(
            @{ id="mod-samsung"; family="Samsung 970/980/990"; manufacturer="Samsung"; matchPattern="Samsung|970|980|990" },
            @{ id="mod-wd"; family="WD Blue/Black/Red"; manufacturer="Western Digital"; matchPattern="WDC|WD " },
            @{ id="mod-crucial"; family="Crucial MX/BX"; manufacturer="Crucial"; matchPattern="Crucial|CT" },
            @{ id="mod-intel"; family="Intel SSD"; manufacturer="Intel"; matchPattern="Intel|INTEL" },
            @{ id="mod-kingston"; family="Kingston A2000/KC3000"; manufacturer="Kingston"; matchPattern="Kingston|KINGSTON" },
            @{ id="mod-seagate"; family="Seagate Barracuda/FireCuda"; manufacturer="Seagate"; matchPattern="Seagate|ST" },
            @{ id="mod-toshiba"; family="Toshiba/Kioxia"; manufacturer="Toshiba"; matchPattern="Toshiba|TOSHIBA|KIOXIA" },
            @{ id="mod-sandisk"; family="SanDisk Ultra/Extreme"; manufacturer="SanDisk"; matchPattern="SanDisk|SANDISK" },
            @{ id="mod-hynix"; family="SK Hynix Gold"; manufacturer="SK Hynix"; matchPattern="Hynix|SK Hynix" },
            @{ id="mod-micron"; family="Micron/Crucial"; manufacturer="Micron"; matchPattern="Micron|MT" },
            @{ id="mod-pny"; family="PNY XLR8"; manufacturer="PNY"; matchPattern="PNY" },
            @{ id="mod-corsair"; family="Corsair Force/MP"; manufacturer="Corsair"; matchPattern="Corsair|CORSAIR" },
            @{ id="mod-adata"; family="ADATA XPG"; manufacturer="ADATA"; matchPattern="ADATA|XPG" },
            @{ id="mod-generic-ssd"; family="Generic SSD"; manufacturer="Other"; matchPattern="" },
            @{ id="mod-generic-hdd"; family="Generic HDD"; manufacturer="Other"; matchPattern="" },
            @{ id="mod-unknown"; family="Unknown"; manufacturer="Unknown"; matchPattern="" }
        )
        Write-JsonList $script:ModelsFile $models
    }
}

# --- Session Management ---
function Get-SessionUser($token) {
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    $sessions = Read-JsonList $script:SessionsFile
    $session = $null
    foreach ($s in $sessions) {
        if ($s.token -eq $token) { $session = $s; break }
    }
    if ($null -eq $session) { return $null }
    $expires = [DateTime]::Parse($session.expiresAt)
    if ($expires -lt (Get-Date)) {
        $sessions.Remove($session) | Out-Null
        Write-JsonList $script:SessionsFile $sessions
        return $null
    }
    $users = Read-JsonList $script:UsersFile
    foreach ($u in $users) {
        if ($u.name -eq $session.username) { return $u }
    }
    return $null
}

function New-Session($username) {
    Write-Host "[SESSION] Creating new session for user: $username" -ForegroundColor Cyan

    $token = New-SessionToken
    Write-Host "[SESSION] Token generated: $($token.Length) chars" -ForegroundColor Gray

    Write-Host "[SESSION] Reading sessions file..." -ForegroundColor Gray
    $sessions = Read-JsonList $script:SessionsFile

    Write-Host "[SESSION] Current sessions count: $($sessions.Count)" -ForegroundColor Gray

    $newSession = @{
        token = $token
        username = $username
        createdAt = (Get-Date -Format "o")
        expiresAt = ((Get-Date).AddHours(12)).ToString("o")
    }

    Write-Host "[SESSION] Adding new session to list..." -ForegroundColor Gray
    [void]$sessions.Add($newSession)

    Write-Host "[SESSION] Writing sessions to file..." -ForegroundColor Gray
    Write-JsonList $script:SessionsFile $sessions

    Write-Host "[SESSION] Session created successfully!" -ForegroundColor Green
    return $token
}

function Remove-Session($token) {
    $sessions = Read-JsonList $script:SessionsFile
    $toRemove = $null
    foreach ($s in $sessions) {
        if ($s.token -eq $token) { $toRemove = $s; break }
    }
    if ($null -ne $toRemove) {
        $sessions.Remove($toRemove) | Out-Null
        Write-JsonList $script:SessionsFile $sessions
    }
}

# --- HTTP Parsing ---
function Parse-HttpRequest($stream) {
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            Write-Host "[PARSE] Empty request line" -ForegroundColor Yellow
            return $null
        }
        Write-Host "[PARSE] Request: $requestLine" -ForegroundColor Cyan
        $parts = $requestLine -split " "
        if ($parts.Count -lt 2) {
            return $null
        }
        $method = $parts[0]
        $fullPath = $parts[1]
        $pathParts = $fullPath -split "\?"
        $path = $pathParts[0]
        $queryString = ""
        if ($pathParts.Count -gt 1) { $queryString = $pathParts[1] }
        $headers = @{}
        while ($true) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            $colonIdx = $line.IndexOf(":")
            if ($colonIdx -gt 0) {
                $key = $line.Substring(0, $colonIdx).Trim()
                $val = $line.Substring($colonIdx + 1).Trim()
                $headers[$key] = $val
            }
        }
        $body = ""
        if ($headers.ContainsKey("Content-Length")) {
            $contentLen = 0
            [int]::TryParse($headers["Content-Length"], [ref]$contentLen) | Out-Null
            Write-Host "[PARSE] Content-Length: $contentLen" -ForegroundColor Cyan
            if ($contentLen -gt 0 -and $contentLen -lt 10485760) {
                $bodyBuf = New-Object char[] $contentLen
                $totalRead = 0
                while ($totalRead -lt $contentLen) {
                    $read = $reader.Read($bodyBuf, $totalRead, $contentLen - $totalRead)
                    Write-Host "[PARSE] Read $read bytes (total: $($totalRead + $read)/$contentLen)" -ForegroundColor Cyan
                    if ($read -eq 0) {
                        Write-Host "[PARSE] WARNING: Read returned 0 before completing" -ForegroundColor Yellow
                        break
                    }
                    $totalRead += $read
                }
                $body = New-Object string($bodyBuf, 0, $totalRead)
                Write-Host "[PARSE] Body read: $totalRead bytes" -ForegroundColor Green
            }
        } else {
            Write-Host "[PARSE] No Content-Length header" -ForegroundColor Yellow
        }
        # Don't dispose reader - it would close the underlying stream!
        return @{ Method=$method; Path=$path; Query=$queryString; Headers=$headers; Body=$body }
    } catch [System.IO.IOException] {
        Write-Host "[PARSE] IOException: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    } catch [System.ObjectDisposedException] {
        Write-Host "[PARSE] ObjectDisposedException: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    } catch [System.Net.Sockets.SocketException] {
        Write-Host "[PARSE] SocketException: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    } catch {
        Write-Host "[PARSE] Unknown error: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Send-HttpResponse($stream, $statusCode, $statusText, $contentType, $bodyBytes) {
    try {
        $header = "HTTP/1.1 $statusCode $statusText`r`n"
        $header += "Content-Type: $contentType`r`n"
        $header += "Content-Length: $($bodyBytes.Length)`r`n"
        $header += "Access-Control-Allow-Origin: *`r`n"
        $header += "Access-Control-Allow-Methods: GET, POST, PATCH, DELETE, OPTIONS`r`n"
        $header += "Access-Control-Allow-Headers: Content-Type, Authorization`r`n"
        $header += "Connection: close`r`n"
        $header += "`r`n"
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
        Write-Host "[SEND] Sending $statusCode response ($($bodyBytes.Length) bytes)" -ForegroundColor Cyan
        $stream.Write($headerBytes, 0, $headerBytes.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()
        Write-Host "[SEND] Response sent successfully" -ForegroundColor Green
    } catch [System.IO.IOException] {
        Write-Host "[SEND] IOException: $($_.Exception.Message)" -ForegroundColor Red
    } catch [System.ObjectDisposedException] {
        Write-Host "[SEND] ObjectDisposedException: $($_.Exception.Message)" -ForegroundColor Red
    } catch [System.Net.Sockets.SocketException] {
        Write-Host "[SEND] SocketException: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function ConvertTo-SafeJson($obj) {
    # Convert hashtable to PSCustomObject to prevent array conversion in PS 5.1
    if ($obj -is [hashtable]) {
        $psObj = New-Object PSObject
        foreach ($key in $obj.Keys) {
            $psObj | Add-Member -MemberType NoteProperty -Name $key -Value $obj[$key]
        }
        return $psObj | ConvertTo-Json -Depth 20 -Compress
    }
    return $obj | ConvertTo-Json -Depth 20 -Compress
}

function Send-Json($stream, $statusCode, $obj) {
    Write-Host "[SEND-JSON] Converting object to JSON..." -ForegroundColor Gray

    # Handle ArrayList explicitly - ConvertTo-Json returns null for empty ArrayLists
    if ($obj -is [System.Collections.ArrayList]) {
        if ($obj.Count -eq 0) {
            Write-Host "[SEND-JSON] Empty ArrayList detected, using '[]'" -ForegroundColor Gray
            $json = "[]"
        } else {
            Write-Host "[SEND-JSON] ArrayList with $($obj.Count) items" -ForegroundColor Gray
            # Convert each item individually using safe conversion
            $jsonParts = @()
            foreach ($item in $obj) {
                $jsonParts += (ConvertTo-SafeJson $item)
            }
            $json = "[" + ($jsonParts -join ",") + "]"
        }
    }
    # Use safe conversion for hashtables and other objects
    else {
        $json = ConvertTo-SafeJson $obj
    }

    # Final null check - use "[]" for empty collections, "{}" for objects
    if ([string]::IsNullOrWhiteSpace($json)) {
        if ($obj -is [System.Collections.ArrayList] -or $obj -is [System.Array]) {
            Write-Host "[SEND-JSON] JSON is null/empty after conversion for collection, using '[]'" -ForegroundColor Yellow
            $json = "[]"
        } else {
            Write-Host "[SEND-JSON] JSON is null/empty after conversion, using '{}'" -ForegroundColor Yellow
            $json = "{}"
        }
    }

    try {
        Write-Host "[SEND-JSON] JSON: $json" -ForegroundColor Gray
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        Send-HttpResponse $stream $statusCode "OK" "application/json" $bytes
    } catch {
        Write-Host "[SEND-JSON] ERROR converting to JSON: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[SEND-JSON] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
        # Fallback: send empty JSON object
        $fallbackBytes = [System.Text.Encoding]::UTF8.GetBytes("{}")
        Send-HttpResponse $stream $statusCode "OK" "application/json" $fallbackBytes
    }
}

function Send-JsonError($stream, $statusCode, $message) {
    $obj = @{ error = $message }
    $json = $obj | ConvertTo-Json -Depth 5 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $statusText = switch ($statusCode) {
        400 { "Bad Request" }
        401 { "Unauthorized" }
        403 { "Forbidden" }
        404 { "Not Found" }
        500 { "Internal Server Error" }
        default { "Error" }
    }
    Send-HttpResponse $stream $statusCode $statusText "application/json" $bytes
}

function Send-File($stream, $filePath, $contentType) {
    Write-Host "[FILE] Attempting to serve: $filePath" -ForegroundColor Cyan
    if (-not (Test-Path $filePath)) {
        Write-Host "[FILE] File not found: $filePath" -ForegroundColor Red
        Send-JsonError $stream 404 "File not found"
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    Write-Host "[FILE] File loaded: $($bytes.Length) bytes" -ForegroundColor Green
    Send-HttpResponse $stream 200 "OK" $contentType $bytes
}

function Get-AuthToken($headers) {
    if ($headers.ContainsKey("Authorization")) {
        $auth = $headers["Authorization"]
        if ($auth.StartsWith("Bearer ")) {
            return $auth.Substring(7)
        }
    }
    return $null
}

# --- Route Handlers ---
function Handle-Request($stream, $request) {
    $method = $request.Method
    $path = $request.Path
    $body = $request.Body
    $headers = $request.Headers

    # CORS preflight
    if ($method -eq "OPTIONS") {
        Send-HttpResponse $stream 200 "OK" "text/plain" ([byte[]]@())
        return
    }

    # Public routes
    if ($path -eq "/" -and $method -eq "GET") {
        # Try multiple locations for index.html
        $indexPath = Join-Path $PSScriptRoot "index.html"
        if (-not (Test-Path $indexPath)) {
            # Try dist/ folder (if running from parent directory)
            $indexPath = Join-Path $PSScriptRoot "dist\index.html"
        }
        if (-not (Test-Path $indexPath)) {
            # Try parent's dist/ folder
            $indexPath = Join-Path (Split-Path $PSScriptRoot -Parent) "dist\index.html"
        }
        Write-Host "[ROUTE] Looking for index.html at: $indexPath" -ForegroundColor Cyan
        if (Test-Path $indexPath) {
            Send-File $stream $indexPath "text/html"
        } else {
            Send-JsonError $stream 404 "index.html not found at $indexPath"
        }
        return
    }
    if ($path.StartsWith("/assets/") -and $method -eq "GET") {
        # Serve static assets (CSS, JS)
        $assetName = $path.Substring(8)
        $assetPath = Join-Path $PSScriptRoot "assets\$assetName"
        if (-not (Test-Path $assetPath)) {
            $assetPath = Join-Path $PSScriptRoot "dist\assets\$assetName"
        }
        if (-not (Test-Path $assetPath)) {
            $assetPath = Join-Path (Split-Path $PSScriptRoot -Parent) "dist\assets\$assetName"
        }
        Write-Host "[ROUTE] Looking for asset: $assetPath" -ForegroundColor Cyan
        if (Test-Path $assetPath) {
            $ext = [System.IO.Path]::GetExtension($assetPath).ToLower()
            $contentType = switch ($ext) {
                ".js" { "application/javascript" }
                ".css" { "text/css" }
                ".json" { "application/json" }
                ".png" { "image/png" }
                ".jpg" { "image/jpeg" }
                ".svg" { "image/svg+xml" }
                default { "application/octet-stream" }
            }
            Send-File $stream $assetPath $contentType
        } else {
            Send-JsonError $stream 404 "Asset not found: $assetName"
        }
        return
    }
    if ($path -eq "/probe.ps1" -and $method -eq "GET") {
        $probePath = Join-Path $PSScriptRoot "probe.ps1"
        if (Test-Path $probePath) {
            Send-File $stream $probePath "text/plain"
        } else {
            Send-JsonError $stream 404 "probe.ps1 not found"
        }
        return
    }
    if ($path -eq "/favicon.ico" -and $method -eq "GET") {
        # Return empty 204 No Content for favicon
        Send-HttpResponse $stream 204 "No Content" "image/x-icon" ([byte[]]@())
        return
    }

    # API routes
    if ($path -eq "/api/health" -and $method -eq "GET") {
        Send-Json $stream 200 @{ status = "ok"; time = (Get-Date -Format "o") }
        return
    }

    if ($path -eq "/api/login" -and $method -eq "POST") {
        Write-Host "[LOGIN] Body length: $($body.Length)" -ForegroundColor Cyan
        Write-Host "[LOGIN] Body content: $body" -ForegroundColor Cyan

        if ([string]::IsNullOrWhiteSpace($body)) {
            Write-Host "[LOGIN] ERROR: Empty body" -ForegroundColor Red
            Send-JsonError $stream 400 "Empty request body"
            return
        }

        try {
            $data = $body | ConvertFrom-Json
            Write-Host "[LOGIN] Parsed data - username: $($data.username)" -ForegroundColor Green
        } catch {
            Write-Host "[LOGIN] ERROR parsing JSON: $_" -ForegroundColor Red
            Send-JsonError $stream 400 "Invalid JSON"
            return
        }

        if ([string]::IsNullOrWhiteSpace($data.username) -or [string]::IsNullOrWhiteSpace($data.password)) {
            Write-Host "[LOGIN] ERROR: Missing username or password" -ForegroundColor Red
            Send-JsonError $stream 400 "Username and password required"
            return
        }

        $users = Read-JsonList $script:UsersFile
        Write-Host "[LOGIN] Found $($users.Count) users in database" -ForegroundColor Cyan
        $user = $null
        foreach ($u in $users) {
            Write-Host "[LOGIN] Checking user: $($u.name)" -ForegroundColor Gray
            if ($u.name -eq $data.username) {
                $user = $u
                Write-Host "[LOGIN] User found: $($u.name)" -ForegroundColor Green
                Write-Host "[LOGIN] User properties:" -ForegroundColor Cyan
                $u.PSObject.Properties | ForEach-Object {
                    $val = $_.Value
                    if ($_.Name -eq "passwordHash") {
                        $val = if ($val) { "[HASH PRESENT - $($val.Length) chars]" } else { "[NULL/EMPTY]" }
                    }
                    Write-Host "  $($_.Name) = $val" -ForegroundColor Gray
                }
                break
            }
        }
        if ($null -eq $user) {
            Write-Host "[LOGIN] User not found: $($data.username)" -ForegroundColor Red
            Send-JsonError $stream 401 "Invalid credentials"
            return
        }
        # Explicit type conversion for PSCustomObject properties
        $userPassword = [string]$data.password
        $userHash = [string]$user.passwordHash

        Write-Host "[LOGIN] Password to check: $($userPassword.Length) chars" -ForegroundColor Cyan
        Write-Host "[LOGIN] Hash to check: $($userHash.Length) chars" -ForegroundColor Cyan

        if ([string]::IsNullOrWhiteSpace($userHash)) {
            Write-Host "[LOGIN] ERROR: User passwordHash is null or empty after conversion!" -ForegroundColor Red
            Write-Host "[LOGIN] This usually means the users.json file is corrupted." -ForegroundColor Red
            Write-Host "[LOGIN] Solution: Delete the data folder and restart the server." -ForegroundColor Red
            Send-JsonError $stream 500 "User data corrupted - please reset admin password"
            return
        }

        Write-Host "[LOGIN] Calling Test-PasswordHash..." -ForegroundColor Cyan
        $passwordValid = Test-PasswordHash $userPassword $userHash

        if (-not $passwordValid) {
            Write-Host "[LOGIN] Password verification failed" -ForegroundColor Red
            Send-JsonError $stream 401 "Invalid credentials"
            return
        }

        Write-Host "[LOGIN] Password verification successful!" -ForegroundColor Green

        # Create session
        Write-Host "[LOGIN] Creating session..." -ForegroundColor Cyan
        $token = New-Session ([string]$user.name)
        Write-Host "[LOGIN] Session created, token length: $($token.Length)" -ForegroundColor Green

        # Build response with explicit type conversion
        Write-Host "[LOGIN] Building response..." -ForegroundColor Cyan
        $responseObj = @{
            token = [string]$token
            username = [string]$user.name
            role = [string]$user.role
        }

        Write-Host "[LOGIN] Response object created:" -ForegroundColor Cyan
        Write-Host "  token: $($responseObj.token.Length) chars" -ForegroundColor Gray
        Write-Host "  username: $($responseObj.username)" -ForegroundColor Gray
        Write-Host "  role: $($responseObj.role)" -ForegroundColor Gray

        # Send response
        Write-Host "[LOGIN] Sending response..." -ForegroundColor Cyan
        Send-Json $stream 200 $responseObj
        Write-Host "[LOGIN] Response sent successfully!" -ForegroundColor Green
        return
    }

    if ($path -eq "/api/register" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($data.username) -or [string]::IsNullOrWhiteSpace($data.password)) {
            Send-JsonError $stream 400 "Username and password required"
            return
        }
        if ($data.username.Length -lt 2 -or $data.username.Length -gt 32) {
            Send-JsonError $stream 400 "Username must be 2-32 characters"
            return
        }
        if ($data.password.Length -lt 6) {
            Send-JsonError $stream 400 "Password must be at least 6 characters"
            return
        }
        $mtx = Get-Mutex "TestDeck_Users"
        $mtx.WaitOne() | Out-Null
        try {
            $users = Read-JsonList $script:UsersFile
            foreach ($u in $users) {
                if ($u.name -eq $data.username) {
                    Send-JsonError $stream 409 "Username already exists"
                    return
                }
            }
            [void]$users.Add(@{
                name = $data.username
                role = "user"
                passwordHash = (New-PasswordHash $data.password)
                createdAt = (Get-Date -Format "o")
            })
            Write-JsonList $script:UsersFile $users
        } finally { $mtx.ReleaseMutex() | Out-Null }
        $token = New-Session $data.username
        Send-Json $stream 200 @{ token = $token; username = $data.username; role = "user" }
        return
    }

    # Auth-required routes
    $token = Get-AuthToken $headers
    $currentUser = Get-SessionUser $token
    if ($null -eq $currentUser) {
        Send-JsonError $stream 401 "Authentication required"
        return
    }

    if ($path -eq "/api/logout" -and $method -eq "POST") {
        Remove-Session $token
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    if ($path -eq "/api/me" -and $method -eq "GET") {
        Send-Json $stream 200 @{ name = $currentUser.name; role = $currentUser.role; createdAt = $currentUser.createdAt }
        return
    }

    if ($path -eq "/api/password" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($data.newPassword) -or $data.newPassword.Length -lt 6) {
            Send-JsonError $stream 400 "New password must be at least 6 characters"
            return
        }
        $mtx = Get-Mutex "TestDeck_Users"
        $mtx.WaitOne() | Out-Null
        try {
            $users = Read-JsonList $script:UsersFile
            foreach ($u in $users) {
                if ($u.name -eq $currentUser.name) {
                    $u.passwordHash = New-PasswordHash $data.newPassword
                    break
                }
            }
            Write-JsonList $script:UsersFile $users
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Drives
    if ($path -eq "/api/drives" -and $method -eq "GET") {
        Write-Host "[DRIVES-GET] Loading drives from file" -ForegroundColor Cyan
        $drives = Read-JsonList $script:DrivesFile
        Write-Host "[DRIVES-GET] Returning $($drives.Count) drives" -ForegroundColor Green
        Send-Json $stream 200 $drives
        return
    }
    if ($path -eq "/api/drives" -and $method -eq "POST") {
        Write-Host "[DRIVES-POST] Creating new drive record" -ForegroundColor Cyan
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Drives"
        $mtx.WaitOne() | Out-Null
        try {
            $drives = Read-JsonList $script:DrivesFile
            Write-Host "[DRIVES-POST] Current drives count: $($drives.Count)" -ForegroundColor Gray
            $driveId = [guid]::NewGuid().ToString("N").Substring(0,12)
            Write-Host "[DRIVES-POST] Generated new ID: $driveId" -ForegroundColor Gray
            $record = @{
                id = $driveId
                owner = $currentUser.name
                createdAt = (Get-Date -Format "o")
                serial = $data.serial
                model = $data.model
                firmware = $data.firmware
                capacityGB = $data.capacityGB
                bus = $data.bus
                media = $data.media
                healthStatus = $data.healthStatus
                wear = $data.wear
                tempC = $data.tempC
                readErrors = $data.readErrors
                writeErrors = $data.writeErrors
                seqRead = $data.seqRead
                seqWrite = $data.seqWrite
                rndRead = $data.rndRead
                rndWrite = $data.rndWrite
                rndReadIops = $data.rndReadIops
                rndWriteIops = $data.rndWriteIops
                batch = $data.batch
                method = $data.method
                healthScore = $data.healthScore
                lifePct = $data.lifePct
                profileId = $data.profileId
                profileName = $data.profileName
                speedVerdict = $data.speedVerdict
                verdict = $data.verdict
                notes = $data.notes
                extended = $data.extended
            }
            [void]$drives.Add($record)
            Write-Host "[DRIVES-POST] Added record to list, new count: $($drives.Count)" -ForegroundColor Green
            Write-JsonList $script:DrivesFile $drives
            Write-Host "[DRIVES-POST] Saved to file successfully" -ForegroundColor Green

            # Auto-create/update lifecycle entry
            if (-not [string]::IsNullOrWhiteSpace($data.serial)) {
                $lifecycle = Read-JsonList $script:LifecycleFile
                $found = $null
                foreach ($lc in $lifecycle) {
                    if ($lc.serial -eq $data.serial) { $found = $lc; break }
                }
                if ($null -eq $found) {
                    [void]$lifecycle.Add(@{
                        serial = $data.serial
                        status = "TESTED"
                        updated = (Get-Date -Format "o")
                        by = $currentUser.name
                        lastTest = $driveId
                        history = @(@{ at = (Get-Date -Format "o"); by = $currentUser.name; status = "TESTED"; note = "Initial test" })
                    })
                } else {
                    $found.status = "TESTED"
                    $found.updated = (Get-Date -Format "o")
                    $found.by = $currentUser.name
                    $found.lastTest = $driveId
                    $hist = [System.Collections.ArrayList]@()
                    if ($null -ne $found.history) {
                        foreach ($h in $found.history) { [void]$hist.Add($h) }
                    }
                    [void]$hist.Add(@{ at = (Get-Date -Format "o"); by = $currentUser.name; status = "TESTED"; note = "Test recorded" })
                    $found.history = $hist
                }
                Write-JsonList $script:LifecycleFile $lifecycle
            }
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 $record
        return
    }

    # Delete drive
    if ($path -match "^/api/drives/(.+)$" -and $method -eq "DELETE") {
        $driveId = $Matches[1]
        $mtx = Get-Mutex "TestDeck_Drives"
        $mtx.WaitOne() | Out-Null
        try {
            $drives = Read-JsonList $script:DrivesFile
            $toDelete = $null
            foreach ($d in $drives) {
                if ($d.id -eq $driveId) { $toDelete = $d; break }
            }
            if ($null -eq $toDelete) {
                Send-JsonError $stream 404 "Drive not found"
                return
            }
            if ($toDelete.owner -ne $currentUser.name -and $currentUser.role -ne "admin") {
                Send-JsonError $stream 403 "Not authorized"
                return
            }
            $drives.Remove($toDelete) | Out-Null
            Write-JsonList $script:DrivesFile $drives
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Profiles
    if ($path -eq "/api/profiles" -and $method -eq "GET") {
        $profiles = Read-JsonList $script:ProfilesFile
        Send-Json $stream 200 $profiles
        return
    }
    if ($path -eq "/api/profiles" -and $method -eq "POST") {
        Write-Host "[PROFILES-POST] Creating new profile..." -ForegroundColor Cyan
        if ($currentUser.role -ne "admin") {
            Write-Host "[PROFILES-POST] ERROR: User is not admin" -ForegroundColor Red
            Send-JsonError $stream 403 "Admin only"; return
        }
        try {
            $data = $body | ConvertFrom-Json
            Write-Host "[PROFILES-POST] Parsed  name=$($data.name)" -ForegroundColor Green
        } catch {
            Write-Host "[PROFILES-POST] ERROR parsing JSON: $_" -ForegroundColor Red
            Send-JsonError $stream 400 "Invalid JSON"; return
        }
        $mtx = Get-Mutex "TestDeck_Profiles"
        $mtx.WaitOne() | Out-Null
        try {
            $profilesRaw = Read-JsonList $script:ProfilesFile
            # Explicit ArrayList conversion for PS 5.1 compatibility
            $profiles = New-Object System.Collections.ArrayList
            foreach ($item in $profilesRaw) { [void]$profiles.Add($item) }
            Write-Host "[PROFILES-POST] Current profiles count: $($profiles.Count)" -ForegroundColor Gray
            $profile = @{
                id = "prof-" + [guid]::NewGuid().ToString("N").Substring(0,8)
                name = [string]$data.name
                matchSubstring = [string]$data.matchSubstring
                bus = [string]$data.bus
                media = [string]$data.media
                minSeqR = [int]$data.minSeqR
                minSeqW = [int]$data.minSeqW
                min4kR = [int]$data.min4kR
                min4kW = [int]$data.min4kW
                tolerancePct = [int]$data.tolerancePct
                ratedTBW = [int]$data.ratedTBW
            }
            Write-Host "[PROFILES-POST] Created profile object" -ForegroundColor Gray
            [void]$profiles.Add($profile)
            Write-Host "[PROFILES-POST] New profiles count: $($profiles.Count)" -ForegroundColor Gray
            Write-JsonList $script:ProfilesFile $profiles
            Write-Host "[PROFILES-POST] Profiles saved successfully" -ForegroundColor Green
            Send-Json $stream 200 $profile
        } catch {
            Write-Host "[PROFILES-POST] ERROR: $_" -ForegroundColor Red
            Write-Host "[PROFILES-POST] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
            Send-JsonError $stream 500 "Failed to create profile: $($_.Exception.Message)"
        } finally {
            $mtx.ReleaseMutex() | Out-Null
        }
        return
    }
    if ($path -match "^/api/profiles/(.+)$" -and $method -eq "PATCH") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $profId = $Matches[1]
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Profiles"
        $mtx.WaitOne() | Out-Null
        try {
            $profiles = Read-JsonList $script:ProfilesFile
            foreach ($p in $profiles) {
                if ($p.id -eq $profId) {
                    $props = @("name","matchSubstring","bus","media","minSeqR","minSeqW","min4kR","min4kW","tolerancePct","ratedTBW")
                    foreach ($prop in $props) {
                        if ($null -ne $data.$prop) { $p.$prop = $data.$prop }
                    }
                    break
                }
            }
            Write-JsonList $script:ProfilesFile $profiles
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }
    if ($path -match "^/api/profiles/(.+)$" -and $method -eq "DELETE") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $profId = $Matches[1]
        $mtx = Get-Mutex "TestDeck_Profiles"
        $mtx.WaitOne() | Out-Null
        try {
            $profiles = Read-JsonList $script:ProfilesFile
            $toRemove = $null
            foreach ($p in $profiles) { if ($p.id -eq $profId) { $toRemove = $p; break } }
            if ($null -ne $toRemove) { $profiles.Remove($toRemove) | Out-Null }
            Write-JsonList $script:ProfilesFile $profiles
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Models
    if ($path -eq "/api/models" -and $method -eq "GET") {
        Send-Json $stream 200 (Read-JsonList $script:ModelsFile)
        return
    }
    if ($path -eq "/api/models" -and $method -eq "POST") {
        Write-Host "[MODELS-POST] Creating new model..." -ForegroundColor Cyan
        if ($currentUser.role -ne "admin") {
            Write-Host "[MODELS-POST] ERROR: User is not admin" -ForegroundColor Red
            Send-JsonError $stream 403 "Admin only"; return
        }
        try {
            $data = $body | ConvertFrom-Json
            Write-Host "[MODELS-POST] Parsed  family=$($data.family), manufacturer=$($data.manufacturer)" -ForegroundColor Green
        } catch {
            Write-Host "[MODELS-POST] ERROR parsing JSON: $_" -ForegroundColor Red
            Send-JsonError $stream 400 "Invalid JSON"; return
        }
        $mtx = Get-Mutex "TestDeck_Models"
        $mtx.WaitOne() | Out-Null
        try {
            $modelsRaw = Read-JsonList $script:ModelsFile
            # Explicit ArrayList conversion for PS 5.1 compatibility
            $models = New-Object System.Collections.ArrayList
            foreach ($item in $modelsRaw) { [void]$models.Add($item) }
            Write-Host "[MODELS-POST] Current models count: $($models.Count)" -ForegroundColor Gray
            $model = @{
                id = "mod-" + [guid]::NewGuid().ToString("N").Substring(0,8)
                family = [string]$data.family
                manufacturer = [string]$data.manufacturer
                matchPattern = [string]$data.matchPattern
            }
            Write-Host "[MODELS-POST] Created model object" -ForegroundColor Gray
            [void]$models.Add($model)
            Write-Host "[MODELS-POST] New models count: $($models.Count)" -ForegroundColor Gray
            Write-JsonList $script:ModelsFile $models
            Write-Host "[MODELS-POST] Models saved successfully" -ForegroundColor Green
            Send-Json $stream 200 $model
        } catch {
            Write-Host "[MODELS-POST] ERROR: $_" -ForegroundColor Red
            Write-Host "[MODELS-POST] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
            Send-JsonError $stream 500 "Failed to create model: $($_.Exception.Message)"
        } finally {
            $mtx.ReleaseMutex() | Out-Null
        }
        return
    }
    if ($path -match "^/api/models/(.+)$" -and $method -eq "PATCH") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $modId = $Matches[1]
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Models"
        $mtx.WaitOne() | Out-Null
        try {
            $models = Read-JsonList $script:ModelsFile
            foreach ($m in $models) {
                if ($m.id -eq $modId) {
                    if ($null -ne $data.family) { $m.family = $data.family }
                    if ($null -ne $data.manufacturer) { $m.manufacturer = $data.manufacturer }
                    if ($null -ne $data.matchPattern) { $m.matchPattern = $data.matchPattern }
                    break
                }
            }
            Write-JsonList $script:ModelsFile $models
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }
    if ($path -match "^/api/models/(.+)$" -and $method -eq "DELETE") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $modId = $Matches[1]
        $mtx = Get-Mutex "TestDeck_Models"
        $mtx.WaitOne() | Out-Null
        try {
            $models = Read-JsonList $script:ModelsFile
            $toRemove = $null
            foreach ($m in $models) { if ($m.id -eq $modId) { $toRemove = $m; break } }
            if ($null -ne $toRemove) { $models.Remove($toRemove) | Out-Null }
            Write-JsonList $script:ModelsFile $models
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Labels
    if ($path -eq "/api/labels" -and $method -eq "GET") {
        Send-Json $stream 200 (Read-JsonList $script:LabelsFile)
        return
    }
    if ($path -eq "/api/labels" -and $method -eq "POST") {
        Write-Host "[LABELS-POST] Creating new label..." -ForegroundColor Cyan
        if ($currentUser.role -ne "admin") {
            Write-Host "[LABELS-POST] ERROR: User is not admin" -ForegroundColor Red
            Send-JsonError $stream 403 "Admin only"; return
        }
        try {
            $data = $body | ConvertFrom-Json
            Write-Host "[LABELS-POST] Parsed  name=$($data.name), width=$($data.widthMm), height=$($data.heightMm)" -ForegroundColor Green
        } catch {
            Write-Host "[LABELS-POST] ERROR parsing JSON: $_" -ForegroundColor Red
            Send-JsonError $stream 400 "Invalid JSON"; return
        }
        $mtx = Get-Mutex "TestDeck_Labels"
        $mtx.WaitOne() | Out-Null
        try {
            $labelsRaw = Read-JsonList $script:LabelsFile
            # Explicit ArrayList conversion for PS 5.1 compatibility
            $labels = New-Object System.Collections.ArrayList
            foreach ($item in $labelsRaw) { [void]$labels.Add($item) }
            Write-Host "[LABELS-POST] Current labels count: $($labels.Count)" -ForegroundColor Gray
            $label = @{
                id = "lbl-" + [guid]::NewGuid().ToString("N").Substring(0,8)
                name = [string]$data.name
                widthMm = [int]$data.widthMm
                heightMm = [int]$data.heightMm
            }
            Write-Host "[LABELS-POST] Created label object: $($label | ConvertTo-Json -Compress)" -ForegroundColor Gray
            [void]$labels.Add($label)
            Write-Host "[LABELS-POST] New labels count: $($labels.Count)" -ForegroundColor Gray
            Write-JsonList $script:LabelsFile $labels
            Write-Host "[LABELS-POST] Labels saved successfully" -ForegroundColor Green
            Send-Json $stream 200 $label
        } catch {
            Write-Host "[LABELS-POST] ERROR: $_" -ForegroundColor Red
            Write-Host "[LABELS-POST] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
            Send-JsonError $stream 500 "Failed to create label: $($_.Exception.Message)"
        } finally {
            $mtx.ReleaseMutex() | Out-Null
        }
        Send-Json $stream 200 $label
        return
    }
    if ($path -match "^/api/labels/(.+)$" -and $method -eq "PATCH") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $lblId = $Matches[1]
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Labels"
        $mtx.WaitOne() | Out-Null
        try {
            $labels = Read-JsonList $script:LabelsFile
            foreach ($l in $labels) {
                if ($l.id -eq $lblId) {
                    if ($null -ne $data.name) { $l.name = $data.name }
                    if ($null -ne $data.widthMm) { $l.widthMm = $data.widthMm }
                    if ($null -ne $data.heightMm) { $l.heightMm = $data.heightMm }
                    break
                }
            }
            Write-JsonList $script:LabelsFile $labels
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }
    if ($path -match "^/api/labels/(.+)$" -and $method -eq "DELETE") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $lblId = $Matches[1]
        $mtx = Get-Mutex "TestDeck_Labels"
        $mtx.WaitOne() | Out-Null
        try {
            $labels = Read-JsonList $script:LabelsFile
            $toRemove = $null
            foreach ($l in $labels) { if ($l.id -eq $lblId) { $toRemove = $l; break } }
            if ($null -ne $toRemove) { $labels.Remove($toRemove) | Out-Null }
            Write-JsonList $script:LabelsFile $labels
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Lifecycle
    if ($path -eq "/api/lifecycle" -and $method -eq "GET") {
        Send-Json $stream 200 (Read-JsonList $script:LifecycleFile)
        return
    }
    if ($path -eq "/api/lifecycle" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Lifecycle"
        $mtx.WaitOne() | Out-Null
        try {
            $lifecycle = Read-JsonList $script:LifecycleFile
            $found = $null
            foreach ($lc in $lifecycle) {
                if ($lc.serial -eq $data.serial) { $found = $lc; break }
            }
            if ($null -eq $found) {
                $entry = @{
                    serial = $data.serial
                    status = $data.status
                    updated = (Get-Date -Format "o")
                    by = $currentUser.name
                    lastTest = ""
                    history = @(@{ at = (Get-Date -Format "o"); by = $currentUser.name; status = $data.status; note = $data.note })
                }
                [void]$lifecycle.Add($entry)
            } else {
                $found.status = $data.status
                $found.updated = (Get-Date -Format "o")
                $found.by = $currentUser.name
                $hist = [System.Collections.ArrayList]@()
                if ($null -ne $found.history) { foreach ($h in $found.history) { [void]$hist.Add($h) } }
                [void]$hist.Add(@{ at = (Get-Date -Format "o"); by = $currentUser.name; status = $data.status; note = $data.note })
                $found.history = $hist
            }
            Write-JsonList $script:LifecycleFile $lifecycle
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # Users (admin)
    if ($path -eq "/api/users" -and $method -eq "GET") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $users = Read-JsonList $script:UsersFile
        $safe = [System.Collections.ArrayList]@()
        foreach ($u in $users) {
            [void]$safe.Add(@{ name = $u.name; role = $u.role; createdAt = $u.createdAt })
        }
        Send-Json $stream 200 $safe
        return
    }
    if ($path -eq "/api/users" -and $method -eq "POST") {
        Write-Host "[USERS-POST] Creating new user..." -ForegroundColor Cyan
        if ($currentUser.role -ne "admin") {
            Write-Host "[USERS-POST] ERROR: User is not admin" -ForegroundColor Red
            Send-JsonError $stream 403 "Admin only"; return
        }
        try {
            $data = $body | ConvertFrom-Json
            Write-Host "[USERS-POST] Parsed  username=$($data.username), role=$($data.role)" -ForegroundColor Green
        } catch {
            Write-Host "[USERS-POST] ERROR parsing JSON: $_" -ForegroundColor Red
            Send-JsonError $stream 400 "Invalid JSON"; return
        }
        if ([string]::IsNullOrWhiteSpace($data.username) -or [string]::IsNullOrWhiteSpace($data.password)) {
            Write-Host "[USERS-POST] ERROR: Missing username or password" -ForegroundColor Red
            Send-JsonError $stream 400 "Username and password required"; return
        }
        $mtx = Get-Mutex "TestDeck_Users"
        $mtx.WaitOne() | Out-Null
        try {
            $usersRaw = Read-JsonList $script:UsersFile
            # Explicit ArrayList conversion for PS 5.1 compatibility
            $users = New-Object System.Collections.ArrayList
            foreach ($item in $usersRaw) { [void]$users.Add($item) }
            Write-Host "[USERS-POST] Current users count: $($users.Count)" -ForegroundColor Gray
            foreach ($u in $users) {
                if ($u.name -eq $data.username) {
                    Write-Host "[USERS-POST] ERROR: User already exists" -ForegroundColor Red
                    Send-JsonError $stream 409 "Exists"; return
                }
            }
            $newUser = @{
                name = [string]$data.username
                role = [string]$(if ($data.role) { $data.role } else { "user" })
                passwordHash = (New-PasswordHash $data.password)
                createdAt = (Get-Date -Format "o")
            }
            Write-Host "[USERS-POST] Created user object" -ForegroundColor Gray
            [void]$users.Add($newUser)
            Write-Host "[USERS-POST] New users count: $($users.Count)" -ForegroundColor Gray
            Write-JsonList $script:UsersFile $users
            Write-Host "[USERS-POST] Users saved successfully" -ForegroundColor Green
            Send-Json $stream 200 @{ ok = $true }
        } catch {
            Write-Host "[USERS-POST] ERROR: $_" -ForegroundColor Red
            Write-Host "[USERS-POST] Stack: $($_.ScriptStackTrace)" -ForegroundColor Red
            Send-JsonError $stream 500 "Failed to create user: $($_.Exception.Message)"
        } finally {
            $mtx.ReleaseMutex() | Out-Null
        }
        return
    }
    if ($path -match "^/api/users/(.+)$" -and $method -eq "PATCH") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $userName = $Matches[1]
        $data = $body | ConvertFrom-Json
        $mtx = Get-Mutex "TestDeck_Users"
        $mtx.WaitOne() | Out-Null
        try {
            $users = Read-JsonList $script:UsersFile
            foreach ($u in $users) {
                if ($u.name -eq $userName) {
                    if ($null -ne $data.role) { $u.role = $data.role }
                    if ($null -ne $data.password) { $u.passwordHash = New-PasswordHash $data.password }
                    break
                }
            }
            Write-JsonList $script:UsersFile $users
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }
    if ($path -match "^/api/users/(.+)$" -and $method -eq "DELETE") {
        if ($currentUser.role -ne "admin") { Send-JsonError $stream 403 "Admin only"; return }
        $userName = $Matches[1]
        if ($userName -eq $currentUser.name) { Send-JsonError $stream 400 "Cannot delete yourself"; return }
        $mtx = Get-Mutex "TestDeck_Users"
        $mtx.WaitOne() | Out-Null
        try {
            $users = Read-JsonList $script:UsersFile
            $toRemove = $null
            foreach ($u in $users) { if ($u.name -eq $userName) { $toRemove = $u; break } }
            if ($null -ne $toRemove) { $users.Remove($toRemove) | Out-Null }
            Write-JsonList $script:UsersFile $users
        } finally { $mtx.ReleaseMutex() | Out-Null }
        Send-Json $stream 200 @{ ok = $true }
        return
    }

    # 404
    Send-JsonError $stream 404 "Route not found: $method $path"
}

# --- TLS Certificate ---
function Get-OrCreateCert {
    $certPath = if ($CertFile) { $CertFile } else { Join-Path $script:DataDir "testdeck-tls.pfx" }
    $passPath = Join-Path $script:DataDir "testdeck-tls.pass"

    if ($CertPass) { return @{ Path = $certPath; Password = $CertPass } }
    if (Test-Path $passPath) {
        $pass = Get-Content $passPath -Raw
        return @{ Path = $certPath; Password = $pass.Trim() }
    }

    # Generate self-signed cert
    $pass = New-RandomPassword 24
    $computerName = $env:COMPUTERNAME
    $ips = @()
    try {
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue
        foreach ($a in $adapters) {
            if ($a.IPAddress -ne "127.0.0.1") { $ips += $a.IPAddress }
        }
    } catch {}

    $sanList = @("localhost", $computerName, "127.0.0.1")
    $sanList += $ips
    $sanString = "&SAN=dns=" + ($sanList -join "&dns=")

    $dn = "CN=TestDeck"
    try {
        $makecert = "makecert.exe"
        $pvk2pfx = "pvk2pfx.exe"
        # Try New-SelfSignedCertificate (needs admin for cert store, but we can export)
        $cert = New-SelfSignedCertificate -DnsName $sanList -CertStoreLocation "Cert:\CurrentUser\My" -NotAfter (Get-Date).AddYears(5) -ErrorAction Stop
        $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $pass)
        [System.IO.File]::WriteAllBytes($certPath, $certBytes)
        # Remove from store
        Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Warning: Could not generate TLS cert: $_" -ForegroundColor Yellow
        Write-Host "HTTPS will not be available. Use -NoTls or run once as admin." -ForegroundColor Yellow
        return $null
    }

    Set-Content $passPath $pass -NoNewline
    return @{ Path = $certPath; Password = $pass }
}

# --- Main Server Loop ---
function Start-Server {
    Write-Host "=== TestDeck Server Starting ===" -ForegroundColor Cyan
    Write-Host "Initializing data..." -ForegroundColor Gray

    try {
        Initialize-Data
        Write-Host "Data initialized successfully" -ForegroundColor Green
    } catch {
        Write-Host "ERROR initializing  $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return
    }

    Write-Host "Starting TestDeck Server..." -ForegroundColor Cyan
    Write-Host "Data directory: $($script:DataDir)" -ForegroundColor Gray

    Write-Host "Creating TCP listener on localhost:$Port..." -ForegroundColor Gray
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        Write-Host "TestDeck Server running on http://localhost:$Port" -ForegroundColor Green
        Write-Host "TLS disabled for now (use -NoTls flag)" -ForegroundColor Yellow
    } catch {
        Write-Host "ERROR starting listener: $_" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        return
    }

    Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray
    Write-Host "Waiting for connections..." -ForegroundColor Cyan

    try {
        while ($true) {
            # Simple blocking accept for HTTP
            try {
                $client = $listener.AcceptTcpClient()
                Write-Host "[CONN] Accepted connection from $($client.Client.RemoteEndPoint)" -ForegroundColor Gray

                $clientStream = $client.GetStream()
                $client.Client.ReceiveTimeout = 30000  # 30 seconds for reading request
                $client.Client.SendTimeout = 30000

                $request = Parse-HttpRequest $clientStream
                if ($null -eq $request) {
                    Write-Host "[CONN] Request parsing failed" -ForegroundColor Yellow
                    $client.Close()
                    continue
                }

                Write-Host "[CONN] Handling: $($request.Method) $($request.Path)" -ForegroundColor Green
                Handle-Request $clientStream $request
                Write-Host "[CONN] Completed" -ForegroundColor Green
                $client.Close()
            } catch {
                Write-Host "[CONN] Error: $_" -ForegroundColor Red
                try { if ($null -ne $client) { $client.Close() } } catch {}
            }
        }
    } finally {
        $listener.Stop()
    }
}

Start-Server
