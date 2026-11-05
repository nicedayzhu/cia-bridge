param(
  [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing.Common

function New-RoundedPath {
  param(
    [System.Drawing.RectangleF]$Bounds,
    [float]$Radius
  )

  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $diameter = $Radius * 2
  $arc = [System.Drawing.RectangleF]::new($Bounds.X, $Bounds.Y, $diameter, $diameter)
  $path.AddArc($arc, 180, 90)
  $arc.X = $Bounds.Right - $diameter
  $path.AddArc($arc, 270, 90)
  $arc.Y = $Bounds.Bottom - $diameter
  $path.AddArc($arc, 0, 90)
  $arc.X = $Bounds.X
  $path.AddArc($arc, 90, 90)
  $path.CloseFigure()
  return $path
}

function Draw-RoundedRectangle {
  param(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.Pen]$Pen,
    [System.Drawing.RectangleF]$Bounds,
    [float]$Radius
  )

  $path = New-RoundedPath -Bounds $Bounds -Radius $Radius
  try { $Graphics.DrawPath($Pen, $path) } finally { $path.Dispose() }
}

function Fill-RoundedRectangle {
  param(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.Brush]$Brush,
    [System.Drawing.RectangleF]$Bounds,
    [float]$Radius
  )

  $path = New-RoundedPath -Bounds $Bounds -Radius $Radius
  try { $Graphics.FillPath($Brush, $path) } finally { $path.Dispose() }
}

function New-BridgeIcon {
  $bitmap = [System.Drawing.Bitmap]::new(
    512,
    512,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.Clear([System.Drawing.Color]::Transparent)

  $backgroundBounds = [System.Drawing.RectangleF]::new(18, 18, 476, 476)
  $background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    $backgroundBounds,
    [System.Drawing.Color]::FromArgb(255, 86, 104, 245),
    [System.Drawing.Color]::FromArgb(255, 48, 204, 171),
    48
  )
  Fill-RoundedRectangle -Graphics $graphics -Brush $background -Bounds $backgroundBounds -Radius 112

  $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
  $outline = [System.Drawing.Pen]::new($white, 24)
  $outline.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $outline.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $outline.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

  $top = [System.Drawing.RectangleF]::new(126, 72, 260, 154)
  $bottom = [System.Drawing.RectangleF]::new(94, 286, 324, 164)
  Draw-RoundedRectangle -Graphics $graphics -Pen $outline -Bounds $top -Radius 34
  Draw-RoundedRectangle -Graphics $graphics -Pen $outline -Bounds $bottom -Radius 40
  $graphics.DrawLine($outline, 168, 257, 344, 257)

  $screenTop = [System.Drawing.SolidBrush]::new(
    [System.Drawing.Color]::FromArgb(255, 38, 55, 83)
  )
  $screenBottom = [System.Drawing.SolidBrush]::new(
    [System.Drawing.Color]::FromArgb(244, 255, 255, 255)
  )
  Fill-RoundedRectangle -Graphics $graphics -Brush $screenTop -Bounds ([System.Drawing.RectangleF]::new(176, 112, 160, 74)) -Radius 12
  Fill-RoundedRectangle -Graphics $graphics -Brush $screenBottom -Bounds ([System.Drawing.RectangleF]::new(207, 323, 98, 66)) -Radius 10

  $detail = [System.Drawing.Pen]::new($white, 15)
  $detail.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $detail.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $graphics.DrawEllipse($detail, 137, 323, 39, 39)
  $graphics.DrawLine($detail, 136, 401, 184, 401)
  $graphics.DrawLine($detail, 160, 377, 160, 425)
  $graphics.DrawEllipse($detail, 345, 328, 13, 13)
  $graphics.DrawEllipse($detail, 374, 355, 13, 13)
  $graphics.DrawEllipse($detail, 316, 355, 13, 13)
  $graphics.DrawEllipse($detail, 345, 382, 13, 13)

  $accent = [System.Drawing.SolidBrush]::new(
    [System.Drawing.Color]::FromArgb(255, 250, 101, 129)
  )
  $graphics.FillEllipse($accent, 351, 119, 14, 14)
  $graphics.FillEllipse($accent, 351, 146, 14, 14)

  $accent.Dispose()
  $detail.Dispose()
  $screenBottom.Dispose()
  $screenTop.Dispose()
  $outline.Dispose()
  $background.Dispose()
  $graphics.Dispose()
  return $bitmap
}

function Get-PngBytes {
  param(
    [System.Drawing.Bitmap]$Source,
    [int]$Size
  )

  $target = [System.Drawing.Bitmap]::new(
    $Size,
    $Size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($target)
  $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
  $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.DrawImage($Source, 0, 0, $Size, $Size)
  $graphics.Dispose()

  $stream = [System.IO.MemoryStream]::new()
  $target.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $target.Dispose()
  $bytes = $stream.ToArray()
  $stream.Dispose()
  return $bytes
}

function Write-Png {
  param(
    [System.Drawing.Bitmap]$Source,
    [int]$Size,
    [string]$Path
  )

  $bytes = Get-PngBytes -Source $Source -Size $Size
  [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Write-Ico {
  param(
    [System.Drawing.Bitmap]$Source,
    [int[]]$Sizes,
    [string]$Path
  )

  $frames = @($Sizes | ForEach-Object {
    [PSCustomObject]@{ Size = $_; Bytes = (Get-PngBytes -Source $Source -Size $_) }
  })
  $stream = [System.IO.MemoryStream]::new()
  $writer = [System.IO.BinaryWriter]::new($stream)
  $writer.Write([UInt16]0)
  $writer.Write([UInt16]1)
  $writer.Write([UInt16]$frames.Count)
  $offset = 6 + (16 * $frames.Count)
  foreach ($frame in $frames) {
    $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
    $writer.Write([byte]$dimension)
    $writer.Write([byte]$dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([UInt16]1)
    $writer.Write([UInt16]32)
    $writer.Write([UInt32]$frame.Bytes.Length)
    $writer.Write([UInt32]$offset)
    $offset += $frame.Bytes.Length
  }
  foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
  $writer.Flush()
  [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
  $writer.Dispose()
  $stream.Dispose()
}

$branding = Join-Path $ProjectRoot 'assets\branding'
[System.IO.Directory]::CreateDirectory($branding) | Out-Null
$source = New-BridgeIcon
try {
  Write-Png -Source $source -Size 512 -Path (Join-Path $branding 'app_icon_512.png')

  $androidSizes = @{
    'mipmap-mdpi' = 48
    'mipmap-hdpi' = 72
    'mipmap-xhdpi' = 96
    'mipmap-xxhdpi' = 144
    'mipmap-xxxhdpi' = 192
  }
  foreach ($entry in $androidSizes.GetEnumerator()) {
    $target = Join-Path $ProjectRoot "android\app\src\main\res\$($entry.Key)\ic_launcher.png"
    Write-Png -Source $source -Size $entry.Value -Path $target
  }

  $windowsIcon = Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico'
  Write-Ico -Source $source -Sizes @(16, 24, 32, 48, 64, 128, 256) -Path $windowsIcon
} finally {
  $source.Dispose()
}

Write-Host 'Generated CIA Bridge Windows and Android app icons.'
