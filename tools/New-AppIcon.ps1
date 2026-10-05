Add-Type -AssemblyName System.Drawing

function New-RoundedPath([float]$x, [float]$y, [float]$width, [float]$height, [float]$radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $width - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $width - $d, $y + $height - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function New-IconPng([int]$size) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $scale = $size / 256.0
    $card = New-RoundedPath (12 * $scale) (12 * $scale) (232 * $scale) (232 * $scale) (58 * $scale)
    $gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        [System.Drawing.RectangleF]::new(12 * $scale, 12 * $scale, 232 * $scale, 232 * $scale),
        [System.Drawing.Color]::FromArgb(15, 35, 57), [System.Drawing.Color]::FromArgb(25, 190, 122), 45)
    $graphics.FillPath($gradient, $card)

    $bubble = New-RoundedPath (48 * $scale) (58 * $scale) (160 * $scale) (124 * $scale) (30 * $scale)
    $white = [System.Drawing.Color]::FromArgb(248, 255, 255, 255)
    $pen = New-Object System.Drawing.Pen($white, [Math]::Max(1.5, 9 * $scale))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawPath($pen, $bubble)
    $tail = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(83 * $scale, 177 * $scale),
        [System.Drawing.PointF]::new(73 * $scale, 199 * $scale),
        [System.Drawing.PointF]::new(111 * $scale, 179 * $scale))
    $graphics.DrawLines($pen, $tail)

    $notePen = New-Object System.Drawing.Pen($white, [Math]::Max(2, 12 * $scale))
    $notePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $notePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($notePen, 139 * $scale, 137 * $scale, 139 * $scale, 91 * $scale)
    $graphics.DrawLine($notePen, 178 * $scale, 131 * $scale, 178 * $scale, 79 * $scale)
    $graphics.DrawLine($notePen, 139 * $scale, 91 * $scale, 178 * $scale, 79 * $scale)
    $graphics.FillEllipse((New-Object System.Drawing.SolidBrush $white), 112 * $scale, 127 * $scale, 30 * $scale, 21 * $scale)
    $graphics.FillEllipse((New-Object System.Drawing.SolidBrush $white), 151 * $scale, 121 * $scale, 30 * $scale, 21 * $scale)

    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose(); $pen.Dispose(); $notePen.Dispose(); $gradient.Dispose(); $bubble.Dispose(); $card.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    $bytes
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = foreach ($size in $sizes) { [pscustomobject]@{ Size = $size; Bytes = (New-IconPng $size) } }
$header = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($header)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($image in $images) {
    $dimension = if ($image.Size -eq 256) { 0 } else { [byte]$image.Size }
    $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$image.Bytes.Length); $writer.Write([uint32]$offset)
    $offset += $image.Bytes.Length
}
foreach ($image in $images) { $writer.Write([byte[]]$image.Bytes) }
$writer.Flush()
$output = Join-Path $PSScriptRoot '..\assets\app.ico'
[System.IO.File]::WriteAllBytes([System.IO.Path]::GetFullPath($output), $header.ToArray())
$writer.Dispose(); $header.Dispose()
Write-Output "Created $output"
