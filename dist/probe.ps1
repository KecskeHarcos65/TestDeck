# TestDeck Probe Agent - PowerShell 5.1 compatible
# Drive inventory + Win32 benchmarks via P/Invoke
# Runs on loopback:8321, single-threaded
param(
    [int]$ProbePort = 8321
)

$ErrorActionPreference = "Continue"

# --- P/Invoke Declarations ---
$kernel32 = @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public class TestDeckWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct OVERLAPPED {
        public IntPtr Internal;
        public IntPtr InternalHigh;
        public uint Offset;
        public uint OffsetHigh;
        public IntPtr hEvent;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern SafeFileHandle CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(
        SafeFileHandle hFile,
        IntPtr lpBuffer,
        uint nNumberOfBytesToRead,
        out uint lpNumberOfBytesRead,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteFile(
        SafeFileHandle hFile,
        IntPtr lpBuffer,
        uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten,
        IntPtr lpOverlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetFilePointerEx(
        SafeFileHandle hFile,
        long liDistanceToMove,
        IntPtr lpNewFilePointer,
        uint dwMoveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateEvent(
        IntPtr lpEventAttributes,
        bool bManualReset,
        bool bInitialState,
        string lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ResetEvent(IntPtr hEvent);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetEvent(IntPtr hEvent);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForMultipleObjects(
        uint nCount,
        IntPtr[] lpHandles,
        bool bWaitAll,
        uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetOverlappedResult(
        SafeFileHandle hFile,
        IntPtr lpOverlapped,
        out uint lpNumberOfBytesTransferred,
        bool bWait);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FlushFileBuffers(SafeFileHandle hFile);

    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint FILE_SHARE_READ = 0x00000001;
    public const uint FILE_SHARE_WRITE = 0x00000002;
    public const uint CREATE_ALWAYS = 2;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    public const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    public const uint FILE_BEGIN = 0;
    public const uint WAIT_OBJECT_0 = 0;
    public const uint WAIT_TIMEOUT = 0x00000102;
    public const uint WAIT_FAILED = 0xFFFFFFFF;
    public const int INVALID_HANDLE_VALUE_32 = -1;
}
"@

Add-Type -TypeDefinition $kernel32 -Language CSharp

# --- Constants (PS 5.1 safe - no hex literals >= 0x80000000) ---
$GENERIC_READ = [uint32]::Parse("2147483648")   # 0x80000000
$GENERIC_WRITE = [uint32]1073741824              # 0x40000000
$FILE_SHARE_RW = [uint32]3                       # READ|WRITE
$CREATE_ALWAYS = [uint32]2
$OPEN_EXISTING = [uint32]3
$FILE_FLAG_NO_BUFFERING = [uint32]536870912      # 0x20000000
$FILE_FLAG_OVERLAPPED = [uint32]1073741824       # 0x40000000 (same bit as GENERIC_WRITE, used separately)
$FILE_FLAG_OVERLAPPED_VAL = [uint32]0x40000000
$FILE_BEGIN = [uint32]0
$BLOCK_SIZE = 1048576  # 1 MiB

# --- Writable folder cache ---
$script:WritableFolders = @{}

function Get-WritableFolder($driveLetter) {
    if ($script:WritableFolders.ContainsKey($driveLetter)) {
        return $script:WritableFolders[$driveLetter]
    }
    $candidates = @(
        "${driveLetter}:\"
        "${driveLetter}:\TestDeck"
        "${driveLetter}:\ProgramData\TestDeck"
        "${driveLetter}:\Users\Public\TestDeck"
    )
    foreach ($cand in $candidates) {
        try {
            if (-not (Test-Path $cand)) {
                New-Item -ItemType Directory -Path $cand -Force -ErrorAction Stop | Out-Null
            }
            $testFile = Join-Path $cand "testdeck_write_test.tmp"
            [System.IO.File]::WriteAllText($testFile, "test")
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            $script:WritableFolders[$driveLetter] = $cand
            return $cand
        } catch {
            continue
        }
    }
    return $null
}

# --- Aligned Buffer Allocation ---
function New-AlignedBuffer($size) {
    # Allocate with 4096-byte alignment using Marshal.AllocHGlobal
    $rawPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size + 4096)
    $rawAddr = $rawPtr.ToInt64()
    $alignedAddr = ($rawAddr + 4095) -band (-bnot 4095)
    $alignedPtr = [IntPtr]$alignedAddr
    return @{ RawPtr = $rawPtr; AlignedPtr = $alignedPtr; Size = $size }
}

function Remove-AlignedBuffer($buf) {
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf.RawPtr)
}

# --- Drive Inventory ---
$script:DriveCache = $null
$script:DriveCacheTime = [DateTime]::MinValue

function Get-DriveInventory {
    if ($null -ne $script:DriveCache -and ((Get-Date) - $script:DriveCacheTime).TotalSeconds -lt 2) {
        return $script:DriveCache
    }

    $results = [System.Collections.ArrayList]@()

    try {
        $disks = Get-Disk -ErrorAction SilentlyContinue
    } catch {
        $disks = @()
    }

    foreach ($disk in $disks) {
        $diskNum = $disk.Number
        $info = @{
            diskNumber = $diskNum
            model = $disk.FriendlyName
            serial = ""
            firmware = ""
            capacityGB = [math]::Round($disk.Size / 1GB, 2)
            bus = "Unknown"
            media = "Unknown"
            healthStatus = "Unknown"
            operationalStatus = "Unknown"
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

        # Bus type
        $info.bus = switch ($disk.BusType) {
            3 { "USB" }
            4 { "SATA" }
            5 { "SATA" }  # AHCI
            11 { "NVMe" }
            17 { "NVMe" }
            default { 
                if ($disk.FriendlyName -match "NVMe|Samsung 9|WD SN|Intel SSDPE") { "NVMe" }
                elseif ($disk.FriendlyName -match "USB|External") { "USB" }
                else { "SATA" }
            }
        }

        # Media type
        $info.media = switch ($disk.MediaType) {
            "SSD" { "SSD" }
            "SCM" { "SSD" }
            "HDD" { "HDD" }
            "Unspecified" { if ($disk.Size -lt 500GB) { "SSD" } else { "HDD" } }
            default { "Unknown" }
        }

        # Health and operational status
        $info.healthStatus = $disk.HealthStatus
        $info.operationalStatus = $disk.OperationalStatus

        # Serial from CIM fallback
        try {
            $cimDisk = Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$diskNum" -ErrorAction Stop
            if ($null -ne $cimDisk) {
                $info.serial = $cimDisk.SerialNumber
                $info.firmware = $cimDisk.FirmwareRevision
                $info.fwSrc = "CIM"
                if ([string]::IsNullOrWhiteSpace($info.model) -or $info.model -eq "Disk drive") {
                    $info.model = $cimDisk.Model
                }
            }
        } catch {
            # Try alternate serial source
            try {
                $physMedia = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $diskNum }
                if ($null -ne $physMedia) {
                    $info.serial = $physMedia.SerialNumber
                    if ([string]::IsNullOrWhiteSpace($info.model)) { $info.model = $physMedia.FriendlyName }
                }
            } catch {}
        }

        # Letters via Get-Partition
        try {
            $partitions = Get-Partition -DiskNumber $diskNum -ErrorAction Stop
            $letters = @()
            foreach ($part in $partitions) {
                if (-not [string]::IsNullOrWhiteSpace($part.DriveLetter)) {
                    $letters += $part.DriveLetter
                }
            }
            $info.letters = $letters
            $info.letSrc = "Storage"
        } catch {
            # CIM fallback for letters
            try {
                $cimParts = Get-CimInstance -ClassName Win32_DiskPartition -Filter "DiskIndex=$diskNum" -ErrorAction Stop
                foreach ($part in $cimParts) {
                    $logDisks = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue | 
                        Where-Object { $_.DeviceID -match ($part.DeviceID -replace '\\','') }
                    foreach ($ld in $logDisks) {
                        if ($ld.DeviceID.Length -ge 1) {
                            $info.letters += $ld.DeviceID[0]
                        }
                    }
                }
                $info.letSrc = "CIM"
            } catch {
                $info.letSrc = "none"
            }
        }

        # Storage Reliability Counter (may need elevation)
        try {
            $relCounter = Get-StorageReliabilityCounter -Disk $disk -ErrorAction Stop
            if ($null -ne $relCounter) {
                $info.wear = $relCounter.Wear
                $info.tempC = $relCounter.Temperature
                $info.readErrors = $relCounter.ReadErrorsTotal
                $info.writeErrors = $relCounter.WriteErrorsTotal
                $info.relOk = $true
            }
        } catch {
            $info.relOk = $false
            $info.relErr = "Requires elevation: $($_.Exception.Message)"
        }

        [void]$results.Add($info)
    }

    $script:DriveCache = $results
    $script:DriveCacheTime = Get-Date
    return $results
}

# --- Benchmark Functions ---
function Run-SeqBench($driveLetter, $op, $sizeMB) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $filePath = Join-Path $folder "testdeck.seq.tmp"
    $sizeBytes = [long]$sizeMB * $BLOCK_SIZE

    try {
        $buf = New-AlignedBuffer $BLOCK_SIZE
        $rng = New-Object System.Random(42)
        $tempBuf = New-Object byte[] $BLOCK_SIZE
        $rng.NextBytes($tempBuf)
        [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $BLOCK_SIZE)

        $result = @{ readMbps = 0; writeMbps = 0 }

        if ($op -eq "write" -or $op -eq "both") {
            $accessFlags = $GENERIC_WRITE
            $flags = [uint32]($FILE_FLAG_NO_BUFFERING)
            $handle = [TestDeckWin32]::CreateFile($filePath, $accessFlags, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, $flags, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                return @{ error = "CreateFile failed (err=$err): $filePath" }
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $written = [long]0
            while ($written -lt $sizeBytes) {
                $bytesWritten = [uint32]0
                $ok = [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$BLOCK_SIZE, [ref]$bytesWritten, [IntPtr]::Zero)
                if (-not $ok) {
                    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    $handle.Close()
                    Remove-AlignedBuffer $buf
                    # Fallback to cached I/O
                    Write-Host "Seq write failed (err=$err), trying cached I/O" -ForegroundColor Yellow
                    $handle2 = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None)
                    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
                    $handle2.Write($tempBuf, 0, $BLOCK_SIZE)
                    $totalW = [long]$BLOCK_SIZE
                    while ($totalW -lt $sizeBytes) {
                        $handle2.Write($tempBuf, 0, $BLOCK_SIZE)
                        $totalW += $BLOCK_SIZE
                    }
                    $handle2.Flush()
                    $handle2.Close()
                    $sw2.Stop()
                    $result.writeMbps = [math]::Round($totalW / 1MB / $sw2.Elapsed.TotalSeconds, 1)
                    break
                }
                $written += $bytesWritten
            }
            [TestDeckWin32]::FlushFileBuffers($handle)
            $sw.Stop()
            $handle.Close()
            if ($result.writeMbps -eq 0) {
                $result.writeMbps = [math]::Round($written / 1MB / $sw.Elapsed.TotalSeconds, 1)
            }
        }

        if ($op -eq "read" -or $op -eq "both") {
            # Flush disk cache
            [System.GC]::Collect()
            Start-Sleep -Milliseconds 200

            $accessFlags = $GENERIC_READ
            $flags = [uint32]($FILE_FLAG_NO_BUFFERING)
            $handle = [TestDeckWin32]::CreateFile($filePath, $accessFlags, $FILE_SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, $flags, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                return @{ error = "CreateFile for read failed (err=$err): $filePath" }
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $read = [long]0
            while ($read -lt $sizeBytes) {
                $bytesRead = [uint32]0
                $ok = [TestDeckWin32]::ReadFile($handle, $buf.AlignedPtr, [uint32]$BLOCK_SIZE, [ref]$bytesRead, [IntPtr]::Zero)
                if (-not $ok -or $bytesRead -eq 0) {
                    if ($read -eq 0) {
                        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        $handle.Close()
                        Remove-AlignedBuffer $buf
                        # Fallback
                        Write-Host "Seq read failed (err=$err), trying cached I/O" -ForegroundColor Yellow
                        $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::None)
                        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
                        $totalR = [long]0
                        $rbuf = New-Object byte[] $BLOCK_SIZE
                        while ($true) {
                            $n = $fs.Read($rbuf, 0, $BLOCK_SIZE)
                            if ($n -eq 0) { break }
                            $totalR += $n
                        }
                        $fs.Close()
                        $sw2.Stop()
                        $result.readMbps = [math]::Round($totalR / 1MB / $sw2.Elapsed.TotalSeconds, 1)
                        Remove-AlignedBuffer $buf
                        return $result
                    }
                    break
                }
                $read += $bytesRead
            }
            $sw.Stop()
            $handle.Close()
            $result.readMbps = [math]::Round($read / 1MB / $sw.Elapsed.TotalSeconds, 1)
        }

        Remove-AlignedBuffer $buf
        return $result
    } catch {
        return @{ error = "SeqBench exception: $($_.Exception.Message)" }
    }
}

function Run-RndBench($driveLetter, $op, $seconds, $sizeMB) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $filePath = Join-Path $folder "testdeck.rnd.tmp"
    $blockSize = 4096
    $totalBlocks = [math]::Max(256, $sizeMB * 256)  # At least 1MB of random positions

    try {
        $buf = New-AlignedBuffer $blockSize
        $rng = New-Object System.Random(123)
        $tempBuf = New-Object byte[] $blockSize
        $rng.NextBytes($tempBuf)
        [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $blockSize)

        $result = @{ readIops = 0; writeIops = 0; readMbps = 0; writeMbps = 0 }

        # Pre-fill file for read test
        if ($op -eq "read" -or $op -eq "both") {
            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if (-not $handle.IsInvalid) {
                for ($i = 0; $i -lt $totalBlocks; $i++) {
                    $bw = [uint32]0
                    [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$blockSize, [ref]$bw, [IntPtr]::Zero) | Out-Null
                }
                [TestDeckWin32]::FlushFileBuffers($handle)
                $handle.Close()
            }
        }

        if ($op -eq "write" -or $op -eq "both") {
            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                return @{ error = "CreateFile rnd write failed (err=$err): $filePath" }
            }
            $fileSize = [long]$totalBlocks * $blockSize
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ops = 0
            while ($sw.Elapsed.TotalSeconds -lt $seconds) {
                $offset = [long]($rng.NextDouble() * ($fileSize - $blockSize))
                $offset = ($offset / $blockSize) * $blockSize  # Align
                [TestDeckWin32]::SetFilePointerEx($handle, $offset, [IntPtr]::Zero, $FILE_BEGIN) | Out-Null
                $bw = [uint32]0
                [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$blockSize, [ref]$bw, [IntPtr]::Zero) | Out-Null
                $ops++
            }
            $sw.Stop()
            $handle.Close()
            $result.writeIops = [math]::Round($ops / $sw.Elapsed.TotalSeconds, 0)
            $result.writeMbps = [math]::Round($ops * $blockSize / 1MB / $sw.Elapsed.TotalSeconds, 2)
        }

        if ($op -eq "read" -or $op -eq "both") {
            [System.GC]::Collect()
            Start-Sleep -Milliseconds 200
            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_READ, $FILE_SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                return @{ error = "CreateFile rnd read failed (err=$err): $filePath" }
            }
            $fileSize = [long]$totalBlocks * $blockSize
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $ops = 0
            while ($sw.Elapsed.TotalSeconds -lt $seconds) {
                $offset = [long]($rng.NextDouble() * ($fileSize - $blockSize))
                $offset = ($offset / $blockSize) * $blockSize
                [TestDeckWin32]::SetFilePointerEx($handle, $offset, [IntPtr]::Zero, $FILE_BEGIN) | Out-Null
                $br = [uint32]0
                [TestDeckWin32]::ReadFile($handle, $buf.AlignedPtr, [uint32]$blockSize, [ref]$br, [IntPtr]::Zero) | Out-Null
                $ops++
            }
            $sw.Stop()
            $handle.Close()
            $result.readIops = [math]::Round($ops / $sw.Elapsed.TotalSeconds, 0)
            $result.readMbps = [math]::Round($ops * $blockSize / 1MB / $sw.Elapsed.TotalSeconds, 2)
        }

        Remove-AlignedBuffer $buf
        return $result
    } catch {
        return @{ error = "RndBench exception: $($_.Exception.Message)" }
    }
}

