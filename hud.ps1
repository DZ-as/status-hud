param(
  [Parameter(Mandatory = $true)][string]$StatusPath,
  [string]$Anchor = 'top-center',
  [string]$OpenUrl = '',
  [string]$HideUrl = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace HudStatus {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static class Native {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  }
}
'@

$statusDir = [System.IO.Path]::GetDirectoryName($StatusPath)
$logPath = Join-Path $statusDir 'hud.log'
$script:SignalPath = Join-Path $statusDir 'event.signal'
function Write-HudLog([string]$Message) {
  try { Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('s') + ' ' + $Message) -Encoding UTF8 } catch {}
}

# Flush with the top edge of the screen: the whole 0..24px band is live, so
# flicking the pointer at the top edge always lands on the bar.
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH Status"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        Width="264" SizeToContent="Height" WindowStartupLocation="Manual"
        FontFamily="Microsoft YaHei UI, Segoe UI, sans-serif"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <StackPanel x:Name="Root" Background="Transparent">
    <Grid x:Name="BarRow" Height="24" Background="Transparent"/>
    <Border x:Name="Panel" Width="440" Margin="0,14,0,0" CornerRadius="14" Background="#FF0F1115"
            BorderBrush="#2EFFFFFF" BorderThickness="1" Padding="10,10,10,8" Visibility="Collapsed">
      <Border.RenderTransform>
        <TranslateTransform x:Name="PanelShift" Y="-10"/>
      </Border.RenderTransform>
      <StackPanel>
        <Border x:Name="EventBar" Visibility="Collapsed" CornerRadius="8" Padding="9,6" Margin="0,0,0,8" Background="#1A22C55E">
          <TextBlock x:Name="EventText" Text="" Foreground="#D7F5E3" FontSize="11.5" TextWrapping="Wrap"/>
        </Border>
        <ScrollViewer x:Name="Scroller" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
          <StackPanel x:Name="Columns" Orientation="Horizontal"/>
        </ScrollViewer>
        <TextBlock x:Name="HintText" Text="click a session to jump" Foreground="#4C5665" FontSize="10" Margin="0,8,0,0"/>
      </StackPanel>
    </Border>
  </StackPanel>
</Window>
'@

try {
  $window = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
  Write-HudLog ('xaml parse failed: ' + $_.Exception.Message)
  throw
}

$script:Window = $window
$script:BarRow = $window.FindName('BarRow')
$script:Panel = $window.FindName('Panel')
$script:PanelShift = $window.FindName('PanelShift')
$script:EventBar = $window.FindName('EventBar')
$script:EventText = $window.FindName('EventText')
$script:Scroller = $window.FindName('Scroller')
$script:Columns = $window.FindName('Columns')
$script:HintText = $window.FindName('HintText')

$script:Expanded = $null
$script:ReadyAt = [DateTime]::Now.AddMilliseconds(700)
$script:MissTicks = 0
$script:HoverSince = $null
$script:Tick = 0
$script:AutoUntil = $null
$script:AutoKind = ''
$script:LastEventAt = 0
$script:Sessions = @()
$script:Segments = @()
$script:SegTransforms = @()
$script:SegScales = @()
$script:Cards = @()
$script:CardRefs = @()
$script:Signature = ''
$script:SignalSeen = ''
$script:ForceRefresh = $false
$script:BarWidth = 240
$script:PanelWidth = 440
$script:HoverIndex = -1
$script:DragFrom = $null
$script:DragOffset = 0
$script:PressX = 0
$script:HoldCard = $null
$script:HoldId = ""
$script:HoldSince = $null
$script:HoldParts = $null
$script:CursorX = -1
$script:CursorY = -1
$script:RectLeft = 0
$script:RectTop = 0

$COL_W = 190
$MAX_COLS = 6
$SEG_W = 64
$SEG_H = 6
$HOT_H = 4
$HOLD_MS = 650
$DWELL_MS = 0

$stateColors = @{
  'running' = '#4C8DFF'
  'waiting' = '#F5A524'
  'done'    = '#22C55E'
  'error'   = '#EF4444'
  'idle'    = '#64748B'
}
$eventColors = @{
  'done'    = @{ bg = '#1A22C55E'; fg = '#BBF7D0' }
  'error'   = @{ bg = '#1AEF4444'; fg = '#FECACA' }
  'waiting' = @{ bg = '#1AF5A524'; fg = '#FDE68A' }
}

function Brush([string]$hex) {
  return (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)))
}

function Ease-Out {
  $ease = New-Object System.Windows.Media.Animation.CubicEase
  $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  return $ease
}

function Ease-In {
  $ease = New-Object System.Windows.Media.Animation.CubicEase
  $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
  return $ease
}

function StateColor([string]$state) {
  $c = $stateColors[$state]
  if (-not $c) { $c = '#64748B' }
  return $c
}

function Read-Shared([string]$path) {
  # Share ReadWrite+Delete: a plain read blocks the writer's atomic rename.
  $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
  $stream = New-Object System.IO.FileStream $path, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), $share
  try {
    $reader = New-Object System.IO.StreamReader $stream, ([System.Text.Encoding]::UTF8)
    return $reader.ReadToEnd()
  } finally {
    $stream.Dispose()
  }
}

