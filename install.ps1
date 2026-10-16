# Installs smith on Windows from a release:
#
#   powershell -c "irm https://raw.githubusercontent.com/Arzaroth/smith/master/install.ps1 | iex"
#
# into %LOCALAPPDATA%\Programs\smith (the MSI's directory, or SMITH_INSTALL_DIR),
# added to the user PATH, after checking the archive against the release's
# SHA256SUMS. SMITH_VERSION picks a release (default: the latest).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Install-Smith {
    $repo = 'Arzaroth/smith'
    $web = if ($env:SMITH_INSTALL_URL) { $env:SMITH_INSTALL_URL } else { "https://github.com/$repo" }
    $installDir = [IO.Path]::GetFullPath($(if ($env:SMITH_INSTALL_DIR) { $env:SMITH_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\smith' }))

    $machine = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($machine) {
        'AMD64' { 'x86_64' }
        'ARM64' { 'x86_64' }
        default { throw "install: no release for $machine" }
    }

    $version = $env:SMITH_VERSION
    if (-not $version) {
        if ($env:SMITH_INSTALL_URL) { throw "install: set SMITH_VERSION along with SMITH_INSTALL_URL" }
        try {
            $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
        } catch {
            throw "install: cannot look up the latest release ($($_.Exception.Message)); set SMITH_VERSION to the version you want"
        }
    }
    $version = $version.TrimStart('v')
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "install: SMITH_VERSION takes X.Y.Z, not $version" }
    $base = "$web/releases/download/v$version"
    $name = "smith-$version-$arch-windows"

    function Fetch($file, $to) {
        if ($base -match '^https://') {
            Invoke-WebRequest -UseBasicParsing "$base/$file" -OutFile $to
        } elseif ($base -match '^[a-z]+://') {
            throw "install: downloads go over https only, not $base"
        } else {
            Copy-Item (Join-Path $base $file) $to
        }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        Write-Host "Downloading smith $version for $arch Windows"
        try {
            Fetch 'SHA256SUMS' "$tmp\SHA256SUMS"
        } catch {
            throw "install: cannot download release v$version's SHA256SUMS ($($_.Exception.Message)); check the version on $web/releases"
        }
        $line = Get-Content "$tmp\SHA256SUMS" | Where-Object { $_ -match "^[0-9a-f]{64}  \*?$([regex]::Escape("$name.zip"))$" } | Select-Object -First 1
        if (-not $line) { throw "install: release v$version has no build for $arch Windows (the first is 0.9.0)" }
        $expected = ($line -split '  ', 2)[0]
        Fetch "$name.zip" "$tmp\$name.zip"
        $actual = (Get-FileHash -Algorithm SHA256 "$tmp\$name.zip").Hash.ToLower()
        if ($actual -ne $expected) { throw "install: $name.zip does not match the release's SHA256SUMS; try again" }

        Expand-Archive "$tmp\$name.zip" -DestinationPath $tmp
        New-Item -ItemType Directory -Force $installDir | Out-Null
        $exe = Join-Path $installDir 'smith.exe'
        Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
        if (Test-Path $exe) { Move-Item $exe "$exe.old" -Force }
        foreach ($file in 'smith.exe', 'README.md', 'LICENSE', 'CHANGELOG.md') {
            Copy-Item (Join-Path "$tmp\$name" $file) $installDir -Force
        }
        Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -Recurse -Force $tmp
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $userPath = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = $userPath -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }
        if ($entries -notcontains $installDir.TrimEnd('\')) {
            $joined = if ($userPath) { "$($userPath.TrimEnd(';'));$installDir" } else { $installDir }
            $key.SetValue('Path', $joined, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            # A registry write alone does not reach running programs; this broadcasts WM_SETTINGCHANGE.
            [Environment]::SetEnvironmentVariable('SMITH_PATH_REFRESH', '1', 'User')
            [Environment]::SetEnvironmentVariable('SMITH_PATH_REFRESH', $null, 'User')
            Write-Host "Added $installDir to your PATH: open a new terminal to use smith."
        }
    } finally {
        $key.Close()
    }
    Write-Host "Installed $(& $exe --version) into $installDir"
    Write-Host "Next: smith auth login --hostname <your-forgejo-host>"
}

Install-Smith
