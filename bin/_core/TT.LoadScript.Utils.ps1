function Global:Import-ScriptFunctions {
    param (
        [string]$filepath
    )

    $initialFunctions = Get-ChildItem Function: | Select-Object -ExpandProperty Name

    . $filepath

    Get-ChildItem Function: | Where-Object { $_.Name -notin $initialFunctions } | ForEach-Object {
        $function_name = $_.Name
        # echo "[Import-ScriptFunctions]: function_name: $function_name"
        Copy-Item -Path "function:$function_name" -Destination "function:Global:$function_name"
    }
}

