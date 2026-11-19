# run_tb_xsim.ps1 - compile and run each Task 10 testbench with the Vivado
# 2017.4 command-line simulator (xvlog / xelab / xsim), outside the project.
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\run_tb_xsim.ps1 [tb_name ...]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Only)

$root  = Split-Path -Parent $PSScriptRoot
$bin   = "C:\Xilinx\Vivado\2017.4\bin"
$hdl   = Join-Path $root "HDL_Incomplete"
$tbdir = Join-Path $root "tb"
$work  = Join-Path $root "sim_out"
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work

# module under test -> source files it needs
$tbs = [ordered]@{
    tb_vga_timing      = @("vga_timing.v")
    tb_button_debounce = @("buttons.v")
    tb_ps2_rx          = @("ps2_rx.v")
    tb_kbd_state       = @("kbd_state.v")
    tb_ge_collide      = @("ge_units.v")
    tb_ge_boundary     = @("ge_units.v")
    tb_ge_split        = @("ge_units.v")
    tb_binary2bcd      = @("binary2bcd.v")
    tb_hud_digits      = @("vga_render.v", "binary2bcd.v")
}
if ($Only) { $sel = $Only } else { $sel = $tbs.Keys }

$summary = @()
foreach ($tb in $sel) {
    Write-Output "=================== $tb ==================="
    $srcs = @($tbs[$tb] | ForEach-Object { Join-Path $hdl $_ }) + (Join-Path $tbdir "$tb.v")
    & "$bin\xvlog.bat" -nolog -i $hdl @srcs | Select-String -Pattern "ERROR|WARNING" | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { $summary += "${tb}: COMPILE ERROR"; continue }
    & "$bin\xelab.bat" -nolog -debug off -s "${tb}_snap" "work.$tb" | Select-String -Pattern "ERROR|WARNING" | ForEach-Object { $_.Line }
    if ($LASTEXITCODE -ne 0) { $summary += "${tb}: ELABORATION ERROR"; continue }
    $out = & "$bin\xsim.bat" -nolog "${tb}_snap" -R
    $out | Where-Object { $_ -match "MISMATCH|PASS|FAIL|ERROR|received|rejected|seen|longest" } | Select-Object -First 40
    $res = $out | Where-Object { $_ -match "^${tb}: (PASS|FAIL)" } | Select-Object -Last 1
    if (-not $res) { $res = "${tb}: no PASS/FAIL line" }
    $summary += $res
    $out | Out-File -Encoding utf8 (Join-Path $work "$tb.log")
}
Write-Output ""
Write-Output "==================== SUMMARY ===================="
$summary
