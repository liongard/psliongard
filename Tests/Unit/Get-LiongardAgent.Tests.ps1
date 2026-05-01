#requires -Version 5.1
BeforeAll {
    Import-Module "$PSScriptRoot\..\..\PSLiongard.psd1" -Force
}

$commonParams = @{
    LiongardURL = 'test.app.liongard.com'
    ApiKey      = 'key'
    ApiSecret   = 'secret'
}

Describe "Get-LiongardAgent" {
    Context "ByName - successful v1 lookup" {
        BeforeEach {
            Mock Invoke-LiongardApi -ModuleName PSLiongard -MockWith {
                [PSCustomObject]@{
                    Success = $true
                    Data    = @([PSCustomObject]@{ ID = 7; Name = 'TestAgent' })
                }
            }
        }

        It "returns the matching agent object" {
            $result = Get-LiongardAgent @commonParams -Name 'TestAgent'
            $result.ID   | Should -Be 7
            $result.Name | Should -Be 'TestAgent'
        }

        It "only calls the v1 endpoint when v1 succeeds" {
            Get-LiongardAgent @commonParams -Name 'TestAgent'
            Should -Invoke Invoke-LiongardApi -ModuleName PSLiongard -Times 1 -ParameterFilter {
                $Endpoint -like '/api/v1/agents*'
            }
        }

        It "returns null when the name is not in the response" {
            $result = Get-LiongardAgent @commonParams -Name 'Ghost'
            $result | Should -BeNullOrEmpty
        }
    }

    Context "ByName - v1 fails, falls back to v2" {
        BeforeEach {
            Mock Invoke-LiongardApi -ModuleName PSLiongard `
                -ParameterFilter { $Endpoint -like '/api/v1*' } `
                -MockWith { [PSCustomObject]@{ Success = $false; Data = $null } }

            Mock Invoke-LiongardApi -ModuleName PSLiongard `
                -ParameterFilter { $Endpoint -like '/v2*' } `
                -MockWith {
                    [PSCustomObject]@{
                        Success = $true
                        Data    = @([PSCustomObject]@{ ID = 7; Name = 'TestAgent' })
                    }
                }
        }

        It "returns the agent from the v2 response" {
            $result = Get-LiongardAgent @commonParams -Name 'TestAgent'
            $result.ID | Should -Be 7
        }

        It "calls both the v1 and v2 endpoints" {
            Get-LiongardAgent @commonParams -Name 'TestAgent'
            Should -Invoke Invoke-LiongardApi -ModuleName PSLiongard -Times 1 `
                -ParameterFilter { $Endpoint -like '/api/v1*' }
            Should -Invoke Invoke-LiongardApi -ModuleName PSLiongard -Times 1 `
                -ParameterFilter { $Endpoint -like '/v2*' }
        }
    }

    Context "ByID" {
        BeforeEach {
            Mock Invoke-LiongardApi -ModuleName PSLiongard -MockWith {
                [PSCustomObject]@{
                    Success = $true
                    Data    = [PSCustomObject]@{ ID = 42; Name = 'AgentByID' }
                }
            }
        }

        It "returns the agent with the given ID" {
            $result = Get-LiongardAgent @commonParams -ID 42
            $result.ID | Should -Be 42
        }

        It "returns null when both API versions fail" {
            Mock Invoke-LiongardApi -ModuleName PSLiongard -MockWith {
                [PSCustomObject]@{ Success = $false; Data = $null }
            }
            $result = Get-LiongardAgent @commonParams -ID 999
            $result | Should -BeNullOrEmpty
        }
    }

    Context "ByConditions" {
        BeforeEach {
            Mock Invoke-LiongardApi -ModuleName PSLiongard -MockWith {
                [PSCustomObject]@{
                    Success = $true
                    Data    = @([PSCustomObject]@{ ID = 1; Name = 'Agent1'; MachineGuid = 'abc-123' })
                }
            }
        }

        It "URL-encodes the conditions string in the endpoint" {
            Get-LiongardAgent @commonParams -Conditions "MachineGuid = 'abc-123'"
            Should -Invoke Invoke-LiongardApi -ModuleName PSLiongard -ParameterFilter {
                $Endpoint -like '/api/v1/agents?conditions=*' -and $Endpoint -notlike "*'*"
            }
        }

        It "returns an array of matching agents" {
            $result = Get-LiongardAgent @commonParams -Conditions "MachineGuid = 'abc-123'"
            $result | Should -HaveCount 1
            $result[0].ID | Should -Be 1
        }

        It "returns an empty array when no agents match" {
            Mock Invoke-LiongardApi -ModuleName PSLiongard -MockWith {
                [PSCustomObject]@{ Success = $false; Data = $null }
            }
            $result = Get-LiongardAgent @commonParams -Conditions "MachineGuid = 'no-match'"
            $result | Should -HaveCount 0
        }
    }
}
