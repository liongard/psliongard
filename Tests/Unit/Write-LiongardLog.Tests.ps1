#requires -Version 5.1
BeforeAll {
    Import-Module "$PSScriptRoot\..\..\PSLiongard.psd1" -Force
}

Describe "Write-LiongardLog" {
    BeforeEach {
        # Mock Write-Host inside the module scope so we can assert on calls without
        # producing console output during the test run.
        Mock Write-Host -ModuleName PSLiongard {}
    }

    Context "output format" {
        It "includes an ISO-style timestamp in the output" {
            Write-LiongardLog "check format"
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $Object -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]'
            }
        }

        It "includes the severity label in the output" {
            Write-LiongardLog "check label" -Level WARNING
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $Object -match '\[WARNING\]'
            }
        }

        It "includes the message text in the output" {
            Write-LiongardLog "unique message content"
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $Object -match 'unique message content'
            }
        }
    }

    Context "severity levels" {
        It "defaults to INFO when no Level is specified" {
            Write-LiongardLog "default level"
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $Object -match '\[INFO\]' -and $ForegroundColor -eq 'White'
            }
        }

        It "uses Yellow for WARNING" {
            Write-LiongardLog "warning message" -Level WARNING
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $ForegroundColor -eq 'Yellow'
            }
        }

        It "uses Red for ERROR" {
            Write-LiongardLog "error message" -Level ERROR
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $ForegroundColor -eq 'Red'
            }
        }

        It "uses Green for SUCCESS" {
            Write-LiongardLog "success message" -Level SUCCESS
            Should -Invoke Write-Host -ModuleName PSLiongard -ParameterFilter {
                $ForegroundColor -eq 'Green'
            }
        }
    }

    Context "parameter validation" {
        It "throws when Message is empty" {
            { Write-LiongardLog "" } | Should -Throw
        }

        It "rejects an unrecognised Level value" {
            { Write-LiongardLog "msg" -Level "VERBOSE" } | Should -Throw
        }
    }
}
