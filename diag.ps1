Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]

# Find the correct generic AsTask overload for IAsyncOperation<T>
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and
    $_.IsGenericMethodDefinition -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

$op             = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
$genericMethod  = $asTask.MakeGenericMethod([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$task           = $genericMethod.Invoke($null, @($op))
$task.Wait()
$manager        = $task.Result

$sessions = $manager.GetSessions()
Write-Host "Session count: $($sessions.Count)"

foreach ($session in $sessions) {
    Write-Host "--- Session ---"
    Write-Host "  SourceAppUserModelId : $($session.SourceAppUserModelId)"
    Write-Host "  PlaybackStatus       : $($session.GetPlaybackInfo().PlaybackStatus)"
}

Read-Host "Press Enter to exit"