function Run-QdBench($driveLetter, $kind, $q, $seconds, $op) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $fileName = "testdeck.qd.tmp"
    $filePath = Join-Path $folder $fileName
    $blockSize = if ($kind -eq "seq") { $BLOCK_SIZE } else { 4096 }
    $fileBlocks = [math]::Max($q * 2, 256)
    $fileSize = [long]$fileBlocks * $blockSize

    try {
        # Pre-fill for read
        if ($op -eq "read" -or $op -eq "both") {
            $buf = New-AlignedBuffer $blockSize
            $rng = New-Object System.Random(77)
            $tempBuf = New-Object byte[] $blockSize
            $rng.NextBytes($tempBuf)
            [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $blockSize)

            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if (-not $handle.IsInvalid) {
                for ($i = 0; $i -lt $fileBlocks; $i++) {
                    $bw = [uint32]0
                    [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$blockSize, [ref]$bw, [IntPtr]::Zero) | Out-Null
                }
                [TestDeckWin32]::FlushFileBuffers($handle)
                $handle.Close()
            }
            Remove-AlignedBuffer $buf
        }

        $result = @{ iops = 0; mbps = 0 }

        # Create overlapped events
        $events = New-Object IntPtr[] $q
        $overlappeds = New-Object IntPtr[] $q
        $buffers = @()
        for ($i = 0; $i -lt $q; $i++) {
            $events[$i] = [TestDeckWin32]::CreateEvent([IntPtr]::Zero, $true, $false, $null)
            $ovlp = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf([Type][TestDeckWin32+OVERLAPPED]))
            $overlappeds[$i] = $ovlp
            $buffers += (New-AlignedBuffer $blockSize)
            if ($op -ne "read") {
                $rng = New-Object System.Random(50 + $i)
                $tb = New-Object byte[] $blockSize
                $rng.NextBytes($tb)
                [System.Runtime.InteropServices.Marshal]::Copy($tb, 0, $buffers[$i].AlignedPtr, $blockSize)
            }
        }

        $accessFlags = if ($op -eq "read") { $GENERIC_READ } else { $GENERIC_WRITE }
        $createDisp = if ($op -eq "read") { $OPEN_EXISTING } else { $CREATE_ALWAYS }
        $flags = [uint32]($FILE_FLAG_NO_BUFFERING + $FILE_FLAG_OVERLAPPED_VAL)
        $handle = [TestDeckWin32]::CreateFile($filePath, $accessFlags, $FILE_SHARE_RW, [IntPtr]::Zero, $createDisp, $flags, [IntPtr]::Zero)
        if ($handle.IsInvalid) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            for ($i = 0; $i -lt $q; $i++) {
                [TestDeckWin32]::CloseHandle($events[$i]) | Out-Null
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($overlappeds[$i])
                Remove-AlignedBuffer $buffers[$i]
            }
            return @{ error = "CreateFile QD failed (err=$err): $filePath" }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $totalOps = [long]0

        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            # Submit Q operations
            $pending = 0
            for ($i = 0; $i -lt $q; $i++) {
                [TestDeckWin32]::ResetEvent($events[$i]) | Out-Null
                # Set offset in OVERLAPPED struct
                $slotOffset = [long](($totalOps + $i) % $fileBlocks) * $blockSize
                [System.Runtime.InteropServices.Marshal]::WriteInt32($overlappeds[$i], 8, [int]($slotOffset -band 0xFFFFFFFF))
                [System.Runtime.InteropServices.Marshal]::WriteInt32($overlappeds[$i], 12, [int](($slotOffset -shr 32) -band 0xFFFFFFFF))
                [System.Runtime.InteropServices.Marshal]::WriteIntPtr($overlappeds[$i], 16, $events[$i])

                $ioResult = [uint32]0
                if ($op -eq "read") {
                    $ok = [TestDeckWin32]::ReadFile($handle, $buffers[$i].AlignedPtr, [uint32]$blockSize, [ref]$ioResult, $overlappeds[$i])
                } else {
                    $ok = [TestDeckWin32]::WriteFile($handle, $buffers[$i].AlignedPtr, [uint32]$blockSize, [ref]$ioResult, $overlappeds[$i])
                }
                if (-not $ok) {
                    $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    if ($lastErr -eq 997) { $pending++ }  # ERROR_IO_PENDING
                } else {
                    $pending++
                    $totalOps++
                }
            }

            # Wait for completions
            if ($pending -gt 0) {
                $waitResult = [TestDeckWin32]::WaitForMultipleObjects([uint32]$q, $events, $false, [uint32]5000)
                for ($i = 0; $i -lt $q; $i++) {
                    $transferred = [uint32]0
                    [TestDeckWin32]::GetOverlappedResult($handle, $overlappeds[$i], [ref]$transferred, $false) | Out-Null
                    if ($transferred -gt 0) { $totalOps++ }
                }
            }
        }

        $sw.Stop()
        $handle.Close()

        for ($i = 0; $i -lt $q; $i++) {
            [TestDeckWin32]::CloseHandle($events[$i]) | Out-Null
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($overlappeds[$i])
            Remove-AlignedBuffer $buffers[$i]
        }

        $result.iops = [math]::Round($totalOps / $sw.Elapsed.TotalSeconds, 0)
        $result.mbps = [math]::Round($totalOps * $blockSize / 1MB / $sw.Elapsed.TotalSeconds, 2)
        return $result
    } catch {
        return @{ error = "QdBench exception: $($_.Exception.Message)" }
    }
}

