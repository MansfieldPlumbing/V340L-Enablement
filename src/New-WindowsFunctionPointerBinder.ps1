[CmdletBinding()]
param()

if ($MyInvocation.InvocationName -eq '.') {
    throw 'New-WindowsFunctionPointerBinder.ps1 must be invoked with &, not dot-sourced.'
}

$Interop = & {
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
        [Reflection.AssemblyName]::new('QuickPS.WindowsInterop.' + [Guid]::NewGuid().ToString('N')),
        [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule('WindowsInterop')
    $types = [Collections.Generic.Dictionary[string, Type]]::new()
    $calls = [Collections.Generic.Dictionary[string, Delegate]]::new()
    $libraries = [Collections.Generic.Dictionary[string, IntPtr]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    $instance = [PSCustomObject]@{
        PSTypeName = 'QuickPS.WindowsInterop'
        Module = $module
        DelegateTypes = $types
        Calls = $calls
        Libraries = $libraries
    }

    $instance | Add-Member ScriptMethod LoadLibrary ({
        param([string] $Name)
        if (-not $this.Libraries.ContainsKey($Name)) {
            $this.Libraries[$Name] = [Runtime.InteropServices.NativeLibrary]::Load($Name)
        }
        $this.Libraries[$Name]
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod GetExport ({
        param([IntPtr] $Library, [string] $Name)
        [Runtime.InteropServices.NativeLibrary]::GetExport($Library, $Name)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod GetCall ({
        param([IntPtr] $Address, [Type] $ReturnType, [Type[]] $ParameterTypes)
        if ($Address -eq [IntPtr]::Zero) { throw 'Cannot bind a null native address.' }
        $signature = $ReturnType.FullName + ':' + (($ParameterTypes | ForEach-Object FullName) -join ',')
        if (-not $this.DelegateTypes.ContainsKey($signature)) {
            $builder = $this.Module.DefineType(
                'Call_' + [Guid]::NewGuid().ToString('N'),
                'Class,Public,Sealed',
                [MulticastDelegate])
            $constructor = $builder.DefineConstructor(
                'Public,HideBySig,RTSpecialName',
                [Reflection.CallingConventions]::Standard,
                @([object], [IntPtr]))
            $constructor.SetImplementationFlags('Runtime,Managed')
            $invoke = $builder.DefineMethod(
                'Invoke', 'Public,HideBySig,NewSlot,Virtual',
                $ReturnType, $ParameterTypes)
            $invoke.SetImplementationFlags('Runtime,Managed')
            $attribute = [Reflection.Emit.CustomAttributeBuilder]::new(
                [Runtime.InteropServices.UnmanagedFunctionPointerAttribute].GetConstructor(
                    @([Runtime.InteropServices.CallingConvention])),
                @([Runtime.InteropServices.CallingConvention]::StdCall))
            $builder.SetCustomAttribute($attribute)
            $this.DelegateTypes[$signature] = $builder.CreateType()
        }
        $key = $Address.ToInt64().ToString() + ':' + $signature
        if (-not $this.Calls.ContainsKey($key)) {
            $this.Calls[$key] = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer(
                $Address, $this.DelegateTypes[$signature])
        }
        $this.Calls[$key]
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod GetExportCall ({
        param([string] $Library, [string] $Name, [Type] $ReturnType, [Type[]] $ParameterTypes)
        $handle = $this.LoadLibrary($Library)
        $address = $this.GetExport($handle, $Name)
        $this.GetCall($address, $ReturnType, $ParameterTypes)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod GetComCall ({
        param([IntPtr] $Object, [int] $Slot, [Type] $ReturnType, [Type[]] $ParameterTypes)
        if ($Object -eq [IntPtr]::Zero) { throw 'Cannot bind a null COM interface.' }
        $vtable = [Runtime.InteropServices.Marshal]::ReadIntPtr($Object)
        $address = [Runtime.InteropServices.Marshal]::ReadIntPtr(
            $vtable, $Slot * [IntPtr]::Size)
        $this.GetCall($address, $ReturnType, (@([IntPtr]) + $ParameterTypes))
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod InvokeCom ({
        param(
            [IntPtr] $Object,
            [int] $Slot,
            [Type] $ReturnType,
            [Type[]] $ParameterTypes,
            [object[]] $Arguments
        )
        $call = $this.GetComCall($Object, $Slot, $ReturnType, $ParameterTypes)
        $invokeArguments = [object[]]::new(1 + $Arguments.Count)
        $invokeArguments[0] = [IntPtr]$Object
        for ($index = 0; $index -lt $Arguments.Count; $index++) {
            $argument = $Arguments[$index]
            if ($argument -is [Management.Automation.PSObject]) {
                $argument = $argument.BaseObject
            }
            $invokeArguments[$index + 1] = $argument
        }
        $call.DynamicInvoke($invokeArguments)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod Allocate ({
        param([int] $Bytes)
        if ($Bytes -lt 1) { throw 'Allocation size must be positive.' }
        $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Bytes)
        for ($index = 0; $index -lt $Bytes; $index++) {
            [Runtime.InteropServices.Marshal]::WriteByte($pointer, $index, 0)
        }
        $pointer
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod Free ({
        param([IntPtr] $Pointer)
        if ($Pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::FreeHGlobal($Pointer)
        }
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod NewBuffer ({
        param([int] $Bytes)
        if ($Bytes -lt 1) { throw 'Allocation size must be positive.' }
        [PSCustomObject]@{ Pointer = $this.Allocate($Bytes); Length = $Bytes }
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod FreeBuffer ({
        param($Buffer)
        if ($null -eq $Buffer) { return }
        $this.Free([IntPtr]$Buffer.Pointer)
        $Buffer.Pointer = [IntPtr]::Zero
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod CheckBufferRange ({
        param($Buffer, [int] $Offset, [int] $Width)
        if ($null -eq $Buffer -or $Buffer.Pointer -eq [IntPtr]::Zero -or
            $Offset -lt 0 -or $Width -lt 0 -or
            ([long]$Offset + $Width) -gt $Buffer.Length) {
            throw 'Native buffer access is out of bounds.'
        }
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod WriteUInt32 ({
        param($Buffer, [int] $Offset, [uint32] $Value)
        $this.CheckBufferRange($Buffer, $Offset, 4)
        [Runtime.InteropServices.Marshal]::WriteInt32($Buffer.Pointer, $Offset, [int]$Value)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod ReadUInt32 ({
        param($Buffer, [int] $Offset)
        $this.CheckBufferRange($Buffer, $Offset, 4)
        [uint32]([Runtime.InteropServices.Marshal]::ReadInt32($Buffer.Pointer, $Offset) -band 0xFFFFFFFFL)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod WriteUInt64 ({
        param($Buffer, [int] $Offset, [uint64] $Value)
        $this.CheckBufferRange($Buffer, $Offset, 8)
        [Runtime.InteropServices.Marshal]::WriteInt64($Buffer.Pointer, $Offset, [long]$Value)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod ReadUInt64 ({
        param($Buffer, [int] $Offset)
        $this.CheckBufferRange($Buffer, $Offset, 8)
        [System.BitConverter]::ToUInt64([System.BitConverter]::GetBytes([Runtime.InteropServices.Marshal]::ReadInt64($Buffer.Pointer, $Offset)), 0)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod WritePointer ({
        param($Buffer, [int] $Offset, [IntPtr] $Value)
        $this.CheckBufferRange($Buffer, $Offset, [IntPtr]::Size)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($Buffer.Pointer, $Offset, $Value)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod ReadPointer ({
        param($Buffer, [int] $Offset)
        $this.CheckBufferRange($Buffer, $Offset, [IntPtr]::Size)
        [Runtime.InteropServices.Marshal]::ReadIntPtr($Buffer.Pointer, $Offset)
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod ReleaseCom ({
        param([IntPtr] $Object)
        if ($Object -eq [IntPtr]::Zero) { return [uint32]0 }
        [uint32]$this.InvokeCom($Object, 2, ([uint32]), @(), @())
    }.GetNewClosure())

    $instance | Add-Member ScriptMethod Dispose ({
        foreach ($library in $this.Libraries.Values) {
            if ($library -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.NativeLibrary]::Free($library)
            }
        }
        $this.Libraries.Clear()
        $this.Calls.Clear()
        $this.DelegateTypes.Clear()
    }.GetNewClosure())

    $instance
}

$Interop
