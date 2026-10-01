$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dllPath = 'C:\dev\V340L-Emancipated\scratch\antigravity-publisher-20261001\Antigravity.ProducerPublisher.dll'
$bytes = [IO.File]::ReadAllBytes($dllPath)
$asm = [Reflection.Assembly]::Load($bytes)
$type = $asm.GetType('Antigravity.ProducerPublisher', $true)

Write-Host "Assembly loaded: $($asm.FullName)" -ForegroundColor Cyan
Write-Host "Type: $($type.FullName)" -ForegroundColor Cyan

# Test ExtractTensorBuffer on a synthetic tensor layout
# Tensor layout in stock:
# offset 0x08: buffer (IntPtr)
# offset 0x60 of buffer: context (IntPtr)
# offset 0x10 of context: dev_buffer (IntPtr)
# offset 0x00 of dev_buffer: VkBuffer (ulong)
# offset 0xE8: view_src (IntPtr)
# offset 0xF0: view_offs (long)
# offset 0xF8: data (IntPtr)

$memTensor = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
$memBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(256)
$memContext = [Runtime.InteropServices.Marshal]::AllocHGlobal(256)
$memDevBuffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(256)
$outBuf = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)
$outOff = [Runtime.InteropServices.Marshal]::AllocHGlobal(8)

try {
    # Zero all
    for ($i = 0; $i -lt 512; $i += 8) { [Runtime.InteropServices.Marshal]::WriteInt64($memTensor, $i, 0) }
    for ($i = 0; $i -lt 256; $i += 8) { [Runtime.InteropServices.Marshal]::WriteInt64($memBuffer, $i, 0) }
    for ($i = 0; $i -lt 256; $i += 8) { [Runtime.InteropServices.Marshal]::WriteInt64($memContext, $i, 0) }
    for ($i = 0; $i -lt 256; $i += 8) { [Runtime.InteropServices.Marshal]::WriteInt64($memDevBuffer, $i, 0) }

    # Setup pointers
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memTensor, 0x08, $memBuffer)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memBuffer, 0x60, $memContext)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memContext, 0x10, $memDevBuffer)
    
    $expectedVkBuf = 0xABCD1234EF567890L
    [Runtime.InteropServices.Marshal]::WriteInt64($memDevBuffer, 0x00, $expectedVkBuf)

    # Direct (no view): data = 0x1400 (base = 0x1400 - 0x1000 = 0x400), view_offs = 0x20
    # Expected offset = 0x420
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memTensor, 0xE8, [IntPtr]::Zero)
    [Runtime.InteropServices.Marshal]::WriteInt64($memTensor, 0xF0, 0x20L)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memTensor, 0xF8, [IntPtr]::new(0x1400))

    $extractMethod = $type.GetMethod('ExtractTensorBuffer')
    $res = $extractMethod.Invoke($null, @($memTensor, $outBuf, $outOff))
    $actualVkBuf = [Runtime.InteropServices.Marshal]::ReadInt64($outBuf)
    $actualOff = [Runtime.InteropServices.Marshal]::ReadInt64($outOff)

    if ($res -ne 0 -or $actualVkBuf -ne $expectedVkBuf -or $actualOff -ne 0x420L) {
        throw "Direct tensor test failed: res=$res, vkBuf=0x$($actualVkBuf.ToString('X')), off=0x$($actualOff.ToString('X'))"
    }
    Write-Host "  [+] Direct tensor extract passed: VkBuffer=0x$($actualVkBuf.ToString('X')), Offset=0x$($actualOff.ToString('X'))" -ForegroundColor Green

    # View tensor: view_src points to base tensor with data = 0x2000 (base = 0x1000), view_offs = 0x100
    # Expected offset = 0x1100
    $memViewSrc = [Runtime.InteropServices.Marshal]::AllocHGlobal(512)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memViewSrc, 0xF8, [IntPtr]::new(0x2000))
    [Runtime.InteropServices.Marshal]::WriteIntPtr($memTensor, 0xE8, $memViewSrc)
    [Runtime.InteropServices.Marshal]::WriteInt64($memTensor, 0xF0, 0x100L)

    $res2 = $extractMethod.Invoke($null, @($memTensor, $outBuf, $outOff))
    $actualVkBuf2 = [Runtime.InteropServices.Marshal]::ReadInt64($outBuf)
    $actualOff2 = [Runtime.InteropServices.Marshal]::ReadInt64($outOff)

    if ($res2 -ne 0 -or $actualVkBuf2 -ne $expectedVkBuf -or $actualOff2 -ne 0x1100L) {
        throw "View tensor test failed: res=$res2, vkBuf=0x$($actualVkBuf2.ToString('X')), off=0x$($actualOff2.ToString('X'))"
    }
    Write-Host "  [+] View tensor extract passed: VkBuffer=0x$($actualVkBuf2.ToString('X')), Offset=0x$($actualOff2.ToString('X'))" -ForegroundColor Green

    [Runtime.InteropServices.Marshal]::FreeHGlobal($memViewSrc)
} finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($memTensor)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($memBuffer)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($memContext)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($memDevBuffer)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($outBuf)
    [Runtime.InteropServices.Marshal]::FreeHGlobal($outOff)
}
Write-Host "ALL ABI TESTS PASSED." -ForegroundColor Green
