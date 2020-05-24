<#
.DESCRIPTION
    Uses the Internet Archive Wayback Machine "Save" feature to archive web pages. Receives an array of URLs and sends them to the Wayback Machine.

.PARAMETER Method
    HTTP method sent to Wayback Machine. Requests will differ slightly between GET and POST.
.PARAMETER BackoffSeconds
    Upon a response of "429 Too many Requests", the amount of time (in seconds) to wait before retrying the request.
    If "Retry-After" header is provided by the server, then the header value is used instead.
.PARAMETER SaveResponse
    Output the WebResponseObject, containing the response content, headers, links, etc.
.PARAMETER ShowProgress
    Shows save progress of URLs via Write-Progress
.PARAMETER RetryBackOffPercent
    Percentage of BackoffSeconds to wait on each subsequent retry.
    For example, a value of 50% will halve the wait time on each retry. Given an original BackoffSeconds off 60...
    Retry #1: BackoffSeconds = 60 ; Retry #2: BackoffSeconds = 30 ; Retry #3: BackoffSeconds = 15
.PARAMETER RandomWaitSeconds
    Optional base seconds to wait between each request. Multiplied by random value between 0.5 and 1.5.
    For example, a value of 3 will result in a random wait between 1.5 to 4.5 seconds.
.PARAMETER LogPath
    Optional path to a log file to write script output information.

.EXAMPLE
    PS> $WaybackSaves = .\Invoke-WaybackSave.ps1 -Url "https://example.com","https://example.org" -Method POST -SaveResponse
    PS> $WaybackSaves
    Url                         Response
    ---                         --------
    https://example.com/        <!DOCTYPE html>…
    https://example.org/        <!DOCTYPE html>…

    Sends POST requests to 'https://web.archive.org/save/https://example.com' and 'https://web.archive.org/save/https://example.org'.
    Saves PSCustomObject, including WebResponseObject, to variable $WaybackSaves for later review.

.EXAMPLE
    PS> $UrlArray = Import-Csv -Path "MyUrls.csv"
    PS> .\Invoke-WaybackSave.ps1 -Url $UrlArray -Method POST -BackoffSeconds 60 -InformationAction Continue -Verbose

    [2020-12-31 23:55:01.045] [1] Saving URL:    https://sub1.example.domain/
    VERBOSE: [1] Wayback URL:   https://web.archive.org/save/https://sub1.example.domain/
    ...
    [2020-12-31 23:55:51.451] [26] Saving URL:    https://3b481fbdeb2e4bb286b210140ea3d7de.example.domain/
    VERBOSE: [26] Wayback URL:   https://web.archive.org/save/https://3b481fbdeb2e4bb286b210140ea3d7de.example.domain/
    WARNING: Response Status: 429 Too Many Requests
    [2020-12-31 23:55:51.567] Waiting seconds: 60
    [2020-12-31 23:56:52.890] [26] Saving URL:    https://3b481fbdeb2e4bb286b210140ea3d7de.example.domain/
    VERBOSE: [26] Wayback URL:   https://web.archive.org/save/https://3b481fbdeb2e4bb286b210140ea3d7de.example.domain/
    [2020-12-31 23:56:55.123] [27] Saving URL:    https://www.youtube.com/watch?v=Gs069dndIYk
    VERBOSE: [27] Wayback URL:   https://web.archive.org/save/https://www.youtube.com/watch?v=Gs069dndIYk

    Sends POST requests for each URL in in "MyUrls.csv". Demonstrates rate-limiting 429 response by the server. Client waits 60 seconds and retries.
    Sets InformationAction = Continue will send also information stream to console.

.LINK
    https://web.archive.org/

.NOTES
    TODO: Authenticated sessions (i.e. logged in with Archive.org account) will allow more save options, such as saving outlinks and screenshots.
#>

#Requires -Version 5

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [uri[]] $Url,
    [string] $UserAgent = 'Mozilla/5.0 PowerShell (PS-Wayback-Save)',
    [ValidateSet("GET","POST")]
    [string] $Method = "POST",
    [double] $BackoffSeconds = 60,
    [int] $Retry = 3,
    [ValidateRange(1, 100)]
    [int] $RetryBackOffPercent = 50,
    [ValidateRange(1, [int]::MaxValue)]
    [double] $RandomWaitSeconds = 2.5,
    [switch] $SaveResponse,
    [switch] $ShowProgress,
    $LogPath = $null
)

function Write-InfoLog {
    param (
        [string] $Message,
        [System.IO.FileInfo] $LogPath = $script:LogPath
    )

    $timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $msg = "[$timestamp] $Message"
    if ($LogPath) {
        Write-Information -MessageData $msg -InformationAction Continue
        Add-Content -Path $LogPath -Value $msg
    }
    else {
        Write-Information -MessageData $msg
    }
}

