param(

  # { "name": "String", "build": "Boolean" }
  [Parameter(Mandatory)]
  [string]$BuildableJson,

  # [ "String" ]
  [Parameter(Mandatory)]
  [string]$ChangedFilesJson,

  [Parameter(Mandatory)]
  [string]$GitHubSHA,

  [Parameter(Mandatory)]
  [string]$GitHubRefName,

  [Parameter(Mandatory)]
  [string]$ContainerRegistry,

  [Parameter(Mandatory)]
  [string]$GitHubEventName,

  # { "name": "String", "deploy": "Boolean" }
  [Parameter(Mandatory)]
  [string]$EnvironmentsJson,

  [Parameter(Mandatory)]
  [string]$MetadataFile
)

function Write-KeyValue {
    param([string]$Key, [string]$Value)

    Write-Host ("{0,-20} : {1}" -f $Key, $Value)
}

function Get-TestProjects {
  param([psobject]$Project)

  # Convert the configured test project paths into the compact shape consumed by
  # the workflow's test job. Projects without testProjects are not testable.

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

function Create-ImageName {
  param([psobject]$Project)

  # Include a random suffix so independently created images do not share a tag.
  $randomSuffix = '{0:D5}' -f (Get-Random -Minimum 0 -Maximum 5000)

  return ("{0}/{1}:{2}-{3}-{4}-{5}" -f $ContainerRegistry, $Project.name, $branchName, $timestamp, $shortSha, $randomSuffix)
}

function Get-DockerfilePath {
    param([psobject]$Project)

    # Get the dockerfile path for the project, loads from the project metadata
    # or generates it based off the project path (the default)

    if ($Project.PSObject.Properties.Name -contains 'dockerfilePath') {
      return $Project.dockerfilePath
    }

    $projectDirectory = Split-Path -Path $Project.path -Parent

    return Join-Path -Path $projectDirectory -ChildPath "Dockerfile"
}

function Test-ProjectChanged {
    param([psobject]$Paths, [string[]]$ChangedFiles)

    # A project is considered changed when any configured related path matches
    # one of the files reported by the change-detection step.

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

  # Changes anywhere in the project directory are relevant by default; the
  # metadata file can add paths shared by multiple projects.
  $relatedPaths = @(
    "$projectDirectory/*"
  )

  if ($Project.PSObject.Properties.Name -contains 'relatedPaths') {
    $relatedPaths += $Project.relatedPaths
  }

  return $relatedPaths
}

function Get-DeployableEnvironments {
  # Keep only environments enabled for deployment and expose their names to
  # later workflow steps.
  return ,@( 
    $EnvironmentsJson `
      | ConvertFrom-Json `
      | Where-Object { $_.deploy } `
      | ForEach-Object { [pscustomobject]@{ name = $_.name } } 
  )
}

function Get-ProjectMetadata {
  # Build one normalized record per selected project so build and test stages
  # can apply their own filters without re-reading the source metadata.
  $result = @()

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
      $imageName        = Create-ImageName $project
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
        imageName       = $imageName
        runTests        = $runTests
      }    
  }

  return $result
}

function Get-BuildableProjectsMetadata {
  # Reduce project metadata to only the required fields
  # We only need fields relating to building, scanning, and deploying
  return ,@( 
      $projectMetadata `
        | Where-Object { $_.build } `
        | ForEach-Object {
          [pscustomobject]@{
            name           = $_.name
            context        = $_.context
            dockerfilePath = $_.dockerfilePath
            imageName      = $_.imageName
            eventName      = $_.eventName
          }
        }
      )
}

function Get-TestableProjectsMetadata {
  # Flatten test projects from all projects, then remove duplicate paths so a
  # shared test project runs only once.
  return ,@( 
    $projectMetadata `
      | Where-Object { $_.runTests } `
      | ForEach-Object { $_.testProjects } `
      | Sort-Object -Property path -Unique
    )
}

function Read-MetadataFile {
  # yq flattens nested YAML sequences before the result is parsed as JSON.
  # Allows yaml anchors to work as expected  
  $valuesJson = yq eval -o=json -c 'explode(.) | (.. | select(tag == "!!seq")) |= flatten' $MetadataFile

  return $valuesJson | ConvertFrom-Json
}

# Inputs arrive from workflow expressions, where escaped quotes may remain in
# the changed-files array. Normalize them before deserializing.
$changedFilesJson   = $ChangedFilesJson -replace '\\"', '"'

$metadata           = Read-MetadataFile 
$deployables        = @( $BuildableJson | ConvertFrom-Json )
$projects           = @( $metadata.projects | Where-Object { $_.name -in $deployables.name } )
$changedFiles       = @( $changedFilesJson | ConvertFrom-Json )
$shortSha           = $GitHubSHA.Substring(0, 7)
$timestamp          = Get-Date -Format "yyyyMMdd-HHmmss"
$branchName         = ($GitHubRefName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-').Trim('-.')
$environments       = Get-DeployableEnvironments
$projectMetadata    = Get-ProjectMetadata
$buildableProjects  = Get-BuildableProjectsMetadata
$testProjects       = Get-TestableProjectsMetadata

# Return both the filtered collections and boolean flags for workflow
# conditions in the calling GitHub Actions job.
$payload = [pscustomobject]@{
  buildable        = $buildableProjects
  environments     = $environments
  testProjects     = $testProjects
  hasAnyBuildable  = ($buildableProjects.Count -gt 0)
  hasAnyTestable   = ($testProjects.Count -gt 0)
  hasAnyDeployable = (($buildableProjects.Count -gt 0) -and ($environments.Count -gt 0))
}

# Emit a single compact JSON document for the next workflow step.
# Generally read by the setup workflow
ConvertTo-Json -InputObject $payload -Compress -Depth 10