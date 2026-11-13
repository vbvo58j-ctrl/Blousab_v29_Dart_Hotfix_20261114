# Single-command Windows source/build acceptance. Does not touch user data.
Set-Location $PSScriptRoot
$pass = 0; $fail = 0; $skip = 0
function Test-Step($label, $cmd, $argsList) {
    Write-Host "`n===== $label ====="
    & $cmd @argsList
    if ($LASTEXITCODE -eq 0) { Write-Host "PASS: $label"; $script:pass++ }
    else { Write-Host "FAIL: $label"; $script:fail++ }
}
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) { Write-Host 'FAIL: Python not found'; $fail++ }
else {
    Test-Step STATIC_SOURCE_AND_RESOURCES python @('scripts/check_static.py')
    Test-Step V26_SOURCE_CONTRACTS python @('scripts/check_v26_contracts.py')
    Test-Step V29_FEATURE_CONTRACTS python @('scripts/check_blousab_v29.py')
    Test-Step V29_COMPILE_REGRESSION_GUARDS python @('scripts/check_v29_compile_regressions.py')
    Test-Step PRODUCTION_SECURITY_GATE python @('scripts/check_production_security.py')
}
$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -eq $flutter) { Write-Host 'FAIL: Flutter SDK not found'; $fail++; $skip += 4 }
else {
    Test-Step FLUTTER_PUB_GET flutter @('pub','get')
    if ($fail -eq 0) {
        Test-Step FLUTTER_ANALYZE flutter @('analyze')
        Test-Step FLUTTER_TEST flutter @('test')
        Test-Step FLUTTER_BUILD_APK_DEBUG flutter @('build','apk','--debug')
    } else { Write-Host 'SKIP: compile until release blockers are resolved'; $skip += 3 }
}
Write-Host "`n========== ACCEPTANCE SUMMARY =========="
Write-Host "PASS=$pass FAIL=$fail SKIPPED=$skip"
if ($fail -gt 0) {
    Write-Host 'NOT VERIFIED FOR RELEASE.'
    if ([Environment]::UserInteractive) { Read-Host 'اضغط Enter لإغلاق الفحص' | Out-Null }
    exit 1
}
Write-Host 'All available checks passed.'