function Invoke-WebRequestWrapper {
<#
.PARAMETER RetryBackOffPercent
    Percentage of BackoffSeconds to wait on each subsequent retry.
    For example, a value of 50% will halve the wait time on each retry. Given an original BackoffSeconds = 60:
    1st Retry: BackoffSeconds = 60
    2nd Retry: BackoffSeconds = 30
    3rd Retry: BackoffSeconds = 15
.PARAMETER RandomWaitSeconds
    Optional base seconds to wait between each request. Multiplied by random value between 0.5 and 1.5.
    For example, a value of 3 will result in a random wait between 1.5 to 4.5 seconds.
#>
    param (
        $Url = $u,
        $Parameters = $Params_InvokeReq,
        [double] $BackoffSeconds = $BackoffSeconds,
        [int] $Retry = 3,
        [ValidateRange(1, 100)]
        [int] $RetryBackOffPercent = 50,
        [ValidateRange(1, [int]::MaxValue)]
        [int] $RandomWaitSeconds = $RandomWaitSeconds
    )

    $http_retry = @(404, 408, 425, 429, 500, 502, 503, 504)

    try {
        $Response = Invoke-WebRequest @Parameters
    }
    catch [System.Net.Sockets.SocketException] {
        # Retry request with new backoff time
        $Retry--
        if ($Retry -ge 0) {
            Write-InfoLog -Message "$_"
            Write-InfoLog -Message "Retries remaining: $Retry"
            [System.Threading.Thread]::Sleep($BackoffSeconds * 1000)
            $BackoffSeconds = $BackoffSeconds * ($RetryBackOffPercent / 100)
            Invoke-WebRequestWrapper -Url $Url -Parameters $Parameters -BackoffSeconds $BackoffSeconds -Retry $Retry
            return
        }
        else {
            Write-InfoLog -Message "Retry limit reached. Skipping..."
            return $_.Exception
        }
    }
    catch [System.Net.Http.HttpRequestException] {
        # Check for "Retry-After" header to wait; Otherwise, wait for an arbitrary amount of time (BackoffSeconds)
        # If not an HTTP 429 error, return that response and do not retry
        if ($_.Exception.Response) {
            $status_descr = $_.Exception.Response.ReasonPhrase
            $status_code = $_.Exception.Response.StatusCode.value__
            Write-Warning "Response Status: $status_code $status_descr"
            $retry_after = $_.Exception.Response.Headers["Retry-After"]
        }
        if ( ($status_code -eq 429) -and $retry_after) {
            Write-InfoLog -Message "Retry After: $retry_after"
            Write-Warning "Retry After: $retry_after"
            $BackoffSeconds = $retry_after
        }
        elseif ($status_code -in $http_retry) {
            Write-InfoLog -Message "Waiting seconds: $BackoffSeconds"
            Write-Warning "Waiting seconds: $BackoffSeconds"
        }
        else {
            $Retry = 0
        }

        # Retry request with new backoff time
        $Retry--
        if ($Retry -ge 0) {
            Write-InfoLog -Message "Retries remaining: $Retry"
            [System.Threading.Thread]::Sleep($BackoffSeconds * 1000)
            $BackoffSeconds = $BackoffSeconds * ($RetryBackOffPercent / 100)
            Invoke-WebRequestWrapper -Url $Url -Parameters $Parameters -BackoffSeconds $BackoffSeconds -Retry $Retry
            return
        }
        else {
            Write-InfoLog -Message "Retry limit reached. Skipping..."
            return $_.Exception.Response
        }
    }
    catch {
        Write-InfoLog -Message "Uncaught exception! Skipping..."
        return $_.Exception
    }

    if ($RandomWaitSeconds) {
        $RandWaitMs = $RandomWaitSeconds * 1000 * (Get-Random -Minimum 0.5 -Maximum 1.5)
        [System.Threading.Thread]::Sleep($RandWaitMs)
    }
    return $Response
}

function New-LogFile {
    param (
        $LogPath = $LogPath
    )

    if ($LogPath) {
        if (Test-Path -Path $LogPath -PathType Leaf) {
            Write-Warning  "Existing log file at: $LogPath"
            return
        }
        try {
            Write-Host "Creating new log file at: $LogPath"
            New-Item -Path $LogPath -ItemType File -Force -ErrorAction Stop > $null
        }
        catch {
            Write-Error $_
            break
        }
    }
}

################
##### Main #####
################

New-LogFile -LogPath $LogPath

$Headers = @{
    "Accept" = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8'
    "Accept-Encoding" = 'gzip, deflate, br'
    "Accept-Language" = 'en-US,en;q=0.5'
    "DNT" = 1
    "Referer" = "https://web.archive.org.org/save"
    "TE" = 'trailers'
}

# List to get partial responses in case of cancel (i.e. Ctrl+C)
$total = $Url.Count
$counter = 0
$ListOut = New-Object -TypeName 'System.Collections.Generic.List[System.Object]' -ArgumentList $total

try {
    foreach ($u in $Url) {
        try {
            $save_url = "https://web.archive.org/save/$u"
            $websession1 = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $Req_Body = @{
                url = $u
                capture_all = "on"
                #capture_outlinks = "on"
                #capture_screen = "on"
            }

            $Params_InvokeReq = @{
                Method = $Method
                Uri = $save_url
                UserAgent = $UserAgent
                Headers  = $Headers
                ContentType = 'application/x-www-form-urlencoded'
                WebSession = $websession1
                Verbose = $false
            }

            switch ($Method) {
                "POST" {
                    $Params_InvokeReq["Body"] = $Req_Body
                }
                "GET" { }
                Default { }
            }

            $counter++
            if ($ShowProgress) {
                $prog_percent = [System.Math]::Round(($counter / $total) * 100, 2)
                Write-Progress -Activity "Saving URLs to Wayback Machine" -PercentComplete $prog_percent -Status "Percent Complete ($counter of $total): $prog_percent%" -CurrentOperation "Saving URL: $u"
            }
            Write-InfoLog "[$counter] Saving URL:`t$u"
            Write-Verbose "[$counter] Wayback URL:`t$($Params_InvokeReq.Uri)"
            $Resp = Invoke-WebRequestWrapper -Url $u -Parameters $Params_InvokeReq -BackoffSeconds $BackoffSeconds -Retry $Retry -RetryBackOffPercent $RetryBackOffPercent
        }
        finally {
            if ($SaveResponse) {
                $temp = [PSCustomObject]@{
                    Url = $u
                    Response = $Resp
                }
            }
            else {
                $temp = $u.ToString()
            }

            $ListOut.Add($temp)
        }
    }
}
finally {
    Write-Output $ListOut
}
