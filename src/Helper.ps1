<#
    Helper script containing helper functions for the LogicAppDoc and PowerAutomateDoc PowerShell scripts.
#>

Function Get-Action {

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        $Actions,
        [Parameter(Mandatory = $false)]
        $Parent = $null
    )

    foreach ($key in $Actions.PSObject.Properties.Name) {
        $action = $Actions.$key
        $actionName = $key -replace '[ |(|)|@]', '_'

        # new runafter code
        $runAfter = if (![string]::IsNullOrWhitespace($action.runafter)) {            
            $action.runAfter.PSObject.Properties.Name -replace '[ |(|)|@]', '_'
        }
        elseif (([string]::IsNullOrWhitespace($action.runafter)) -and $Parent) {
            # if Runafter is empty but has parent use parent.
            $Parent -replace '(-False|-True)', ''
        }
        else {
            # if Runafter is empty and has no parent use null.
            $null
        }
        
        $inputs = if ($action | Get-Member -MemberType Noteproperty -Name 'inputs') { 
            $($action.inputs)
        } 
        else { 
            $null 
        }

        $type = $action.type
        
        $Description = if ($action | Get-Member -MemberType Noteproperty -Name 'Description')  {
            $action.Description
        }
        else{
            $null
        }

        # new ChildActions code
        $childActions = if (($action | Get-Member -MemberType Noteproperty -Name 'Actions') -and ($action.Actions.PSObject.Properties | measure-object).count -gt 0) { $action.Actions.PSObject.Properties.Name } else { $null }
        
        # Create PSCustomObject
        [PSCustomObject]@{
            ActionName   = $actionName
            RunAfter     = $runAfter
            Type         = $type
            Parent       = $Parent
            ChildActions = $childActions
            Comment      = $description
            Inputs       = if ($inputs) {
                Format-HTMLInputContent -Inputs $(Remove-Secrets -Inputs $($inputs | ConvertTo-Json -Depth 10 -Compress))
            }
            else {
                $null | ConvertTo-Json
            } # Output is a json string
        }

        if ($action.type -eq 'If') {
            # Check if the else property is present
            if ($action | Get-Member -MemberType Noteproperty -Name 'else') {
                # Get the actions for the true condition
                Write-Verbose -Message ('Processing action {0}' -f $actionName)
                # Check if Action has any actions for the true condition
                if (![string]::IsNullOrEmpty($action.actions)) { 
                    Get-Action -Actions $($action.Actions) -Parent ('{0}-True' -f $actionName)
                    # Get the actions for the false condition
                    Get-Action -Actions $($action.else.Actions) -Parent ('{0}-False' -f $actionName)
                }
            }
            #When there is only action for the true condition
            else {
                Get-Action -Actions $($action.Actions) -Parent ('{0}-True' -f $actionName)
            }
        }

        # Recursively call the function for child actions
        elseif ($action | Get-Member -MemberType Noteproperty -Name 'Actions') {
            Get-Action -Actions $($action.Actions) -Parent $actionName
        }
    }   
}

