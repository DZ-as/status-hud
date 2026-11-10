param(
  [Parameter(Mandatory = $true)][string]$Title,
  [Parameter(Mandatory = $true)][string]$Body,
  [string]$AppId = 'com.deepseek.dsh',
  [switch]$Sound
)

$ErrorActionPreference = 'Stop'

# Windows notification (Action Center toast) without any third-party module.
# The preferred AppUserModelID is the desktop app's own, so the toast is titled
# "DeepSeek Harness"; when that identity cannot show a toast, the registered
# PowerShell identity is used as a fallback instead of dropping the message.
$identities = @()
if (-not [string]::IsNullOrWhiteSpace($AppId)) { $identities += $AppId }
$identities += '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

try {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

  $lastError = $null
  foreach ($identity in $identities) {
    try {
      $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
        [Windows.UI.Notifications.ToastTemplateType]::ToastText02)

      $texts = $template.GetElementsByTagName('text')
      [void]$texts.Item(0).AppendChild($template.CreateTextNode($Title))
      [void]$texts.Item(1).AppendChild($template.CreateTextNode($Body))

      $audio = $template.CreateElement('audio')
      if ($Sound) {
        $audio.SetAttribute('src', 'ms-winsoundevent:Notification.Default')
      } else {
        $audio.SetAttribute('silent', 'true')
      }
      [void]$template.DocumentElement.AppendChild($audio)

      $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
      $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($identity)
      $notifier.Show($toast)
      exit 0
    } catch {
      $lastError = $_.Exception.Message
    }
  }
  Write-Error $lastError
  exit 1
} catch {
  Write-Error $_.Exception.Message
  exit 1
}
