function Invoke-AzureEdgeBootstrap {
    param (
        $LocalBoxConfig,
        [PSCredential]$localCred
    )

    foreach ($node in $LocalBoxConfig.NodeHostConfig) {
        Write-Host "🛠️ Running bootstrap script on $($node.Hostname)..."
        Invoke-Command -VMName $node.Hostname -Credential $localCred -ScriptBlock {
          # & C:\startupScriptsWrapper.ps1 'C:\BootstrapPackage\bootstrap\content\Bootstrap-Setup.ps1 -Install'
          # Get-ScheduledTask -TaskName ImageCustomizationScheduledTask | Start-ScheduledTask
        }

        Write-Host "⏳ Waiting for modules and agent on $($node.Hostname)..."
        Wait-AzureEdgeBootstrap -VMName $node.Hostname -Credential $localCred
    }
}