Function Sort-Action {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        $Actions
    )

    # Turn input into an array. Otherwise count will not work.
    $Actions = @($Actions)

    # Search for the action that has an empty RunAfter property
    $firstAction = $Actions | Where-Object { [string]::IsNullOrEmpty($_.RunAfter) } |
    Add-Member -MemberType NoteProperty -Name Order -Value 0 -PassThru
    $currentAction = $firstAction

    # Define a variable to hold the current order index
    $indexNumber = 1

    #Loop through all the actions
    Write-Verbose -Message ('Sorting {0} Actions' -f $($Actions.Count))
    for ($i = 1; $i -lt $Actions.Count; $i++) {
        Write-Verbose -Message ('Processing currentaction {0} number {1} of {2} Actions in total' -f $($currentAction.ActionName), $i, $($Actions.Count))
        # Search for the action that has the first action's ActionName in the RunAfter property or the previous action's ActionName
        if (![string]::IsNullOrEmpty($firstAction)) {
            $Actions | Where-Object { $_.RunAfter -eq $firstAction.ActionName } | 
            Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber
            $currentAction = ($Actions | Where-Object { $_.RunAfter -eq $firstAction.ActionName })
            # Set the firstAction variable to null
            $firstAction = $null            
            $indexNumber++ 
        }
        else {
            # Search for actions that have the previous action's ActionName in the RunAfter property
            # If there are multiple actions with the same RunAfter property, set the RunAfter property to the Parent property
            if (($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) } | Measure-Object).count -gt 1) {
                $Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) } | ForEach-Object {                     
                    # Check if the action has a Parent Value
                    if (![string]::IsNullOrEmpty($_.Parent)) {
                        Write-Verbose -Message ('Setting RunAfter property {0} to Parent property value {1} for action {2}' -f $_.RunAfter, $_.Parent, $_.ActionName)
                        $_.RunAfter = $_.Parent
                    }
                    else {
                        Write-Verbose -Message ('Current action {0} with RunAfter property {1} has no Parent property' -f $_.ActionName, $_.RunAfter)
                    }
                }
                # Iterate first the condition status true actions.
                if ($Actions | Where-Object { $_.RunAfter -eq $(('{0}-True') -f $($currentAction.ActionName)) }) {
                    $Actions | Where-Object { $_.RunAfter -eq $(('{0}-True') -f $($currentAction.ActionName)) }  |
                    Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber
                    $currentAction = $Actions | Where-Object { $_.RunAfter -eq $(('{0}-True') -f $($currentAction.ActionName)) }
                    # Increment the indexNumber
                    $indexNumber++
                }   
                else {
                    # Add Order property to the action that it's RunAfter property updated from the Parent property.
                    # This is the first action in a foreach loop.
                    # After this action the rest of rest of the foreach actions need to be processed.
                    if ($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) -and ($null -ne $($_.Parent)) } ) {
                        $Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) -and ($null -ne $($_.Parent)) } |
                        Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                        $currentAction = $Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) -and ($null -ne $($_.Parent)) }
                        # Increment the indexNumber
                        $indexNumber++
                    }
                    else {
                        # There is another action with the same RunAfter property that runs parallel with the current action.
                        # Start with the first action that has the same RunAfter property.
                        if ($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) }) {
                            $($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) })[0] | 
                            Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                            # CurrentAction will be empty if the ???
                            $currentAction = $($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) })[0]
                            # Increment the indexNumber
                            $indexNumber++                    
                        }
                    }                    
                }             
            }
            else {
                # If there cannot any action found with the previous action's ActionName in the RunAfter property, search for the action has a parent with the false condition.
                if ($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) }) {
                    $Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) } | 
                    Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                    # CurrentAction will be empty if the ??
                    $currentAction = ($Actions | Where-Object { $_.RunAfter -eq $($currentAction.ActionName) })
                    # Increment the indexNumber
                    $indexNumber++                    
                }
                # Current error is that there can be an newly created action that does not have a paret property.???
                elseif ($Actions | Where-Object { $_.RunAfter -eq $(('{0}-False') -f $(($currentAction.Parent).Substring(0, ($currentAction.Parent).length - 5))) } ) {
                    $Actions | Where-Object { $_.RunAfter -eq $(('{0}-False') -f $(($currentAction.Parent).Substring(0, ($currentAction.Parent).length - 5))) }  |
                    Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                    # Fix the issue when currentAction is empty
                    if ($Actions | Where-Object { $_.RunAfter -eq $(('{0}-False') -f $(($currentAction.Parent).Substring(0, ($currentAction.Parent).length - 5))) }) {
                        $currentAction = $Actions | Where-Object { $_.RunAfter -eq $(('{0}-False') -f $(($currentAction.Parent).Substring(0, ($currentAction.Parent).length - 5))) }
                    }
                    # Increment the indexNumber
                    $indexNumber++
                }
                else {
                    # If there cannot any action found with the previous action's ActionName in the RunAfter property, search for the action has a parent with the same name as the currents action's runasfter property.
                    if ($Actions | Where-Object { $_.RunAfter -eq $($currentAction.Parent) -and !($_ | Get-Member -MemberType NoteProperty 'Order') }) {
                        $Actions | Where-Object { $_.RunAfter -eq $($currentAction.Parent) -and !($_ | Get-Member -MemberType NoteProperty 'Order') } | 
                        Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                        # CurrentAction will be empty if the ??
                        $currentAction = ($Actions | Where-Object { ($_ | Get-Member -MemberType NoteProperty 'Order') -and ($_.Order -eq $indexNumber) })
                        # Increment the indexNumber
                        $indexNumber++                    
                    }
                    else {
                        # When an action runs after a condition find orderid of last condition actionname
                        if ($Actions | Where-Object { !($_ | Get-Member -MemberType NoteProperty 'Order') -and (![string]::IsNullOrEmpty($_.Parent)) }) {
                            $Actions | Where-Object { !($_ | Get-Member -MemberType NoteProperty 'Order') -and (![string]::IsNullOrEmpty($_.Parent)) } | 
                            Add-Member -MemberType NoteProperty -Name Order -Value $indexNumber 
                            # CurrentAction
                            $currentAction = ($Actions | Where-Object { ($_ | Get-Member -MemberType NoteProperty 'Order') -and ($_.Order -eq $indexNumber) })
                            # Increment the indexNumber
                            $indexNumber++
                        }
                    }
                }
            }                
        }
        Write-Verbose -Message ('Current action {0} with Order Id {1}' -f $($currentAction.ActionName), $($currentAction.Order) )
    }
}

Function Get-Connection {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        $Connection
    )

    foreach ($key in $Connection.PSObject.Properties) {
        [PSCustomObject]@{
            Name                 = $key.name
            ConnectionId         = $key.Value.connectionId
            ConnectionName       = $key.Value.connectionName
            ConnectionProperties = if ($key.Value | Get-Member -MemberType NoteProperty connectionProperties) { $key.Value.connectionProperties } else { $null }
            id                   = $key.Value.id
        } 
    }
}

Function Remove-Secrets {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        $Inputs
    )

    # Remove the secrets from the Logic App Inputs
    $regexPattern = '(\"headers":\{"Authorization":"(Bearer|Basic) )[^"]*'
    $Inputs -replace $regexPattern, '$1******'
}

# When the input contains a HTML input content, this needs to be wrapped within a <textarea disabled> and </textarea> tag.
Function Format-HTMLInputContent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        $Inputs
    )

    # If Input contains HTML input content, remove '\n characters and wrap the input within a <textarea disabled> and </textarea> tag.
    if ($Inputs -match '<html>') {
        Write-Verbose -Message ('Found HTML input content in Action Inputs')
        $($Inputs -replace '\\n', '') -replace '<html>', '<textarea disabled><html>' -replace '</html>', '</html></textarea>'
    }
    else {
        $Inputs
    }
}
