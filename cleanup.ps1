param (
    [string]$ContainerName
)

$ErrorActionPreference = 'Continue'
$runnerOs = $Env:RUNNER_OS ?? "Linux"

if ($runnerOs -eq "Linux") {
    if (-not $ContainerName) {
        Write-Output "No container name supplied, nothing to clean up"
        return
    }

    Write-Output "Killing Docker container $ContainerName"
    docker kill $ContainerName 2>$null

    Write-Output "Removing Docker container $ContainerName"
    docker rm $ContainerName 2>$null
}
elseif ($runnerOs -eq "Windows") {
    # The Windows container removal runs through the WslTools module (Invoke-Wsl),
    # which setup-wsl-action exports at WSL_TOOLS_MODULE_PATH.
    if (-not $Env:WSL_TOOLS_MODULE_PATH) {
        throw "This action requires Particular/setup-wsl-action to run first — it provisions WSL/Docker and exports the WslTools module at WSL_TOOLS_MODULE_PATH."
    }
    Import-Module $Env:WSL_TOOLS_MODULE_PATH -Force

    $wslDistribution = $Env:WSL_DISTRIBUTION

    if ($ContainerName) {
        Write-Output "Removing WSL Docker container $ContainerName"
        if ($wslDistribution) {
            wsl.exe --distribution $wslDistribution --user root -- bash -c "docker rm --force ${ContainerName} 2>/dev/null || true"
        }
    }
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}