function Run-MixBench($driveLetter, $seconds, $sizeMB) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $filePath = Join-Path $folder "testdeck.mix.tmp"
    $blockSize = 4096
    $q = 8
    $fileBlocks = [math]::Max(512, $sizeMB * 256)
    $fileSize = [long]$fileBlocks * $blockSize

    try {
        # Pre-fill
        $buf = New-AlignedBuffer $blockSize
        $rng = New-Object System.Random(99)
        $tempBuf = New-Object byte[] $blockSize
        $rng.NextBytes($tempBuf)
        [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $blockSize)

        $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
        if (-not $handle.IsInvalid) {
            for ($i = 0; $i -lt $fileBlocks; $i++) {
                $bw = [uint32]0
                [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$blockSize, [ref]$bw, [IntPtr]::Zero) | Out-Null
            }
            [TestDeckWin32]::FlushFileBuffers($handle)
            $handle.Close()
        }
        Remove-AlignedBuffer $buf

        # 70/30 mixed read/write with overlapped I/O
        $events = New-Object IntPtr[] $q
        $buffers = @()
        for ($i = 0; $i -lt $q; $i++) {
            $events[$i] = [TestDeckWin32]::CreateEvent([IntPtr]::Zero, $true, $false, $null)
            $buffers += (New-AlignedBuffer $blockSize)
        }

        $handle = [TestDeckWin32]::CreateFile($filePath, [uint32]($GENERIC_READ + $GENERIC_WRITE), $FILE_SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, [uint32]($FILE_FLAG_NO_BUFFERING + $FILE_FLAG_OVERLAPPED_VAL), [IntPtr]::Zero)
        if ($handle.IsInvalid) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            for ($i = 0; $i -lt $q; $i++) {
                [TestDeckWin32]::CloseHandle($events[$i]) | Out-Null
                Remove-AlignedBuffer $buffers[$i]
            }
            return @{ error = "CreateFile mix failed (err=$err): $filePath" }
        }

        $rng = New-Object System.Random(55)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $readOps = [long]0
        $writeOps = [long]0

        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            for ($i = 0; $i -lt $q; $i++) {
                [TestDeckWin32]::ResetEvent($events[$i]) | Out-Null
                $offset = [long]($rng.NextDouble() * ($fileSize - $blockSize))
                $offset = ($offset / $blockSize) * $blockSize

                $ovlp = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(32)
                [System.Runtime.InteropServices.Marshal]::WriteInt32($ovlp, 0, 0)
                [System.Runtime.InteropServices.Marshal]::WriteInt32($ovlp, 4, 0)
                [System.Runtime.InteropServices.Marshal]::WriteInt32($ovlp, 8, [int]($offset -band 0xFFFFFFFF))
                [System.Runtime.InteropServices.Marshal]::WriteInt32($ovlp, 12, [int](($offset -shr 32) -band 0xFFFFFFFF))
                [System.Runtime.InteropServices.Marshal]::WriteIntPtr($ovlp, 16, $events[$i])

                $isRead = ($rng.NextDouble() -lt 0.7)
                $ioResult = [uint32]0
                if ($isRead) {
                    [TestDeckWin32]::ReadFile($handle, $buffers[$i].AlignedPtr, [uint32]$blockSize, [ref]$ioResult, $ovlp) | Out-Null
                } else {
                    [TestDeckWin32]::WriteFile($handle, $buffers[$i].AlignedPtr, [uint32]$blockSize, [ref]$ioResult, $ovlp) | Out-Null
                }
                [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ovlp)

                if ($isRead) { $readOps++ } else { $writeOps++ }
            }
            [TestDeckWin32]::WaitForMultipleObjects([uint32]$q, $events, $true, [uint32]3000) | Out-Null
        }

        $sw.Stop()
        $handle.Close()

        for ($i = 0; $i -lt $q; $i++) {
            [TestDeckWin32]::CloseHandle($events[$i]) | Out-Null
            Remove-AlignedBuffer $buffers[$i]
        }

        $elapsed = $sw.Elapsed.TotalSeconds
        return @{
            readMbps = [math]::Round($readOps * $blockSize / 1MB / $elapsed, 2)
            writeMbps = [math]::Round($writeOps * $blockSize / 1MB / $elapsed, 2)
            readIops = [math]::Round($readOps / $elapsed, 0)
            writeIops = [math]::Round($writeOps / $elapsed, 0)
        }
    } catch {
        return @{ error = "MixBench exception: $($_.Exception.Message)" }
    }
}

