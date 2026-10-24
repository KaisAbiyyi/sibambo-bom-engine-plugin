param([string]$Mode,[string]$InputPath,[string]$OutputPath,[int]$Width,[int]$Height,[int]$Channels,[int]$Padding,[string]$Bgr,[string]$CachePath)
$ErrorActionPreference='Stop'
# Ruby can inherit a PowerShell7 module path; this process is Windows PS5.1.
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
$env:TEMP=Split-Path -Parent $InputPath
$env:TMP=$env:TEMP
$source=Join-Path $PSScriptRoot 'exact_png_worker.cs'
$sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
New-Item -ItemType Directory -Force -Path $CachePath | Out-Null
$key=$sourceHash+'-'+[Environment]::Version.ToString()
$record=Join-Path $CachePath ($key+'.json')
$assembly=$null
if(Test-Path -LiteralPath $record){
  $meta=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
  if($meta.name -match '^[a-f0-9-]+\.dll$'){
    $candidate=Join-Path $CachePath $meta.name
    if((Test-Path -LiteralPath $candidate) -and (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -eq $meta.sha){$assembly=$candidate}
  }
}
if(-not $assembly){
  $assembly=Join-Path $CachePath ([guid]::NewGuid().ToString()+'.dll')
  Add-Type -Path $source -OutputAssembly $assembly -ReferencedAssemblies System.dll,System.Core.dll,System.IO.Compression.dll
  @{name=(Split-Path -Leaf $assembly);sha=(Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash.ToLowerInvariant()}|ConvertTo-Json|Set-Content -LiteralPath $record -Encoding UTF8
}
Add-Type -Path $assembly
[SibamboExactPngWorker]::Run($Mode,$InputPath,$OutputPath,$Width,$Height,$Channels,$Padding,($Bgr -eq 'true'))
