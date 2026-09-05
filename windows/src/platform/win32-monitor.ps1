param([switch]$Once)

$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MicrocamWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);

    public static double IdleSeconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(info);
        if (!GetLastInputInfo(ref info)) return 0;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
    }
}
"@

while ($true) {
    try {
        $handle = [MicrocamWin32]::GetForegroundWindow()
        $processId = [uint32]0
        [void][MicrocamWin32]::GetWindowThreadProcessId($handle, [ref]$processId)
        $builder = [System.Text.StringBuilder]::new(2048)
        [void][MicrocamWin32]::GetWindowText($handle, $builder, $builder.Capacity)

        $process = Get-Process -Id $processId -ErrorAction Stop
        $executable = ($process.ProcessName + ".exe").ToLowerInvariant()
        $displayName = $process.ProcessName
        try {
            $description = $process.MainModule.FileVersionInfo.FileDescription
            if (-not [string]::IsNullOrWhiteSpace($description)) { $displayName = $description }
        } catch { }

        [ordered]@{
            executable = $executable
            appName = $displayName
            title = $builder.ToString()
            idleSeconds = [MicrocamWin32]::IdleSeconds()
            capturedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        } | ConvertTo-Json -Compress
        [Console]::Out.Flush()
    } catch {
        [ordered]@{
            unavailable = $true
            capturedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        } | ConvertTo-Json -Compress
        [Console]::Out.Flush()
    }
    if ($Once) { break }
    Start-Sleep -Seconds 2
}
