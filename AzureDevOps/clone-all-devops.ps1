# ================== CONFIG ==================
$org        = "ORG"          # your Azure DevOps organization name
$pat        = "PAT"     # your personal access token (Code Read + Project Read)
$basePath   = "PATH"       # where to store all projects/repos
$zipOutput  = "PATH\azure-devops-backup.zip"  # base name for the zip archive
# =======================================================

Write-Host "=== Azure DevOps bulk clone (REST API mode) ==="
Write-Host "Organization: $org"
Write-Host "Base path:   $basePath"
Write-Host ""

# Build Authorization header for REST API
$pair        = ":$pat"
$bytes       = [System.Text.Encoding]::ASCII.GetBytes($pair)
$basicToken  = [System.Convert]::ToBase64String($bytes)
$headers     = @{ Authorization = "Basic $basicToken" }

# Ensure base folder exists
if (-not (Test-Path $basePath)) {
    New-Item -ItemType Directory -Force -Path $basePath | Out-Null
}

# 1. Get all projects
Write-Host "[1/3] Fetching projects..."
$projectsUrl  = "https://dev.azure.com/$org/_apis/projects?api-version=7.1-preview.4"
$projectsResp = Invoke-RestMethod -Method Get -Uri $projectsUrl -Headers $headers
$projects     = $projectsResp.value

if (-not $projects -or $projects.Count -eq 0) {
    Write-Host "No projects found or PAT/org incorrect."
    exit 1
}

Write-Host ("Found {0} project(s)." -f $projects.Count)

# 2. For each project, clone or update repos
foreach ($proj in $projects) {

    $projectName = $proj.name
    Write-Host ""
    Write-Host ("=== Project: {0} ===" -f $projectName)

    # Create project folder
    $projectPath = Join-Path $basePath $projectName
    if (-not (Test-Path $projectPath)) {
        New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
    }

    # Get repositories for this project
    $reposUrl   = "https://dev.azure.com/$org/$($projectName)/_apis/git/repositories?api-version=7.1-preview.1"
    $reposResp  = Invoke-RestMethod -Method Get -Uri $reposUrl -Headers $headers
    $repos      = $reposResp.value

    if (-not $repos -or $repos.Count -eq 0) {
        Write-Host "  (No repos or no access)"
    }
    else {

        Write-Host ("  Found {0} repo(s)" -f $repos.Count)

        foreach ($repo in $repos) {

            $repoName      = $repo.name
            $cloneUrlHttps = $repo.remoteUrl  # e.g. https://user@dev.azure.com/org/project/_git/repo

            Write-Host ""
            Write-Host ("  -> Repo:  {0}" -f $repoName)
            Write-Host ("     Source {0}" -f $cloneUrlHttps)

            $repoLocalPath = Join-Path $projectPath $repoName

            # detect if repo already exists locally
            $repoAlreadyExists = $false
            if (Test-Path (Join-Path $repoLocalPath ".git")) {
                $repoAlreadyExists = $true
            }

            if ($repoAlreadyExists -eq $true) {

                # repo already cloned: fetch + pull
                Write-Host "     Already cloned -- fetching latest changes..."
                Push-Location $repoLocalPath
                git fetch --all
                git pull
                Pop-Location

            }
            else {

                # Need to clone fresh

                # Build PAT-auth URL safely:
                # Example remoteUrl: https://andtkach@dev.azure.com/andtkach/Tagging/_git/Tagging
                # Step 1: remove leading "https://"
                $noProto = $cloneUrlHttps -replace '^https://', ''

                # Step 2: strip "something@" before host if present
                # Result should look like "dev.azure.com/org/project/_git/repo"
                $noUser = $noProto -replace '^[^@]+@', ''

                # Step 3: inject PAT
                # Final form: https://pat:YOUR_PAT@dev.azure.com/org/project/_git/repo
                $secureCloneUrl = "https://pat:$pat@$noUser"

                Write-Host ("     Cloning fresh copy to {0} ..." -f $repoLocalPath)
                git clone $secureCloneUrl $repoLocalPath

                # Clean PAT from the saved origin remote in local repo
                if (Test-Path $repoLocalPath) {
                    Push-Location $repoLocalPath
                    git remote set-url origin $cloneUrlHttps
                    Pop-Location
                }

            } # end else (fresh clone)

        } # end foreach ($repo in $repos)

    } # end else (repos exist)

} # end foreach ($proj in $projects)

# 3. Zip the entire output directory
Write-Host ""
Write-Host "[3/3] Creating zip archive..."

# Remove old base zip if it exists
if (Test-Path $zipOutput) {
    Remove-Item $zipOutput -Force
}

# Add timestamp to make unique archive name
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$zipFile = [System.IO.Path]::ChangeExtension($zipOutput, $null) + "_$timestamp.zip"

Write-Host ("Compressing {0} -> {1} ..." -f $basePath, $zipFile)
Compress-Archive -Path "$basePath\*" -DestinationPath $zipFile -Force

Write-Host ""
Write-Host "Done. All projects and repos processed and zipped."
Write-Host ("Archive created: {0}" -f $zipFile)
