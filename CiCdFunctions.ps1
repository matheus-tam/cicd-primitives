
# Base WebRequest verbs

function GetOrchApi([string]$bearerToken, [string]$uri, $headers = $null, [bool]$debug = $false) {
    $tenantName = ExtractTenantNameFromUri -uri $uri
    if($debug) {
        Write-Host $uri
    }
    if( $headers -eq $null ) {
        $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    }
    $response = Invoke-WebRequest -Method 'Get' -Uri $uri -Headers $headers -ContentType "application/json"
    if($debug) {
        Write-Host $response
    }
    return ConvertFrom-Json $response.Content
}

function PostOrchApi([string]$bearerToken, [string]$uri, $body, $headers = $null, [bool]$debug = $false) {
    $body_json = $body | ConvertTo-Json
    $tenantName = ExtractTenantNameFromUri -uri $uri
    if($debug) {
        Write-Host $uri
        Write-Host $body
        Write-Host $headers
    }
    if( $headers -eq $null ) {
        $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    }
    $response = Invoke-WebRequest -Method 'Post' -Uri $uri -Headers $headers -ContentType "application/json" -Body $body_json
    if($debug) {
        Write-Host $response
    }
    if( $response.StatusCode -ne 200 )
    {
        Write-Error "Problem with authentication (Orchestrator)"
        exit 1
    }
    return ConvertFrom-Json $response.Content
}

# Interactions with the Orchestrator API

function AuthenticateToCloudAndGetBearerToken([string]$clientId, [string]$refreshToken, [string]$tenantName, [bool]$debug = $false) {
    $body = @{"grant_type"="refresh_token"; "client_id"="$($clientId)"; "refresh_token"="$($refreshToken)"}
    $headers = @{"Authorization"="Bearer"; "X-UIPATH-TenantName"="$($tenantName)"}
    $uri = "https://account.uipath.com/oauth/token"
    $response = PostOrchApi -bearerToken "" -uri $uri -headers $headers -body $body
    if($debug) {
        Write-Host $response
    }
    return $response.access_token
}

function GetFolderId([string]$orchestratorApiBaseUrl, [string]$bearerToken, [string]$folderName) {
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($orchestratorApiBaseUrl)/Folders?%24filter=FullyQualifiedName%20eq%20'$($folderName)'"
    return $result.value[0].Id.ToString()
}

function GetProcessId([string]$orchestratorApiBaseUrl, [string]$bearerToken, [string]$folderId, [string]$processName) {
    $result = GetOrchApi -bearerToken $bearerToken -uri "$($orchestratorApiBaseUrl)/Releases?%24filter=Name%20eq%20'$($processName)'%20and%20OrganizationUnitId%20eq%20$($folderId)"
    return $result.value[0].Id.ToString()
}

function GetFinalVersionProcess([string]$orchestratorApiBaseUrl, [string]$bearerToken) {
    $processName = GetProcessName
    $processVersion = GetProcessVersion
    
    $uri = "$($orchestratorApiBaseUrl)/Processes/UiPath.Server.Configuration.OData.GetProcessVersions(processId='$($processName)')?`$filter=startswith(Version,'$($processVersion)')&`$orderby=Published%20desc"
    $result = GetOrchApi -bearerToken $bearerToken -uri $uri # -debug $true
    
    if($result."@odata.count" -eq 0) {
        return $processVersion
    }
    else {
        $latestVersion = $result.value[0].Version
    }

    if ($processVersion -eq $latestVersion) {
        $finalVersion = "$($processVersion).1"
    }
    else {
        $finalVersion = IncrementVersion -version $latestVersion
    }
    return $finalVersion
}

function UploadPackageToOrchestrator([string]$orchestratorApiBaseUrl, [string]$bearerToken, [string]$filePath) {
    $tenantName = ExtractTenantNameFromUri -uri $orchestratorApiBaseUrl
    $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"}
    $uri = "$($orchestratorApiBaseUrl)/Processes/UiPath.Server.Configuration.OData.UploadPackage"
    $Form = @{
        file = Get-Item -Path $filePath
    }
    $response = Invoke-RestMethod -Uri $uri -Method Post -Form $Form -Headers $headers -ContentType "multipart/form-data"
}

function BumpProcessVersion([string]$orchestratorApiBaseUrl, [string]$bearerToken, [string]$folderId, [string]$processId, [string]$processVersion) {
    $tenantName = ExtractTenantNameFromUri -uri $orchestratorApiBaseUrl
    $headers = @{"Authorization"="Bearer $($bearerToken)"; "X-UIPATH-TenantName"="$($tenantName)"; "X-UIPATH-OrganizationUnitId"="$($folderId)"}
    $body = @{"packageVersion"=$processVersion}
    $result = PostOrchApi -bearerToken $bearerToken -uri "$($orchestratorApiBaseUrl)/Releases($($processId))/UiPath.Server.Configuration.OData.UpdateToSpecificPackageVersion" -headers $headers -body $body
}

# Helper functions

function GetUrlOrchestratorApiBaseCloud([string]$organizationId, [string]$tenantName) {
    return "https://cloud.uipath.com/$($organizationId)/$($tenantName)/orchestrator_/odata"
}

function GetProcessName() {
    $projectJson = Get-Content .\project.json -Raw | ConvertFrom-Json
    return $projectJson.name
}

function GetProcessVersion() {
    $projectJson = Get-Content .\project.json -Raw | ConvertFrom-Json
    return $projectJson.projectVersion
}

function IncrementVersion([string]$version) {
    $aFinalVersion = ""
    $anOriginalVersionArray = $version.Split('.')
    $lastNumber = 0
    if($anOriginalVersionArray.Count -eq 0) {
        return $version + ".1"
    }
    if( [int]::TryParse($anOriginalVersionArray[$anOriginalVersionArray.Length - 1], [ref]$lastNumber) ) {
        for ($num = 0 ; $num -lt $anOriginalVersionArray.Length - 1; $num++) {
            $aFinalVersion = $aFinalVersion + $anOriginalVersionArray[$num] + "."
        }
        $aFinalVersion = $aFinalVersion + ($lastNumber + 1).ToString()
    }
    else {
        return $version + ".1"
    }
    return $aFinalVersion
}

function ExtractTenantNameFromUri([string]$uri) {
    return "$uri" -replace "(?sm).*?.*/([^/]*?)/orchestrator_/odata(.*?)$.*","`$1"
}

function InterpretTestResults([string]$testResults) {
    $resultsObject = Get-Content $testResults -Raw | ConvertFrom-Json
    $statusPass = $true
    foreach ($elem in $resultsObject.TestSetExecutions) {
        if ($elem.Status -ne "Passed") {
            $statusPass = $false
        }
    }
    if($statusPass -ne $true) {
        return 1
    }
    return 0
}
