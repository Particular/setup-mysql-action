param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$DatabaseName = "nservicebus",
    [string]$Username = "particular",
    [string]$ImageTag = "8.4",
    [string]$InitScript = "",
    [string]$RegistryLoginServer = "index.docker.io",
    [string]$RegistryUser,
    [string]$RegistryPass
)

$ErrorActionPreference = 'Stop'

# Require setup-wsl-action to have run first — it provisions WSL/Docker on Windows
# runners and exports the WslTools module at WSL_TOOLS_MODULE_PATH.
if (-not $Env:WSL_TOOLS_MODULE_PATH) {
    throw "This action requires Particular/setup-wsl-action to run first — it provisions WSL/Docker and exports the WslTools module at WSL_TOOLS_MODULE_PATH."
}
Import-Module $Env:WSL_TOOLS_MODULE_PATH -Force

function Export-Env {
    param([string]$Name, [string]$Value)
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

$runnerOs = $Env:RUNNER_OS ?? "Linux"

# Validate the image tag — it's user-controlled and interpolated into docker commands.
# Docker tags: max 128 chars, alphanumeric + _ . -, must start with alphanumeric or _.
if ($ImageTag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
    throw "image-tag must be a valid Docker image tag (alphanumeric, underscore, period, hyphen; max 128 chars). Got: $ImageTag"
}

# The root account and the connection-string user each get a generated password.
# Mask them so they never surface in the workflow log.
$rootPassword = [guid]::NewGuid().ToString()
Write-Output "::add-mask::$rootPassword"
$userPassword = [guid]::NewGuid().ToString()
Write-Output "::add-mask::$userPassword"

$image = "mysql:$ImageTag"
$port = 3306
$ipAddress = "127.0.0.1"

if ($runnerOs -eq "Linux") {
    Write-Output "Running MySQL in container $ContainerName using Docker"

    docker run --name $ContainerName --detach --restart unless-stopped `
        --publish "${port}:${port}" `
        -e MYSQL_ROOT_PASSWORD=$rootPassword `
        -e MYSQL_ROOT_HOST=% `
        -e MYSQL_DATABASE=$DatabaseName `
        -e MYSQL_USER=$Username `
        -e MYSQL_PASSWORD=$userPassword `
        $image

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start MySQL container"
    }
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running MySQL in container $ContainerName using WSL"

    # WSL and Docker were provisioned by setup-wsl-action. Read the distribution
    # and the WSL VM IP from the environment it exported.
    $wslDistribution = $Env:WSL_DISTRIBUTION
    $ipAddress = $Env:WSL_IP

    if (-not $ipAddress) {
        throw "WSL_IP is not set. Run Particular/setup-wsl-action before this action."
    }

    Write-Output "WSL address: $ipAddress"

    # Optionally log in to the container registry to avoid rate limits when pulling.
    if ($RegistryUser -and $RegistryPass) {
        Write-Output "::add-mask::$RegistryPass"
        Write-Output "Logging in to $RegistryLoginServer inside WSL"
        $loginCommand = "docker login --username '$RegistryUser' --password-stdin '$RegistryLoginServer'"
        $RegistryPass | wsl.exe --distribution $wslDistribution --user root -- bash -c $loginCommand
        if ($LASTEXITCODE -ne 0) {
            throw "Docker registry login inside WSL failed with exit code $LASTEXITCODE"
        }
    }
    else {
        Write-Output "Using anonymous credentials"
    }

    Write-Output "::group::Starting MySQL container"
    # Use array splatting to avoid WSL interop quoting issues — never pass
    # multi-line commands with backslash continuations through wsl.exe.
    $dockerArgs = @(
        "run", "--name", $ContainerName, "--detach", "--restart", "unless-stopped",
        "--publish", "${port}:${port}",
        "-e", "MYSQL_ROOT_PASSWORD=$rootPassword",
        "-e", "MYSQL_ROOT_HOST=%",
        "-e", "MYSQL_DATABASE=$DatabaseName",
        "-e", "MYSQL_USER=$Username",
        "-e", "MYSQL_PASSWORD=$userPassword",
        $image
    )
    & wsl.exe --distribution $wslDistribution -- docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start MySQL container in WSL"
    }

    & wsl.exe --distribution $wslDistribution -- docker ps --filter "name=$ContainerName"
    Write-Output "::endgroup::"
}
else {
    throw "$runnerOs not supported"
}

# Wait for MySQL to be ready. mysqladmin ping reports server liveness, not auth,
# so it can answer "mysqld is alive" before the entrypoint has created the user
# and database. Probe with a real query instead, over TCP: --host=127.0.0.1 forces
# a TCP connection (the entrypoint's init-phase server runs with --skip-networking,
# so it refuses the connection), and the query only succeeds once root accepts the
# generated password. This exercises the same path the connection string uses.
Write-Output "::group::Waiting for MySQL to be ready"
$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Write-Output "Attempt $i/30 to check MySQL readiness..."

    if ($runnerOs -eq "Linux") {
        docker exec $ContainerName mysql --host=127.0.0.1 --port=$port --user=root --password=$rootPassword --execute="SELECT 1" 2>$null | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    else {
        # Single command string, single-quoted values — wsl.exe re-parses argv as
        # a shell command line, so an unquoted "--execute=SELECT 1" would be split.
        $probe = "docker exec $ContainerName mysql --host=127.0.0.1 --port=$port --user=root --password='$rootPassword' --execute='SELECT 1'"
        Invoke-Wsl -Distribution $wslDistribution -Command $probe 2>$null | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }

    if ($ok) {
        Write-Output "  - MySQL is ready"
        $ready = $true
        break
    }

    Write-Output "  - Not ready, sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"

if (-not $ready) {
    throw "MySQL did not become ready within 150s."
}

# Create a mysql shim on PATH so consumers and CI can run the mysql client the
# same way on both platforms — Linux (Docker directly) and Windows (Docker inside
# WSL). Mirrors the dspmq/runmqsc shim pattern from setup-ibmmq-action. On
# Windows the shim routes through `bash -c` with each argument single-quoted:
# wsl.exe re-parses argv as a shell command line, so an unquoted argument with
# spaces or other shell-special characters would cause a syntax error.
Write-Output "Creating mysql forwarding script"
# RUNNER_TEMP is always set on GitHub runners; fall back for local testing.
$runnerTemp = if ($Env:RUNNER_TEMP) { $Env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$shimDir = Join-Path $runnerTemp "mysql-shim"
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

if ($runnerOs -eq "Linux") {
    # Bash script — stdin flows naturally to docker exec -i
    $mysqlPath = Join-Path $shimDir "mysql"
    Set-Content -Path $mysqlPath -Value "#!/bin/bash`ndocker exec -i $ContainerName mysql `"$@`"" -Encoding ASCII
    & chmod +x $mysqlPath
}
elseif ($runnerOs -eq "Windows") {
    $mysqlPath = Join-Path $shimDir "mysql.ps1"
    Set-Content -Path $mysqlPath -Encoding ASCII -Value @"
`$quoted = (`$args | ForEach-Object { "'" + (`$_ -replace "'", "'\''") + "'" }) -join ' '
`$command = "docker exec -i $ContainerName mysql `$quoted"
`$input | wsl.exe --distribution `$env:WSL_DISTRIBUTION --user root -- bash -c `$command
"@
}

Write-Output "Adding mysql shim to PATH"
$shimDir | Out-File -FilePath $Env:GITHUB_PATH -Encoding utf8 -Append
# GITHUB_PATH only affects subsequent steps; set it in the current process too.
if ($runnerOs -eq "Linux") {
    $Env:PATH = "$shimDir`:$Env:PATH"
} else {
    $Env:PATH = "$shimDir;$Env:PATH"
}

# Export the connection string. The keyword set matches what the NServiceBus
# MySql transport expects.
$connectionString = "Data Source=$ipAddress;Initial Catalog=$DatabaseName;User ID=$Username;Password=$userPassword;AllowUserVariables=True;AutoEnlist=false;ConnectionReset=true;Connect Timeout=60"

Write-Output "Setting environment variable $ConnectionStringName to MySQL connection string..."
Export-Env -Name $ConnectionStringName -Value $connectionString

if ($InitScript) {
    # Accept a comma-separated list of SQL scripts and execute each in order.
    # The @() wrapper keeps the result an array even when only one path is given,
    # so $scripts.Count is the number of scripts, not the string length.
    $scripts = @($InitScript -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    for ($i = 0; $i -lt $scripts.Count; $i++) {
        $scriptPath = $scripts[$i]
        Write-Output "::group::Running init script $scriptPath"

        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw "Init script not found: $scriptPath"
        }

        # Normalize to LF and pipe through docker exec -i. Scripts may be checked
        # out with CRLF on Windows, and the mysql client should not see them.
        # MYSQL_PWD keeps the password out of the process list. The scripts run
        # as root, so they can create databases and users beyond the defaults.
        $script = (Get-Content -LiteralPath $scriptPath -Raw) -replace "`r`n", "`n"

        if ($runnerOs -eq "Linux") {
            $script | docker exec -i -e "MYSQL_PWD=$rootPassword" $ContainerName mysql --user=root --database=$DatabaseName
        }
        else {
            # Pipe stdin straight into wsl.exe (mirrors the docker login call above) —
            # Invoke-Wsl does not forward pipeline input to the command it runs.
            $run = "docker exec -i -e MYSQL_PWD=$rootPassword $ContainerName mysql --user=root --database=$DatabaseName"
            $script | wsl.exe --distribution $wslDistribution --user root -- bash -c $run
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Init script $scriptPath failed with exit code $LASTEXITCODE"
        }

        Write-Output "::endgroup::"
    }
}