function Run-SustainedBench($driveLetter, $sizeMB, $percent) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $filePath = Join-Path $folder "testdeck.sus.tmp"

    if ($percent -gt 0) {
        try {
            $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
            $totalGB = $vol.Size / 1GB
            $sizeMB = [math]::Max(64, [math]::Floor($totalGB * $percent / 100 * 1024))
        } catch {
            $sizeMB = [math]::Max(64, $sizeMB)
        }
    }

    try {
        $buf = New-AlignedBuffer $BLOCK_SIZE
        $rng = New-Object System.Random(33)
        $tempBuf = New-Object byte[] $BLOCK_SIZE
        $rng.NextBytes($tempBuf)
        [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $BLOCK_SIZE)

        $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, $CREATE_ALWAYS, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
        if ($handle.IsInvalid) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Remove-AlignedBuffer $buf
            return @{ error = "CreateFile sustained failed (err=$err): $filePath" }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $series = [System.Collections.ArrayList]@()
        $written = [long]0
        $targetBytes = [long]$sizeMB * $BLOCK_SIZE
        $lastTempTime = [DateTime]::MinValue
        $tempC = $null
        $windowMbps = [System.Collections.ArrayList]@()

        while ($written -lt $targetBytes) {
            $bw = [uint32]0
            $ok = [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$BLOCK_SIZE, [ref]$bw, [IntPtr]::Zero)
            if (-not $ok) { break }
            $written += $bw

            $elapsed = $sw.Elapsed.TotalSeconds
            $currentMbps = $written / 1MB / $elapsed

            # Sample temp every 2s
            if (((Get-Date) - $lastTempTime).TotalSeconds -ge 2) {
                try {
                    $disks = Get-Disk -ErrorAction SilentlyContinue
                    foreach ($d in $disks) {
                        $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
                        foreach ($p in $parts) {
                            if ($p.DriveLetter -eq $driveLetter) {
                                $rc = Get-StorageReliabilityCounter -Disk $d -ErrorAction SilentlyContinue
                                if ($null -ne $rc) { $tempC = $rc.Temperature }
                                break
                            }
                        }
                    }
                } catch {}
                $lastTempTime = Get-Date
            }

            [void]$series.Add(@{
                s = [math]::Round($elapsed, 1)
                mbps = [math]::Round($currentMbps, 1)
                temp = $tempC
                cum = [math]::Round($written / 1MB, 0)
            })

            [void]$windowMbps.Add($currentMbps)
            if ($windowMbps.Count -gt 10) { $windowMbps.RemoveAt(0) }
        }

        $sw.Stop()
        [TestDeckWin32]::FlushFileBuffers($handle)
        $handle.Close()
        Remove-AlignedBuffer $buf

        # Calculate SLC cache knee
        $cacheMB = 0
        $headAvg = 0
        $headCount = [math]::Min(10, $series.Count)
        for ($i = 0; $i -lt $headCount; $i++) { $headAvg += $series[$i].mbps }
        $headAvg = $headAvg / $headCount

        $maxTemp = 0
        foreach ($pt in $series) {
            if ($null -ne $pt.temp -and $pt.temp -gt $maxTemp) { $maxTemp = $pt.temp }
        }

        for ($i = $headCount; $i -lt $series.Count; $i++) {
            if ($series[$i].mbps -lt ($headAvg * 0.65)) {
                $cacheMB = $series[$i].cum
                break
            }
        }

        # Tail average (after cache)
        $tailStart = if ($cacheMB -gt 0) { 
            $idx = 0
            for ($i = 0; $i -lt $series.Count; $i++) { if ($series[$i].cum -ge $cacheMB) { $idx = $i; break } }
            $idx
        } else { 0 }
        $tailAvg = 0
        $tailCount = 0
        for ($i = $tailStart; $i -lt $series.Count; $i++) {
            $tailAvg += $series[$i].mbps
            $tailCount++
        }
        if ($tailCount -gt 0) { $tailAvg = $tailAvg / $tailCount }

        # Downsample to <=720 points
        $downsampled = [System.Collections.ArrayList]@()
        $step = [math]::Max(1, [math]::Floor($series.Count / 720))
        for ($i = 0; $i -lt $series.Count; $i += $step) {
            [void]$downsampled.Add($series[$i])
        }

        return @{
            cacheMB = $cacheMB
            sustainedMbps = [math]::Round($tailAvg, 1)
            maxTemp = $maxTemp
            sizeMB = $sizeMB
            series = $downsampled
        }
    } catch {
        return @{ error = "SustainedBench exception: $($_.Exception.Message)" }
    }
}

