# Builds build\windows\JogScroll.exe (the tray app) and build\windows\jog-scroll.exe (the terminal
# commands) from this folder. Needs the .NET 8 SDK: winget install Microsoft.DotNet.SDK.8
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$out = Join-Path $PSScriptRoot '..\build\windows'

dotnet publish JogScroll.csproj -c Release -o $out --nologo
if ($LASTEXITCODE -ne 0) { throw 'Building JogScroll.exe failed' }

# The same project again as a console program, with its own obj folder so the two builds don't mix.
dotnet publish JogScroll.csproj -c Release -o $out --nologo `
    -p:OutputType=Exe -p:AssemblyName=jog-scroll -p:IntermediateOutputPath=obj\cli\
if ($LASTEXITCODE -ne 0) { throw 'Building jog-scroll.exe failed' }

Write-Output "Built $(Resolve-Path $out)"