function Read-Status {
  if (-not (Test-Path -LiteralPath $StatusPath)) { return $null }
  try {
    $raw = Read-Shared $StatusPath
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Format-Elapsed([double]$seconds) {
  if ($seconds -lt 0) { $seconds = 0 }
  $total = [int][math]::Floor($seconds)
  $m = [int][math]::Floor($total / 60)
  $s = $total % 60
  if ($m -ge 60) {
    $h = [int][math]::Floor($m / 60)
    return ('{0}:{1:00}:{2:00}' -f $h, ($m % 60), $s)
  }
  return ('{0}:{1:00}' -f $m, $s)
}

function Apply-Position {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $w = $script:Window.ActualWidth
  $h = $script:Window.ActualHeight
  if ($w -le 0) { $w = $script:BarWidth }
  if ($h -le 0) { $h = 20 }
  switch ($Anchor) {
    'top-left' { $script:Window.Left = $wa.Left; $script:Window.Top = $wa.Top }
    'top-right' { $script:Window.Left = $wa.Right - $w; $script:Window.Top = $wa.Top }
    'bottom-left' { $script:Window.Left = $wa.Left; $script:Window.Top = $wa.Bottom - $h }
    'bottom-right' { $script:Window.Left = $wa.Right - $w; $script:Window.Top = $wa.Bottom - $h }
    default {
      $script:Window.Left = $wa.Left + [math]::Round(($wa.Width - $w) / 2)
      $script:Window.Top = $wa.Top
    }
  }
}

# Hover is sampled from the real cursor position: the window is click-through
# while collapsed, so it never sees mouse messages itself.
function Test-Hover {
  try {
    $p = New-Object -TypeName HudStatus.POINT
    if (-not [HudStatus.Native]::GetCursorPos([ref]$p)) { return $false }
    $helper = New-Object -TypeName System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
    $r = New-Object -TypeName HudStatus.RECT
    if (-not [HudStatus.Native]::GetWindowRect($helper.Handle, [ref]$r)) { return $false }
    $script:CursorX = $p.X
    $script:CursorY = $p.Y
    $script:RectLeft = $r.Left
    $script:RectTop = $r.Top
    if ($p.X -lt $r.Left -or $p.X -ge $r.Right) { return $false }
    if ($p.Y -lt $r.Top) { return $false }
    # Collapsed: only the thin strip is hot, so brushing the top edge of a
    # browser toolbar does not open the panel.
    if (-not $script:Expanded) { return ($p.Y -lt ($r.Top + $HOT_H)) }
    return ($p.Y -lt $r.Bottom)
  } catch {
    return $false
  }
}

function Set-ClickThrough([bool]$on) {
  try {
    $helper = New-Object -TypeName System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
    $hwnd = $helper.Handle
    $ex = [HudStatus.Native]::GetWindowLong($hwnd, -20)
    if ($on) { $ex = $ex -bor 0x00000020 } else { $ex = $ex -band (-bnot 0x00000020) }
    [void][HudStatus.Native]::SetWindowLong($hwnd, -20, $ex)
    # Without a frame change the OS keeps using the old hit-test region.
    [void][HudStatus.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0227)
  } catch {
    Write-HudLog ('click-through failed: ' + $_.Exception.Message)
  }
}

# ------------------------------------------------------------------ bar

function New-Segment([string]$state) {
  $seg = New-Object System.Windows.Controls.Border
  $seg.CornerRadius = (New-Object System.Windows.CornerRadius 3)
  $seg.Background = Brush (StateColor $state)
  $translate = New-Object System.Windows.Media.TranslateTransform(0, 0)
  $scale = New-Object System.Windows.Media.ScaleTransform(1, 1)
  $group = New-Object System.Windows.Media.TransformGroup
  $group.Children.Add($scale)
  $group.Children.Add($translate)
  $seg.RenderTransform = $group
  $seg.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5
  return @{ Segment = $seg; Translate = $translate; Scale = $scale }
}

# The bar keeps one fixed pitch in both states: a segment never moves when the
# panel opens, and segment i always sits above column i.
function Build-Bar($sessions) {
  $list = @($sessions)
  $count = [math]::Max(1, $list.Count)
  $script:BarRow.Children.Clear()
  $script:Segments = @()
  $script:SegTransforms = @()
  $script:SegScales = @()

  $pitch = $COL_W
  if ($count -gt $MAX_COLS) { $pitch = [math]::Floor((($MAX_COLS * $COL_W)) / $count) }
  $script:BarWidth = $count * $pitch

  $grid = New-Object System.Windows.Controls.Grid
  $grid.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $grid.Margin = (New-Object System.Windows.Thickness 0, 3, 0, 0)
  for ($i = 0; $i -lt $count; $i++) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = New-Object System.Windows.GridLength $pitch
    [void]$grid.ColumnDefinitions.Add($col)
  }
  for ($i = 0; $i -lt $count; $i++) {
    $state = 'idle'
    if ($i -lt $list.Count) { $state = [string]$list[$i].state }
    $parts = New-Segment $state
    $seg = $parts.Segment
    # Fill the pitch so the bar reads as one segmented line instead of a few
    # scattered dashes; segment i still sits exactly above card i.
    $seg.Width = [math]::Max(24, $pitch - 12)
    $seg.Height = $SEG_H
    $seg.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $seg.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
    [System.Windows.Controls.Grid]::SetColumn($seg, $i)
    [void]$grid.Children.Add($seg)
    $script:Segments += $seg
    $script:SegTransforms += $parts.Translate
    $script:SegScales += $parts.Scale
  }
  [void]$script:BarRow.Children.Add($grid)
}

function Update-Segments($sessions) {
  $list = @($sessions)
  for ($i = 0; $i -lt $script:Segments.Count; $i++) {
    $state = 'idle'
    if ($i -lt $list.Count) { $state = [string]$list[$i].state }
    $seg = $script:Segments[$i]
    $seg.Background = Brush (StateColor $state)
    if ($script:HoverIndex -ge 0) {
      if ($i -eq $script:HoverIndex) { $seg.Opacity = 1.0 } else { $seg.Opacity = 0.4 }
    } elseif ($state -eq 'waiting') {
      $seg.Opacity = 0.6
    } else {
      $seg.Opacity = 1.0
    }
  }
}

# -------------------------------------------------------------- columns

function New-Card($session) {
  $state = [string]$session.state
  $card = New-Object System.Windows.Controls.Border
  $card.Width = $COL_W - 10
  $card.Margin = (New-Object System.Windows.Thickness 5, 0, 5, 0)
  $card.CornerRadius = (New-Object System.Windows.CornerRadius 10)
  $card.Background = Brush '#14FFFFFF'
  $card.BorderThickness = (New-Object System.Windows.Thickness 1)
  $card.BorderBrush = Brush '#00000000'
  $card.Padding = (New-Object System.Windows.Thickness 10, 9, 10, 9)
  $card.Tag = [string]$session.id
  $card.Cursor = [System.Windows.Input.Cursors]::Hand
  $cardScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
  $card.RenderTransform = $cardScale
  $card.RenderTransformOrigin = New-Object System.Windows.Point 0.5, 0.5

  $stack = New-Object System.Windows.Controls.StackPanel

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8
  $dot.Height = 8
  $dot.Fill = Brush (StateColor $state)

  $head = New-Object System.Windows.Controls.StackPanel
  $head.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $dot.Margin = (New-Object System.Windows.Thickness 0, 4, 6, 0)
  [void]$head.Children.Add($dot)

  $title = New-Object System.Windows.Controls.TextBlock
  $title.Text = [string]$session.title
  $title.Foreground = Brush '#F2F5F9'
  $title.FontSize = 12
  $title.FontWeight = [System.Windows.FontWeights]::SemiBold
  $title.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $title.MaxHeight = 34
  $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$head.Children.Add($title)
  [void]$stack.Children.Add($head)

  $workspace = New-Object System.Windows.Controls.TextBlock
  $workspace.Text = [string]$session.workspace
  $workspace.Foreground = Brush '#5C6778'
  $workspace.FontSize = 10
  $workspace.Margin = (New-Object System.Windows.Thickness 14, 2, 0, 0)
  $workspace.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$stack.Children.Add($workspace)

  $stateText = New-Object System.Windows.Controls.TextBlock
  $stateText.Text = [string]$session.stateText
  $stateText.Foreground = Brush (StateColor $state)
  $stateText.FontSize = 11
  $stateText.Margin = (New-Object System.Windows.Thickness 14, 6, 0, 0)
  $stateText.TextWrapping = [System.Windows.TextWrapping]::Wrap
  [void]$stack.Children.Add($stateText)

  $action = New-Object System.Windows.Controls.TextBlock
  $action.Text = [string]$session.detail
  $action.Foreground = Brush '#B6C2D2'
  $action.FontSize = 10.5
  $action.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $action.MaxHeight = 44
  $action.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $action.Margin = (New-Object System.Windows.Thickness 14, 5, 0, 0)
  [void]$stack.Children.Add($action)

  $facts = New-Object System.Windows.Controls.TextBlock
  $facts.Text = [string]$session.facts
  $facts.Foreground = Brush '#4E5866'
  $facts.FontSize = 10
  $facts.Margin = (New-Object System.Windows.Thickness 14, 7, 0, 0)
  $facts.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$stack.Children.Add($facts)

  # Remove overlay: the card content blurs behind a dim layer, with a trash
  # glyph and a circular progress ring that fills while the right button is held.
  $dim = New-Object System.Windows.Controls.Border
  $dim.Background = Brush '#B30B0D10'
  $dim.Visibility = 'Collapsed'
  $dim.IsHitTestVisible = $false

  $ring = New-Object System.Windows.Shapes.Path
  $ring.Stroke = Brush '#FCA5A5'
  $ring.StrokeThickness = 2.5
  $ring.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $ring.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round

  $ringBack = New-Object System.Windows.Shapes.Ellipse
  $ringBack.Width = 44
  $ringBack.Height = 44
  $ringBack.Stroke = Brush '#3DFFFFFF'
  $ringBack.StrokeThickness = 2.5

  $trash = New-Object System.Windows.Shapes.Path
  $trash.Stroke = Brush '#FCA5A5'
  $trash.StrokeThickness = 1.6
  $trash.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $trash.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $trash.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
  $trash.Data = [Windows.Media.Geometry]::Parse('M 1,3.6 L 15,3.6 M 5.6,3.6 L 5.6,1.4 L 10.4,1.4 L 10.4,3.6 M 2.8,3.6 L 3.8,14.4 L 12.2,14.4 L 13.2,3.6 M 6.1,6.4 L 6.5,11.8 M 9.9,6.4 L 9.5,11.8')
  $trash.Width = 20
  $trash.Height = 20
  $trash.Stretch = [System.Windows.Media.Stretch]::Uniform
  $trash.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $trash.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $trash.Margin = (New-Object System.Windows.Thickness 0, 1, 0, 0)

  $overlay = New-Object System.Windows.Controls.Grid
  $overlay.Width = 44
  $overlay.Height = 44
  $overlay.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $overlay.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $overlay.Visibility = 'Collapsed'
  $overlay.IsHitTestVisible = $false
  [void]$overlay.Children.Add($ringBack)
  [void]$overlay.Children.Add($ring)
  [void]$overlay.Children.Add($trash)

  $layers = New-Object System.Windows.Controls.Grid
  [void]$layers.Children.Add($stack)
  [void]$layers.Children.Add($dim)
  [void]$layers.Children.Add($overlay)
  $card.Child = $layers

  return @{
    Card      = $card
    Shift     = $cardShift
    Stack     = $stack
    Dim       = $dim
    Overlay   = $overlay
    Ring      = $ring
    Dot       = $dot
    DotBrush  = $dotBrush
    StateBrush = $stateBrush
    Title     = $title
    Workspace = $workspace
    StateText = $stateText
    Action    = $action
    Facts     = $facts
  }
}

function New-ArcGeometry([double]$size, [double]$angleDeg) {
  $r = ($size / 2) - 2
  $c = $size / 2
  $angle = [math]::Max(1, [math]::Min(359.9, $angleDeg))
  $rad = ($angle - 90) * [math]::PI / 180
  $geo = New-Object System.Windows.Media.PathGeometry
  $fig = New-Object System.Windows.Media.PathFigure
  $fig.StartPoint = New-Object System.Windows.Point $c, ($c - $r)
  $seg = New-Object System.Windows.Media.ArcSegment
  $seg.Point = New-Object System.Windows.Point ($c + $r * [math]::Cos($rad)), ($c + $r * [math]::Sin($rad))
  $seg.Size = New-Object System.Windows.Size $r, $r
  $seg.IsLargeArc = ($angle -gt 180)
  $seg.SweepDirection = [System.Windows.Media.SweepDirection]::Clockwise
  [void]$fig.Segments.Add($seg)
  [void]$geo.Figures.Add($fig)
  return $geo
}

# The index and session id live in the card Tag: a scriptblock created in a
# function does not keep that function's locals when it runs later.
function Add-CardHandlers($card) {
  $card.Add_MouseEnter({
      param($sender, $e)
      try {
        $parts = ([string]$sender.Tag).Split('|')
        if ($parts.Count -ge 2) { Set-Hover ([int]$parts[0]) }
      } catch {}
    })
  $card.Add_MouseLeave({ Clear-Hover; Cancel-Hold })
  $card.Add_MouseRightButtonDown({
      param($sender, $e)
      $e.Handled = $true
      $parts = ([string]$sender.Tag).Split('|')
      if ($parts.Count -ge 2) { Start-Hold $sender ([string]$parts[1]) ([int]$parts[0]) }
    })
  $card.Add_MouseRightButtonUp({
      param($sender, $e)
      $e.Handled = $true
      Cancel-Hold
    })
  $card.Add_MouseLeftButtonUp({
      param($sender, $e)
      try {
        $dx = [math]::Abs($e.GetPosition($script:Scroller).X - $script:PressX)
        if ($dx -gt 6) { return }
        $parts = ([string]$sender.Tag).Split('|')
        if ($parts.Count -ge 2) { Send-Open ([string]$parts[1]) }
      } catch {}
    })
}

function Build-Columns($sessions) {
  $script:Columns.Children.Clear()
  $script:Cards = @()
  $script:CardRefs = @()
  $index = 0
  foreach ($s in @($sessions)) {
    $parts = New-Card $s
    $parts.Card.Tag = ('{0}|{1}' -f $index, [string]$s.id)
    $holder = New-Object System.Windows.Controls.Border
    $holder.Width = $COL_W
    $holder.Child = $parts.Card
    [void]$script:Columns.Children.Add($holder)
    Add-CardHandlers $parts.Card
    $script:Cards += $parts.Card
    $script:CardRefs += $parts
    $index += 1
  }
}

function Apply-CardStyles {
  for ($i = 0; $i -lt $script:Cards.Count; $i++) {
    $state = 'idle'
    if ($i -lt @($script:Sessions).Count) { $state = [string]$script:Sessions[$i].state }
    $card = $script:Cards[$i]
    if ($script:HoverIndex -eq $i) {
      $card.Background = Brush '#33FFFFFF'
      $card.BorderBrush = Brush (StateColor $state)
      $card.Opacity = 1.0
    } elseif ($state -eq 'waiting') {
      # a session that needs an answer keeps an amber frame until it is handled
      $card.Background = Brush '#24F5A524'
      $card.BorderBrush = Brush '#F5A524'
      $card.Opacity = 1.0
    } elseif ($script:HoverIndex -ge 0) {
      $card.Background = Brush '#14FFFFFF'
      $card.BorderBrush = Brush '#00000000'
      $card.Opacity = 0.5
    } else {
      $card.Background = Brush '#14FFFFFF'
      $card.BorderBrush = Brush '#00000000'
      $card.Opacity = 1.0
    }
  }
}

function Clear-Hover {
  if ($script:HoverIndex -lt 0) { return }
  $script:HoverIndex = -1
  Apply-CardStyles
  for ($i = 0; $i -lt $script:SegTransforms.Count; $i++) {
    Move-Segment $i 0
  }
  Update-Segments $script:Sessions
}

function Start-Hold($card, [string]$id, [int]$index) {
  $script:HoldCard = $card
  $script:HoldId = $id
  $script:HoldSince = [DateTime]::Now
  $script:HoldParts = $null
  if ($index -lt 0 -or $index -ge $script:CardRefs.Count) { return }
  $parts = $script:CardRefs[$index]
  $script:HoldParts = $parts
  $card.BorderBrush = Brush '#EF4444'
  # A BlurEffect on this per-pixel-alpha window drops the whole surface into
  # software rendering and the progress ring visibly stalls, so the content is
  # pushed back with opacity instead.
  $parts.Stack.Opacity = 0.3
  $parts.Dim.Visibility = 'Visible'
  $parts.Overlay.Visibility = 'Visible'
  $parts.Ring.Data = New-ArcGeometry 44 1
}

function Stop-HoldVisuals {
  $parts = $script:HoldParts
  $script:HoldParts = $null
  if (-not $parts) { return }
  $parts.Stack.Opacity = 1.0
  $parts.Dim.Visibility = 'Collapsed'
  $parts.Overlay.Visibility = 'Collapsed'
  $parts.Card.BorderBrush = Brush '#00000000'
  $parts.Card.Background = Brush '#14FFFFFF'
}

function Cancel-Hold {
  if ($null -eq $script:HoldSince) { return }
  $script:HoldSince = $null
  $script:HoldId = ''
  $script:HoldCard = $null
  Stop-HoldVisuals
  Clear-Hover
}

function Move-Segment([int]$index, [double]$to) {
  if ($index -lt 0 -or $index -ge $script:SegTransforms.Count) { return }
  $transform = $script:SegTransforms[$index]
  $current = 0.0
  try { $current = [double]$transform.Y } catch {}
  $dur = New-Object -TypeName System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(130))
  $anim = New-Object -TypeName System.Windows.Media.Animation.DoubleAnimation -ArgumentList @($current, $to, $dur)
  $anim.EasingFunction = Ease-Out
  $transform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $anim)
}