function Run-VerifyBench($driveLetter, $sizeMB) {
    $folder = Get-WritableFolder $driveLetter
    if ($null -eq $folder) { return @{ error = "No writable folder on $driveLetter" } }
    $filePath = Join-Path $folder "testdeck.vfy.tmp"

    try {
        $buf = New-AlignedBuffer $BLOCK_SIZE
        $readBuf = New-AlignedBuffer $BLOCK_SIZE
        $badBlocks = 0
        $firstBadMB = -1
        $testedMB = 0
        $magic = [byte[]]@(0x54, 0x44, 0x56, 0x46)  # "TDVF"

        for ($block = 0; $block -lt $sizeMB; $block++) {
            # Generate seeded pattern
            $seed = $block * 7919 + 42
            $rng = New-Object System.Random($seed)
            $tempBuf = New-Object byte[] $BLOCK_SIZE
            $rng.NextBytes($tempBuf)
            # Add magic header
            [Array]::Copy($magic, 0, $tempBuf, 0, 4)
            # Add block number
            $blockBytes = [BitConverter]::GetBytes($block)
            [Array]::Copy($blockBytes, 0, $tempBuf, 4, 4)

            [System.Runtime.InteropServices.Marshal]::Copy($tempBuf, 0, $buf.AlignedPtr, $BLOCK_SIZE)

            # Write
            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_WRITE, $FILE_SHARE_RW, [IntPtr]::Zero, 
                $(if ($block -eq 0) { $CREATE_ALWAYS } else { $OPEN_EXISTING }), [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                Remove-AlignedBuffer $readBuf
                return @{ error = "CreateFile verify write failed (err=$err): $filePath" }
            }
            [TestDeckWin32]::SetFilePointerEx($handle, ([long]$block * $BLOCK_SIZE), [IntPtr]::Zero, $FILE_BEGIN) | Out-Null
            $bw = [uint32]0
            [TestDeckWin32]::WriteFile($handle, $buf.AlignedPtr, [uint32]$BLOCK_SIZE, [ref]$bw, [IntPtr]::Zero) | Out-Null
            [TestDeckWin32]::FlushFileBuffers($handle) | Out-Null
            $handle.Close()

            # Read back
            $handle = [TestDeckWin32]::CreateFile($filePath, $GENERIC_READ, $FILE_SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, [uint32]$FILE_FLAG_NO_BUFFERING, [IntPtr]::Zero)
            if ($handle.IsInvalid) {
                $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                Remove-AlignedBuffer $buf
                Remove-AlignedBuffer $readBuf
                return @{ error = "CreateFile verify read failed (err=$err): $filePath" }
            }
            [TestDeckWin32]::SetFilePointerEx($handle, ([long]$block * $BLOCK_SIZE), [IntPtr]::Zero, $FILE_BEGIN) | Out-Null
            $br = [uint32]0
            [TestDeckWin32]::ReadFile($handle, $readBuf.AlignedPtr, [uint32]$BLOCK_SIZE, [ref]$br, [IntPtr]::Zero) | Out-Null
            $handle.Close()

            # Compare
            $readBack = New-Object byte[] $BLOCK_SIZE
            [System.Runtime.InteropServices.Marshal]::Copy($readBuf.AlignedPtr, $readBack, 0, $BLOCK_SIZE)
            $match = $true
            for ($j = 0; $j -lt [math]::Min(64, $BLOCK_SIZE); $j++) {
                if ($tempBuf[$j] -ne $readBack[$j]) { $match = $false; break }
            }
            if (-not $match) {
                $badBlocks++
                if ($firstBadMB -eq -1) { $firstBadMB = $block }
            }
            $testedMB++
        }

        Remove-AlignedBuffer $buf
        Remove-AlignedBuffer $readBuf

        return @{
            testedMB = $testedMB
            badBlocks = $badBlocks
            firstBadMB = $firstBadMB
        }
    } catch {
        return @{ error = "VerifyBench exception: $($_.Exception.Message)" }
    }
}

