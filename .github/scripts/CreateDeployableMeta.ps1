param(
  [Parameter(Mandatory)]
  [string]$DeployablesJson,

  [Parameter(Mandatory)]
  [string]$ChangedFilesJson,

  [Parameter(Mandatory)]
  [string]$GitHubSHA,

  [Parameter(Mandatory)]
  [string]$GitHubRefName,

  [Parameter(Mandatory)]
  [string]$ContainerRegistry,

  [Parameter(Mandatory)]
  [string]$GitHubEventName
)

function Write-KeyValue {
    param([string]$Key, [string]$Value)

    Write-Host ("{0,-20} : {1}" -f $Key, $Value)
}

function Get-TestProjects {
  param([psobject]$Project)

  if ($Project.PSObject.Properties.Name -contains 'testProjects') {
      return $Project.testProjects | ForEach-Object {
        [pscustomobject]@{
          name = [System.IO.Path]::GetFileNameWithoutExtension($_)
          path = $_
        }
      }
  }

  return
}

function Create-ProposedImage {
  param([psobject]$Project)

  # Random suffix, so tags of different images are not identical
  $randomSuffix = '{0:D5}' -f (Get-Random -Minimum 0 -Maximum 5000)

  return ("{0}/{1}:{2}-{3}-{4}-{5}" -f $ContainerRegistry, $Project.name, $branchName, $timestamp, $shortSha, $randomSuffix)
}

function Get-DockerfilePath {
    param([psobject]$Project)

    $projectDirectory = Split-Path -Path $Project.path -Parent

    return Join-Path -Path $projectDirectory -ChildPath "Dockerfile"
}

function Test-ProjectChanged {
    param([psobject]$Paths, [string[]]$ChangedFiles)

    foreach ($relatedPath in $Paths) {
        if ($ChangedFiles | Where-Object { $_ -like $relatedPath }) {
            return $true
        }
    }

    return $false
}

function Get-ProjectRelatedPaths {
  param([psobject]$Project)

  $projectDirectory = Split-Path -Path $Project.path -Parent
  $relatedPaths     = @(
    "$projectDirectory/*"
  )

  if ($Project.PSObject.Properties.Name -contains 'relatedPaths') {
    $relatedPaths += $Project.relatedPaths
  }

  return $relatedPaths
}

$ChangedFilesJson = $ChangedFilesJson -replace '\\"', '"' # Normalise the array

$valuesFileName = "./.github/project-metadata.yaml"

# Read and explodes the yaml anchors
$valuesJson = yq eval -o=json -c 'explode(.) | (.. | select(tag == "!!seq")) |= flatten' $valuesFileName

$values         = $valuesJson | ConvertFrom-Json
$deployables    = @( $DeployablesJson | ConvertFrom-Json )
$projects       = @( $values.projects | Where-Object { $_.name -in $deployables.name } )
$changedFiles   = @( $ChangedFilesJson | ConvertFrom-Json )
$shortSha       = $GitHubSHA.Substring(0, 7)
$timestamp      = Get-Date -Format "yyyyMMdd-HHmmss"
$branchName     = ($GitHubRefName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-').Trim('-.')

$result = @()

Write-KeyValue "Deployables"    $DeployablesJson
Write-KeyValue "Changed files"  $changedFiles

foreach ($project in $projects) {
    $deployable       = $deployables | Where-Object { $_.name -eq $project.name } | Select-Object -First 1 
    $projectPath      = $project.path
    $name             = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
    $build            = $deployable.build
    $eventName        = $project.name
    $dockerfilePath   = Get-DockerfilePath $project
    $relatedPaths     = Get-ProjectRelatedPaths $project
    $hasChanged       = Test-ProjectChanged $relatedPaths $changedFiles
    $testProjects     = @(Get-TestProjects $project)
    $context          = $project.context
    $proposedImage    = Create-ProposedImage $project
    $runTests         = $build -or ($GitHubEventName -ne "workflow_dispatch")   

    $result += [pscustomobject]@{
      build           = $build
      changed         = $hasChanged
      name            = $name
      projectPath     = $projectPath
      eventName       = $eventName
      dockerfilePath  = $dockerfilePath
      testProjects    = $testProjects
      context         = $context  
      proposedImage   = $proposedImage
      runTests        = $runTests
    }
    
    Write-Host "---"

    Write-KeyValue "Name"           $name
    Write-KeyValue "Project"        $projectPath
    Write-KeyValue "Changed"        $hasChanged
    Write-KeyValue "Build"          $build
    Write-KeyValue "Context"        $context
    Write-KeyValue "Run tests"      $runTests
    Write-KeyValue "Event name"     $eventName
    Write-KeyValue "Dockerfile"     $dockerfilePath
    Write-KeyValue "Related paths"  $relatedPaths
    Write-KeyValue "Image"          $proposedImage
}

ConvertTo-Json -InputObject ([object[]]$result) -Compress -Depth 10