function Set-BrushColor($brush, [string]$hex) {
  if (-not $brush) { return }
  try {
    $target = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    if ($brush.Color -eq $target) { return }
    $dur = New-Object -TypeName System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(320))
    $anim = New-Object -TypeName System.Windows.Media.Animation.ColorAnimation -ArgumentList @($brush.Color, $target, $dur)
    $anim.EasingFunction = Ease-Out
    $brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
  } catch {}
}

function Start-Hop($shift) {
  if (-not $shift) { return }
  $dur = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(430))
  $anim = New-Object -TypeName System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  $anim.Duration = $dur
  $frames = @(
    @{ t = 0; v = 0.0 },
    @{ t = 90; v = -8.0 },
    @{ t = 250; v = 0.0 },
    @{ t = 330; v = -3.0 },
    @{ t = 430; v = 0.0 }
  )
  foreach ($f in $frames) {
    $kf = New-Object -TypeName System.Windows.Media.Animation.EasingDoubleKeyFrame
    $kf.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($f.t))
    $kf.Value = $f.v
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $kf.EasingFunction = $ease
    [void]$anim.KeyFrames.Add($kf)
  }
  $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $anim)
}

function Start-Bounce($scale) {
  if (-not $scale) { return }
  $dur = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(560))
  foreach ($prop in @([System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty)) {
    $anim = New-Object -TypeName System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $anim.Duration = $dur
    $frames = @(
      @{ t = 0.0; v = 1.0 },
      @{ t = 120; v = 1.35 },
      @{ t = 300; v = 0.95 },
      @{ t = 560; v = 1.0 }
    )
    foreach ($f in $frames) {
      $kf = New-Object -TypeName System.Windows.Media.Animation.EasingDoubleKeyFrame
      $kf.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($f.t))
      $kf.Value = $f.v
      $ease = New-Object System.Windows.Media.Animation.CubicEase
      $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
      $kf.EasingFunction = $ease
      [void]$anim.KeyFrames.Add($kf)
    }
    $scale.BeginAnimation($prop, $anim)
  }
}