function Run-Cleanup() {
    $drives = Get-DriveInventory
    foreach ($d in $drives) {
        foreach ($letter in $d.letters) {
            $folder = Get-WritableFolder $letter
            if ($null -ne $folder) {
                $files = @("testdeck.seq.tmp", "testdeck.rnd.tmp", "testdeck.qd.tmp", "testdeck.sus.tmp", "testdeck.vfy.tmp", "testdeck.mix.tmp")
                foreach ($f in $files) {
                    $fp = Join-Path $folder $f
                    try { Remove-Item $fp -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
    }
    return @{ ok = $true }
}

# --- HTTP Handling ---
function Send-ProbeResponse($stream, $statusCode, $statusText, $obj) {
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $header = "HTTP/1.1 $statusCode $statusText`r`n"
    $header += "Content-Type: application/json`r`n"
    $header += "Content-Length: $($bytes.Length)`r`n"
    $header += "Access-Control-Allow-Origin: *`r`n"
    $header += "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n"
    $header += "Access-Control-Allow-Headers: Content-Type`r`n"
    $header += "Connection: close`r`n"
    $header += "`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($headerBytes, 0, $headerBytes.Length)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Handle-ProbeRequest($stream, $method, $path, $body) {
    if ($method -eq "OPTIONS") {
        $header = "HTTP/1.1 200 OK`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: Content-Type`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Flush()
        return
    }

    if ($path -eq "/ping" -and $method -eq "GET") {
        Send-ProbeResponse $stream 200 "OK" @{ status = "ok"; time = (Get-Date -Format "o") }
        return
    }
    if ($path -eq "/drives" -and $method -eq "GET") {
        $drives = Get-DriveInventory
        Send-ProbeResponse $stream 200 "OK" $drives
        return
    }
    if ($path -eq "/bench/seq" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-SeqBench $data.drive $data.op $data.sizeMB
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/rnd" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-RndBench $data.drive $data.op $data.seconds $data.sizeMB
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/qd" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-QdBench $data.drive $data.kind $data.q $data.seconds $data.op
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/mix" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-MixBench $data.drive $data.seconds $data.sizeMB
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/sustained" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-SustainedBench $data.drive $data.sizeMB $data.percent
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/verify" -and $method -eq "POST") {
        $data = $body | ConvertFrom-Json
        $result = Run-VerifyBench $data.drive $data.sizeMB
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/bench/cleanup" -and $method -eq "POST") {
        $result = Run-Cleanup
        Send-ProbeResponse $stream 200 "OK" $result
        return
    }
    if ($path -eq "/stop" -and $method -eq "POST") {
        Send-ProbeResponse $stream 200 "OK" @{ ok = $true; message = "Stopping" }
        $script:StopRequested = $true
        return
    }

    $errJson = @{ error = "Not found: $method $path" } | ConvertTo-Json -Compress
    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
    $header = "HTTP/1.1 404 Not Found`r`nContent-Type: application/json`r`nContent-Length: $($errBytes.Length)`r`nAccess-Control-Allow-Origin: *`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb, 0, $hb.Length)
    $stream.Write($errBytes, 0, $errBytes.Length)
    $stream.Flush()
}

# --- Main Probe Loop ---
$script:StopRequested = $false

Write-Host "Warming up drive inventory..." -ForegroundColor Cyan
$null = Get-DriveInventory
Write-Host "Drive inventory cached." -ForegroundColor Green

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $ProbePort)
$listener.Start()
Write-Host "TestDeck Probe running on http://127.0.0.1:$ProbePort" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray

try {
    while (-not $script:StopRequested) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 100
            continue
        }
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 300000  # 5 min for benchmarks

        try {
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)

            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) { $client.Close(); continue }
            $parts = $requestLine -split " "
            $method = $parts[0]
            $path = $parts[1]

            $headers = @{}
            while ($true) {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) { break }
                $colonIdx = $line.IndexOf(":")
                if ($colonIdx -gt 0) {
                    $headers[$line.Substring(0, $colonIdx).Trim()] = $line.Substring($colonIdx + 1).Trim()
                }
            }

            $body = ""
            if ($headers.ContainsKey("Content-Length")) {
                $contentLen = 0
                [int]::TryParse($headers["Content-Length"], [ref]$contentLen) | Out-Null
                if ($contentLen -gt 0 -and $contentLen -lt 1048576) {
                    $bodyBuf = New-Object char[] $contentLen
                    $totalRead = 0
                    while ($totalRead -lt $contentLen) {
                        $read = $reader.Read($bodyBuf, $totalRead, $contentLen - $totalRead)
                        if ($read -eq 0) { break }
                        $totalRead += $read
                    }
                    $body = New-Object string($bodyBuf, 0, $totalRead)
                }
            }

            # Don't dispose reader - it would close the underlying stream!
            # The reader will be cleaned up when client.Close() is called

            # Extend timeout for benchmark requests
            if ($path -match "/bench/") {
                $client.ReceiveTimeout = 600000  # 10 min
                $client.SendTimeout = 600000
            }

            Handle-ProbeRequest $stream $method $path $body
        } catch [System.IO.IOException] {
            # Client disconnected
        } catch {
            Write-Host "Probe error: $_" -ForegroundColor Red
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
    Write-Host "Probe stopped." -ForegroundColor Yellow
}
