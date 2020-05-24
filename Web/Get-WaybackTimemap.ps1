<#
.DESCRIPTION
    Queries the Internet Archive Wayback Machine Timemap.

    Equivalent to a browser load of "https://web.archive.org/web/*/$TargetUrl/*", where $TargetUrl is your chosen URL.

.EXAMPLE
    PS> $ComeOnAndSlam = .\Get-WaybackTimemap.ps1 -TargetUrl "https://spacejam.com"
    PS> $ComeOnAndSlam

        original                                     mimetype  timestamp      endtimestamp   groupcount uniqcount
        --------                                     --------  ---------      ------------   ---------- ---------
        http://spacejam.com:80/                      text/html 19961227161755 20200519130342 496        39
        http://www.spacejam.com:80/%22/              text/html 20031105072841 20040220233740 2          1
        http://www.spacejam.com:80/%22TARGET=%22_top text/html 20031107172306 20040614191539 3          1
        ...
        ...

    Query against https://spacejam.com with default values.

.EXAMPLE
    PS> $WelcomeToTheJam = .\Get-WaybackTimemap.ps1 -TargetUrl "https://spacejam.com" -ConvertTimeStamp
    PS> $WelcomeToTheJam

        original                                     mimetype  timestamp      endtimestamp   groupcount uniqcount timestamp_datetime    endtimestamp_datetime
        --------                                     --------  ---------      ------------   ---------- --------- ------------------    ---------------------
        http://spacejam.com:80/                      text/html 19961227161755 20200519130342 496        39        12/27/1996 8:17:55 AM 5/19/2020 6:03:42 AM
        http://www.spacejam.com:80/%22/              text/html 20031105072841 20040220233740 2          1         11/4/2003 11:28:41 PM 2/20/2004 3:37:40 PM
        http://www.spacejam.com:80/%22TARGET=%22_top text/html 20031107172306 20040614191539 3          1         11/7/2003 9:23:06 AM  6/14/2004 12:15:39 PM
        ...
        ...

    Query against https://spacejam.com. Converts the timestamps to [DateTime] objects and adds as additional object members.

.NOTES
    TODO: Further research acceptable query parameter syntax
#>

#Requires -Version 5.1

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string] $WaybackTimeMapUri = 'https://web.archive.org/web/timemap/',
    [ValidateNotNullOrEmpty()]
    [string] $TargetUrl,
    [string] $MatchType = 'prefix',
    [string] $Collapse = 'urlkey',
    [ValidateSet('JSON','CSV')]
    [string] $Output = 'JSON',
    [array] $FormatList = @('original','mimetype','timestamp','endtimestamp','groupcount','uniqcount'),
    [string] $Filter = '!statuscode:[45]..',
    [int] $Limit = 100000,
    [string] $UserAgent = 'Mozilla/5.0 PowerShell (PS-Wayback-Save)',
    [switch] $ConvertTimestamp
)

function Convert-Timestamp {
    param (
        [ValidateNotNullOrEmpty()]
        $TimeMap = $TimeMap,
        [string]$DateFormat = 'yyyyMMddHHmmss',
        $TimestampNames = @("timestamp", "endtimestamp")
    )

    # Loop through each defined timestamp header
    foreach ($TSName in $TimestampNames) {
        # Check if timestamp header exists
        if ($Timemap.$TSName) {
            # Add new member to the object containing the converted timestamps
            $TSName_Converted = "$TSName`_datetime"
            $Timemap | Add-Member -Name $TSName_Converted -Value $null -MemberType NoteProperty
            # Set converted timestamp member for each object in the Timemap
            foreach ($obj in $Timemap) {
                $obj.$TSName_Converted = [datetime]::ParseExact($obj.$TSName, 'yyyyMMddHHmmss', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
            }
        }
    }
}

function Add-HttpQueryString {
    [CmdletBinding()]
    param (
        [System.UriBuilder] $Uri,
        [Hashtable] $QueryParameter
    )

    # Create a HttpQSCollection NameValueCollection from an empty string
    $NameValCollection = [System.Web.HttpUtility]::ParseQueryString([string]::Empty)

    # Add hashtable to collection
    foreach ($key in $QueryParameter.Keys) {
        $NameValCollection.Add($key, $QueryParameter.$key)
    }

    # Set the query string
    $Uri.Query = $NameValCollection.ToString()
}

function Convert-WebContent {
    param (
        [string] $Content,
        $ContentType = $Output,
        $Headers = $FormatList
    )

    switch ($ContentType) {
        "JSON" {
            # Content is not JSON formatted. Actually CSV with square brackets.
            # Remove square brackets and curly braces.
            $ContentConverted = $Content -replace '[\[\]{}]','' | ConvertFrom-Csv
        }
        "CSV" {
            # Content is space separated. No headers provided.
            $ContentConverted = $Content | ConvertFrom-Csv -Delimiter " " -Header $Headers
        }
    }

    return $ContentConverted
}

function Invoke-WaybackTimemap {
    [CmdletBinding()]
    param (
        [ValidateNotNullOrEmpty()]
        [string] $WaybackTimeMapUri = 'https://web.archive.org/web/timemap/',
        [ValidateNotNullOrEmpty()]
        [string] $TargetUrl,
        [string] $MatchType = 'prefix',
        [string] $Collapse = 'urlkey',
        [ValidateSet('JSON','CSV')]
        [string] $Output = 'JSON',
        [array] $FormatList = @('original','mimetype','timestamp','endtimestamp','groupcount','uniqcount'),
        [string] $Filter = '!statuscode:[45]..',
        [int] $Limit = 100000,
        [string] $UserAgent = 'Mozilla/5.0'
    )

    $ht_QueryParam = @{
        url = $TargetUrl
        matchType = $MatchType.ToLower()
        collapse = $Collapse.ToLower()
        output = $Output.ToLower()
        fl = ($FormatList -join ',')
        filter = $Filter.ToLower()
        limit = $Limit
    }

    $URL_WaybackTimemap = [System.UriBuilder]::new($WaybackTimeMapUri)
    Add-HttpQueryString -Uri $URL_WaybackTimemap -QueryParameter $ht_QueryParam

    Write-Information "Request URL: $($URL_WaybackTimemap.Uri.ToString())"
    $WebReq = Invoke-WebRequest -Uri $URL_WaybackTimemap.Uri.ToString() -UserAgent $UserAgent
    $Crawled = Convert-WebContent -Content $WebReq.Content -ContentType $Output -Headers $FormatList

    if ($Crawled.Count -ge 1) {
        return $Crawled
    }
    else {
        Write-Warning "No content found at URL: $URL_WaybackTimemap"
        return $null
    }

}

################
##### Main #####
################

$Params_InvokeWaybackTimemap = @{
    WaybackTimeMapUri = $WaybackTimeMapUri
    TargetUrl = $TargetUrl
    MatchType = $MatchType
    Collapse = $Collapse
    Output = $Output
    FormatList = $FormatList
    Filter = $Filter
    Limit = $Limit
    UserAgent = $UserAgent
}

# Known returned timestamp properties
$AllTimestampNames = @(
    "timestamp"
    "endtimestamp"
)

$Timemap = Invoke-WaybackTimemap @Params_InvokeWaybackTimemap

if ($Timemap -and $ConvertTimestamp) {
    Convert-Timestamp -TimeMap $Timemap -TimestampNames $AllTimestampNames
}

return $Timemap