function Set-Hover([int]$index) {
  if ($script:HoverIndex -eq $index) { return }
  $script:HoverIndex = $index
  Apply-CardStyles
  for ($i = 0; $i -lt $script:SegTransforms.Count; $i++) {
    if ($i -eq $index) { Move-Segment $i 10 } else { Move-Segment $i 0 }
  }
  Update-Segments $script:Sessions
}

# ---------------------------------------------------------------- rendering

function Show-HudState {
  $s = Read-Status
  if ($null -eq $s) { return }

  $sessions = @($s.sessions)
  $script:Sessions = $sessions
  $count = $sessions.Count

  $signature = ($sessions | ForEach-Object { '{0}|{1}|{2}' -f $_.id, $_.title, $_.workspace }) -join ';'
  if ($signature -ne $script:Signature) {
    $script:Signature = $signature
    Build-Bar $sessions
    if ($script:Expanded) {
      Build-Columns $sessions
      $visible = [math]::Min([math]::Max(1, $count), $MAX_COLS)
      $script:PanelWidth = ($visible * $COL_W) + 24
      $script:Panel.Width = $script:PanelWidth
      $script:Window.Width = $script:PanelWidth
    } else {
      $script:Window.Width = $script:BarWidth
    }
    $script:HoverIndex = -1
    Update-Segments $sessions
    $script:Window.UpdateLayout()
    Apply-Position
  } else {
    Update-Segments $sessions
  }

  $ev = $s.event
  if ($ev -and $ev.at -and [double]$ev.at -ne $script:LastEventAt) {
    $script:LastEventAt = [double]$ev.at
    $script:AutoKind = [string]$ev.kind
    Write-HudLog ("event seen at=" + $ev.at + " now=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + " delta=" + ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$ev.at))
    if ($script:AutoKind -eq 'waiting') {
      $script:AutoUntil = [DateTime]::Now.AddHours(2)
    } else {
      $millis = 2500
      if ($s.autoShowMs) { $millis = [int]$s.autoShowMs }
      $script:AutoUntil = [DateTime]::Now.AddMilliseconds($millis)
    }
    if (-not $script:Expanded) { Set-Expanded $true }
    $script:PendingBounce = [string]$ev.sid
  }

  if (-not $script:Expanded) { return }

  if ($ev -and $ev.text) {
    $kind = [string]$ev.kind
    $palette = $eventColors[$kind]
    if (-not $palette) { $palette = $eventColors['done'] }
    $script:EventBar.Background = Brush $palette.bg
    $script:EventText.Foreground = Brush $palette.fg
    $script:EventText.Text = [string]$ev.text
    $script:EventBar.Visibility = 'Visible'
  } else {
    $script:EventBar.Visibility = 'Collapsed'
  }

  for ($i = 0; $i -lt $script:CardRefs.Count; $i++) {
    if ($i -ge $count) { break }
    $session = $sessions[$i]
    $ref = $script:CardRefs[$i]
    $state = [string]$session.state
    $color = StateColor $state
    $ref.Dot.Fill = $ref.DotBrush
    Set-BrushColor $ref.DotBrush $color
    Set-BrushColor $ref.StateBrush $color
    if ($null -ne $session.elapsedFrom) {
      $from = [double]$session.elapsedFrom
      if ($null -ne $session.elapsedTo) {
        $to = [double]$session.elapsedTo
      } else {
        $to = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
      }
      $label = [string]$session.elapsedLabel
      $time = Format-Elapsed (($to - $from) / 1000)
      if ([string]::IsNullOrEmpty($label)) {
        $ref.StateText.Text = ('{0}   {1}' -f $session.stateText, $time)
      } else {
        $ref.StateText.Text = ('{0}   {1} {2}' -f $session.stateText, $label, $time)
      }
    } else {
      $ref.StateText.Text = [string]$session.stateText
    }
    $ref.Action.Text = [string]$session.detail
    $ref.Facts.Text = [string]$session.facts
    $ref.Title.Text = [string]$session.title
    $ref.Workspace.Text = [string]$session.workspace
  }

  if ($script:PendingBounce) {
    $bounceId = $script:PendingBounce
    $script:PendingBounce = ''
    for ($i = 0; $i -lt $sessions.Count; $i++) {
      if ([string]$sessions[$i].id -ne $bounceId) { continue }
      if ($script:Expanded -and $i -lt $script:CardRefs.Count) {
        Start-Hop $script:CardRefs[$i].Shift
      } elseif ($i -lt $script:SegScales.Count) {
        Start-Bounce $script:SegScales[$i]
      }
      break
    }
  }

  Apply-CardStyles

  $hint = [string]$s.hint
  if (-not [string]::IsNullOrEmpty($hint)) { $script:HintText.Text = $hint }
}

function Update-Hud {
  try {
    Show-HudState
  } catch {
    Write-HudLog ('update failed: ' + $_.Exception.Message)
  }
}

# -------------------------------------------------------------- transitions

function Animate-In {
  $script:PanelShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
  $script:Panel.Opacity = 1.0
  $script:PanelShift.Y = 0

  $dur = New-Object -TypeName System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(130))
  $slide = New-Object -TypeName System.Windows.Media.Animation.DoubleAnimation -ArgumentList @(-10.0, 0.0, $dur)
  $slide.EasingFunction = Ease-Out
  $script:PanelShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Animate-Out {
  $height = 140
  try {
    if ($script:Panel.ActualHeight -gt 0) { $height = $script:Panel.ActualHeight }
  } catch {}

  $script:PanelShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
  $script:PanelShift.Y = 0

  $dur = New-Object -TypeName System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(150))
  $slide = New-Object -TypeName System.Windows.Media.Animation.DoubleAnimation -ArgumentList @(0.0, -($height + 12), $dur)
  $slide.EasingFunction = Ease-In
  $slide.Add_Completed({ Finish-Collapse })
  $script:PanelShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Finish-Collapse {
  if ($script:Expanded) { return }
  $script:PanelShift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
  $script:PanelShift.Y = -10
  $script:Panel.Opacity = 1.0
  $script:Panel.Visibility = 'Collapsed'
  $script:HoverIndex = -1
  Build-Bar $script:Sessions
  Update-Segments $script:Sessions
  $script:Window.Width = $script:BarWidth
  $script:Window.UpdateLayout()
  Apply-Position
  Set-ClickThrough $true
}

function Set-Expanded([bool]$expanded, [bool]$instant = $false) {
  if ($script:Expanded -eq $expanded) { return }
  $script:Expanded = $expanded
  if ($expanded) {
    Set-ClickThrough $false
    $visible = [math]::Min([math]::Max(1, @($script:Sessions).Count), $MAX_COLS)
    $script:PanelWidth = ($visible * $COL_W) + 24
    $script:Panel.Width = $script:PanelWidth
    $script:Panel.Visibility = 'Visible'
    $script:Window.Width = $script:PanelWidth
    Build-Bar $script:Sessions
    Build-Columns $script:Sessions
    Update-Segments $script:Sessions
    Update-Hud
    $script:Window.UpdateLayout()
    Apply-Position
    if ($instant) {
      $script:Panel.Opacity = 1.0
      $script:PanelShift.Y = 0
    } else {
      Animate-In
    }
  } else {
    if ($instant) {
      Finish-Collapse
    } else {
      Animate-Out
    }
  }
}

function Send-Open([string]$id) {
  if ([string]::IsNullOrEmpty($OpenUrl) -or [string]::IsNullOrEmpty($id)) { return }
  try {
    $url = $OpenUrl + '?session=' + [System.Uri]::EscapeDataString($id)
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 | Out-Null
  } catch {
    Write-HudLog ('open request failed: ' + $_.Exception.Message)
  }
  Focus-Host
  Set-Expanded $false
}

function Send-Hide([string]$id) {
  if ([string]::IsNullOrEmpty($HideUrl) -or [string]::IsNullOrEmpty($id)) { return }
  try {
    $url = $HideUrl + '?session=' + [System.Uri]::EscapeDataString($id)
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 | Out-Null
  } catch {
    Write-HudLog ('hide request failed: ' + $_.Exception.Message)
  }
}

function Focus-Host {
  try {
    $candidates = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -and ($_.ProcessName -match 'DeepSeek|dsh')
      })
    if ($candidates.Count -eq 0) { return }
    $target = $candidates[0].MainWindowHandle
    # SW_RESTORE un-maximizes a maximized window: only use it to bring a
    # minimized window back, otherwise just raise it.
    if ([HudStatus.Native]::IsIconic($target)) {
      [void][HudStatus.Native]::ShowWindow($target, 9)
    }
    [HudStatus.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [HudStatus.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][HudStatus.Native]::SetForegroundWindow($target)
  } catch {}
}

