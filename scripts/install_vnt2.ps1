#requires -Version 5.1
$ErrorActionPreference='Stop'
if($env:PROCESSOR_ARCHITECTURE -ne 'AMD64'){throw 'This installer is for Windows x64. Select the matching official release for other architectures.'}
$install=Join-Path $env:LOCALAPPDATA 'Programs\VNT\v2.0.11'
$cli=Join-Path $install 'vnt2_cli.exe';$ctrl=Join-Path $install 'vnt2_ctrl.exe';$dll=Join-Path $install 'wintun.dll'
if((Test-Path -LiteralPath $cli) -and (Test-Path -LiteralPath $ctrl) -and (Test-Path -LiteralPath $dll)){
    if((& $cli --version | Out-String) -match '2\.0\.11' -and (Get-AuthenticodeSignature -LiteralPath $dll).Status -eq 'Valid'){
        Write-Output 'Official VNT 2.0.11 and signed Wintun are already installed.';exit 0
    }
    throw 'An installation already exists but validation failed. Inspect it before replacement.'
}
if(Get-Process -Name vnt2_cli,vnt2_web -ErrorAction SilentlyContinue){throw 'Do not replace an active VNT installation.'}
$download=Join-Path $env:LOCALAPPDATA ('VNT2\downloads\'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $download -Force)
$archive=Join-Path $download 'vnt2.zip'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/vnt-dev/vnt/releases/download/v2.0.11/vnt2-x86_64-pc-windows-msvc-v2.0.11.zip' -OutFile $archive
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne 'D98D028B0B01ECB0EA740237ED9CA588223998BD40BDEDA6322A0352B86B06E1'){throw 'VNT release SHA256 mismatch.'}
Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $download 'client')
$bins=@(Get-ChildItem -LiteralPath (Join-Path $download 'client') -Recurse -Filter vnt2_cli.exe)
if($bins.Count -ne 1){throw 'Unexpected archive layout.'}
$source=$bins[0].DirectoryName
$oldDll=Join-Path $env:LOCALAPPDATA 'Programs\VNT\v1.2.16\wintun.dll'
if((Test-Path -LiteralPath $oldDll) -and (Get-AuthenticodeSignature -LiteralPath $oldDll).Status -eq 'Valid'){$driver=$oldDll}
else{
    $driverArchive=Join-Path $download 'wintun.zip'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://www.wintun.net/builds/wintun-0.14.1.zip' -OutFile $driverArchive
    Expand-Archive -LiteralPath $driverArchive -DestinationPath (Join-Path $download 'driver')
    $driver=Join-Path $download 'driver\wintun\bin\amd64\wintun.dll'
}
if((Get-AuthenticodeSignature -LiteralPath $driver).Status -ne 'Valid'){throw 'Wintun signature verification failed.'}
[void](New-Item -ItemType Directory -Path $install -Force)
Copy-Item -LiteralPath (Join-Path $source 'vnt2_cli.exe') -Destination $cli
Copy-Item -LiteralPath (Join-Path $source 'vnt2_ctrl.exe') -Destination $ctrl
Copy-Item -LiteralPath $driver -Destination $dll
& $cli --version