# A tool window carries the WS_EX_TOOLWINDOW bit: the shell leaves it out of
# Alt+Tab and the taskbar. WS_EX_NOACTIVATE keeps it from stealing focus.
$window.Add_SourceInitialized({
    try {
      $helper = New-Object -TypeName System.Windows.Interop.WindowInteropHelper -ArgumentList $script:Window
      $hwnd = $helper.Handle
      $exStyle = [HudStatus.Native]::GetWindowLong($hwnd, -20)
      $exStyle = $exStyle -bor 0x00000080 -bor 0x08000000
      [void][HudStatus.Native]::SetWindowLong($hwnd, -20, $exStyle)
    } catch {
      Write-HudLog ('style failed: ' + $_.Exception.Message)
    }
  })

$window.Add_Loaded({
    Apply-Position
    Set-ClickThrough $true
  })
$window.Add_SizeChanged({ Apply-Position })

# Drag to scroll: the window never activates, so wheel messages go to whatever
# app has focus; dragging inside the columns scrolls them instead.
$script:Scroller.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    try {
      $script:DragFrom = $e.GetPosition($script:Scroller).X
      $script:PressX = $script:DragFrom
      $script:DragOffset = $script:Scroller.HorizontalOffset
    } catch {}
  })
$script:Scroller.Add_PreviewMouseMove({
    param($sender, $e)
    try {
      if ($null -eq $script:DragFrom) { return }
      $x = $e.GetPosition($script:Scroller).X
      $script:Scroller.ScrollToHorizontalOffset($script:DragOffset - ($x - $script:DragFrom))
    } catch {}
  })
$script:Scroller.Add_PreviewMouseLeftButtonUp({
    param($sender, $e)
    $script:DragFrom = $null
  })
$script:Scroller.Add_MouseLeave({
    $script:DragFrom = $null
  })

$updateTimer = New-Object System.Windows.Threading.DispatcherTimer
$updateTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$updateTimer.Add_Tick({
    try {
      $script:Tick += 1
      if ($script:ForceRefresh) {
        $script:ForceRefresh = $false
        Update-Hud
      } elseif (($script:Tick % 2) -eq 0) {
        Update-Hud
      }

      if ($script:HoldSince) {
        $elapsed = ([DateTime]::Now - $script:HoldSince).TotalMilliseconds
        if ($script:HoldParts) {
          $pct = [math]::Min(1.0, $elapsed / $HOLD_MS)
          try { $script:HoldParts.Ring.Data = New-ArcGeometry 44 (360 * $pct) } catch {}
        }
        if ($elapsed -ge $HOLD_MS) {
          $id = $script:HoldId
          $script:HoldSince = $null
          $script:HoldId = ''
          $script:HoldCard = $null
          Stop-HoldVisuals
          if ($id) { Send-Hide $id }
        }
      }

      if (-not $script:HoldSince -and $script:HoldParts) { Stop-HoldVisuals }

      $over = Test-Hover
      if ($over) {
        if ($null -eq $script:HoverSince) { $script:HoverSince = [DateTime]::Now }
        $script:MissTicks = 0
        $script:AutoUntil = $null
        if (-not $script:Expanded) {
          $waited = ([DateTime]::Now - $script:HoverSince).TotalMilliseconds
          if ($waited -ge $DWELL_MS) { Set-Expanded $true }
        } else {
          # Column hover follows the sampled cursor instead of WPF mouse
          # events, which do not arrive while the window is click-through.
          if ($script:CursorY -gt ($script:RectTop + 34)) {
            $offset = $script:Scroller.HorizontalOffset
            $x = $script:CursorX - ($script:RectLeft + 11) + $offset
            $index = [int][math]::Floor($x / $COL_W)
            if ($index -lt 0 -or $index -ge $script:Cards.Count) { $index = -1 }
            if ($index -ne $script:HoverIndex) {
              if ($index -lt 0) { Clear-Hover } else { Set-Hover $index }
            }
          } elseif ($script:HoverIndex -ge 0) {
            Clear-Hover
          }
        }
      } else {
        $script:HoverSince = $null
        if ($script:AutoUntil) {
          $stillWaiting = $false
          foreach ($s in $script:Sessions) { if ([string]$s.state -eq 'waiting') { $stillWaiting = $true; break } }
          if ($script:AutoKind -eq 'waiting' -and -not $stillWaiting) {
            $script:AutoUntil = $null
          } elseif ([DateTime]::Now -ge $script:AutoUntil) {
            $script:AutoUntil = $null
          }
        }

        if ($script:AutoUntil) {
          $script:MissTicks = 0
          if (-not $script:Expanded) { Set-Expanded $true }
        } elseif ($script:Expanded) {
          $script:MissTicks += 1
          if ($script:MissTicks -ge 2) { Set-Expanded $false }
        }
      }
    } catch {
      Write-HudLog ('tick failed: ' + $_.Exception.Message)
    }
  })
$updateTimer.Start()

# The event signal is a few dozen bytes; polling it keeps the reaction time
# around 40ms instead of the 200ms snapshot poll.
$signalTimer = New-Object System.Windows.Threading.DispatcherTimer
$signalTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$signalTimer.Add_Tick({
    try {
      if (-not (Test-Path -LiteralPath $script:SignalPath)) { return }
      $raw = Read-Shared $script:SignalPath
      if ([string]::IsNullOrWhiteSpace($raw)) { return }
      if ($raw -ne $script:SignalSeen) {
        $script:SignalSeen = $raw
        Update-Hud
      }
    } catch {}
  })
$signalTimer.Start()

Update-Hud
Set-Expanded $false $true
Write-HudLog 'hud started'

try {
  [void]$window.ShowDialog()
} catch {
  Write-HudLog ('window failed: ' + $_.Exception.Message)
}

$updateTimer.Stop()
Write-HudLog 'hud closed'
