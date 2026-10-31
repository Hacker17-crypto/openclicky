using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using DrawingPoint = System.Drawing.Point;
using DrawingPointF = System.Drawing.PointF;
using DrawingRectangle = System.Drawing.Rectangle;
using WpfPoint = System.Windows.Point;

namespace OpenClicky;

/// <summary>A drawing ready to render, in physical screen pixels.</summary>
public sealed record ScreenDrawing(
    DrawingKind Kind,
    DrawingPointF[] PhysicalPoints,
    float PhysicalRadius,
    float PhysicalWidth,
    float PhysicalHeight,
    string? Label);

/// <summary>
/// A transparent, click-through, always-on-top window covering one monitor. Shows the blue
/// buddy cursor, its pointing flights, Claude's drawings, and the user's ink. Excluded from
/// screen capture so it never appears in screenshots sent to Claude.
/// </summary>
public sealed class ScreenOverlayWindow : Window
{
    public DrawingRectangle PhysicalBounds { get; }

    private readonly Canvas rootCanvas = new();
    private readonly Canvas annotationLayer = new();
    private readonly Canvas inkLayer = new();
    private readonly Polygon buddyTriangle;
    private readonly Border buddyBubble;
    private readonly TextBlock buddyBubbleText;
    private IntPtr windowHandle;
    private double dpiScale = 1.0;

    private enum BuddyMode { FollowingCursor, Flying, Pointing }
    private BuddyMode buddyMode = BuddyMode.FollowingCursor;
    private WpfPoint buddyPosition;

    public static readonly Color BuddyBlue = Color.FromRgb(59, 130, 246);
    public static readonly Color MarkerGold = Color.FromRgb(232, 184, 58);
    public static readonly Color UserInkCoral = Color.FromRgb(255, 107, 61);
    private static readonly FontFamily HandwrittenFont = new("Segoe Print, Ink Free, Comic Sans MS");

    public ScreenOverlayWindow(DrawingRectangle physicalBounds)
    {
        PhysicalBounds = physicalBounds;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Left = physicalBounds.X;
        Top = physicalBounds.Y;
        Width = physicalBounds.Width;
        Height = physicalBounds.Height;

        rootCanvas.Children.Add(inkLayer);
        rootCanvas.Children.Add(annotationLayer);

        buddyTriangle = new Polygon
        {
            Points = new PointCollection { new(0, 0), new(16, 9), new(7, 11), new(3, 19) },
            Fill = new SolidColorBrush(BuddyBlue),
            Effect = new DropShadowEffect { Color = BuddyBlue, BlurRadius = 12, ShadowDepth = 0, Opacity = 0.8 },
            Visibility = Visibility.Hidden,
            IsHitTestVisible = false
        };
        rootCanvas.Children.Add(buddyTriangle);

        buddyBubbleText = new TextBlock { Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.Medium };
        buddyBubble = new Border
        {
            Background = new SolidColorBrush(BuddyBlue),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 3, 8, 4),
            Child = buddyBubbleText,
            Effect = new DropShadowEffect { Color = BuddyBlue, BlurRadius = 10, ShadowDepth = 0, Opacity = 0.7 },
            Opacity = 0,
            IsHitTestVisible = false
        };
        rootCanvas.Children.Add(buddyBubble);

        Content = rootCanvas;
        SourceInitialized += (_, _) =>
        {
            windowHandle = new WindowInteropHelper(this).Handle;
            NativeMethods.MakeOverlayWindow(windowHandle);
            ApplyPhysicalBounds();
        };
        Loaded += (_, _) => dpiScale = VisualTreeHelper.GetDpi(this).DpiScaleX;
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        dpiScale = newDpi.DpiScaleX;
        ApplyPhysicalBounds();
    }

    /// <summary>Positions the window in physical pixels (WPF's own sizing is in DIPs and DPI-dependent).</summary>
    private void ApplyPhysicalBounds()
    {
        if (windowHandle == IntPtr.Zero) return;
        NativeMethods.SetWindowPos(windowHandle, NativeMethods.HWND_TOPMOST, PhysicalBounds.X, PhysicalBounds.Y,
            PhysicalBounds.Width, PhysicalBounds.Height, NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
    }

    public bool ContainsPhysicalPoint(DrawingPoint physicalPoint) => PhysicalBounds.Contains(physicalPoint);

    private WpfPoint ToLocal(DrawingPointF physicalPoint) =>
        new((physicalPoint.X - PhysicalBounds.X) / dpiScale, (physicalPoint.Y - PhysicalBounds.Y) / dpiScale);

    private double ToLocalLength(double physicalLength) => physicalLength / dpiScale;

    // MARK: Buddy cursor

    /// <summary>Called every frame. Keeps the buddy next to the real cursor when it's on this screen.</summary>
    public void UpdateBuddy(DrawingPoint cursorPhysicalPosition, bool isBuddyEnabled, bool isAnotherScreenPointing, double pulse)
    {
        if (buddyMode != BuddyMode.FollowingCursor)
        {
            PlaceBuddy();
            return;
        }

        var isCursorHere = ContainsPhysicalPoint(cursorPhysicalPosition);
        buddyTriangle.Visibility = isBuddyEnabled && isCursorHere && !isAnotherScreenPointing ? Visibility.Visible : Visibility.Hidden;
        if (!isCursorHere) return;

        var cursorLocal = ToLocal(cursorPhysicalPosition);
        buddyPosition = new WpfPoint(cursorLocal.X + 22, cursorLocal.Y + 18);
        buddyTriangle.RenderTransform = new ScaleTransform(pulse, pulse, 8, 10);
        PlaceBuddy();
    }

    private void PlaceBuddy()
    {
        Canvas.SetLeft(buddyTriangle, buddyPosition.X);
        Canvas.SetTop(buddyTriangle, buddyPosition.Y);
        Canvas.SetLeft(buddyBubble, buddyPosition.X + 20);
        Canvas.SetTop(buddyBubble, buddyPosition.Y + 14);
    }

    public bool IsPointing => buddyMode != BuddyMode.FollowingCursor;

    /// <summary>Flies the buddy along an arc to the target, shows the label, then returns.</summary>
    public async Task FlyToAndPointAsync(DrawingPointF targetPhysicalPoint, string? label)
    {
        var startPosition = buddyPosition;
        var targetLocal = ToLocal(targetPhysicalPoint);
        // The triangle's tip is its top-left corner, so aim that at the target.
        var endPosition = new WpfPoint(targetLocal.X, targetLocal.Y);
        if (startPosition == default) startPosition = new WpfPoint(endPosition.X - 120, endPosition.Y + 120);

        buddyMode = BuddyMode.Flying;
        buddyTriangle.Visibility = Visibility.Visible;
        await AnimateBuddyAlongArcAsync(startPosition, endPosition, durationSeconds: 0.7);

        buddyMode = BuddyMode.Pointing;
        buddyBubbleText.Text = string.IsNullOrWhiteSpace(label) ? "right here" : label;
        PlaceBuddy();
        buddyBubble.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.25)));
        await Task.Delay(TimeSpan.FromSeconds(3));
        buddyBubble.BeginAnimation(OpacityProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.3)));

        NativeMethods.GetCursorPos(out var cursorPosition);
        var returnPhysical = new DrawingPointF(cursorPosition.X, cursorPosition.Y);
        var returnLocal = ToLocal(returnPhysical);
        if (ContainsPhysicalPoint(new DrawingPoint(cursorPosition.X, cursorPosition.Y)))
        {
            await AnimateBuddyAlongArcAsync(buddyPosition, new WpfPoint(returnLocal.X + 22, returnLocal.Y + 18), durationSeconds: 0.5);
        }
        buddyMode = BuddyMode.FollowingCursor;
    }

    private async Task AnimateBuddyAlongArcAsync(WpfPoint startPosition, WpfPoint endPosition, double durationSeconds)
    {
        var distance = (endPosition - startPosition).Length;
        // Bow the path sideways so the flight reads as an arc, not a slide.
        var controlPoint = new WpfPoint(
            (startPosition.X + endPosition.X) / 2 - (endPosition.Y - startPosition.Y) * 0.25,
            (startPosition.Y + endPosition.Y) / 2 - Math.Min(140, distance * 0.35));
        var animationStart = DateTime.Now;
        while (true)
        {
            var linearProgress = Math.Min(1, (DateTime.Now - animationStart).TotalSeconds / durationSeconds);
            var easedProgress = 1 - Math.Pow(1 - linearProgress, 3);
            var inverseProgress = 1 - easedProgress;
            buddyPosition = new WpfPoint(
                inverseProgress * inverseProgress * startPosition.X + 2 * inverseProgress * easedProgress * controlPoint.X + easedProgress * easedProgress * endPosition.X,
                inverseProgress * inverseProgress * startPosition.Y + 2 * inverseProgress * easedProgress * controlPoint.Y + easedProgress * easedProgress * endPosition.Y);
            var flightScale = 1 + 0.35 * Math.Sin(easedProgress * Math.PI);
            buddyTriangle.RenderTransform = new ScaleTransform(flightScale, flightScale, 8, 10);
            PlaceBuddy();
            if (linearProgress >= 1) break;
            await Task.Delay(16);
        }
    }

    // MARK: User ink

    public void ShowUserInk(IEnumerable<IReadOnlyList<DrawingPoint>> inkStrokes)
    {
        inkLayer.Children.Clear();
        foreach (var inkStroke in inkStrokes)
        {
            if (inkStroke.Count == 0 || !ContainsPhysicalPoint(inkStroke[0])) continue;
            var strokePoints = new PointCollection(inkStroke.Select(physicalPoint => ToLocal(physicalPoint)));
            inkLayer.Children.Add(new Polyline
            {
                Points = strokePoints,
                Stroke = new SolidColorBrush(UserInkCoral),
                StrokeThickness = 4,
                StrokeLineJoin = PenLineJoin.Round,
                StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round,
                Effect = new DropShadowEffect { Color = UserInkCoral, BlurRadius = 8, ShadowDepth = 0, Opacity = 0.6 }
            });
        }
    }

    // MARK: Claude's drawings

    public void ClearDrawings(bool isAnimated = true)
    {
        if (!isAnimated || (annotationLayer.Children.Count == 0 && inkLayer.Children.Count == 0))
        {
            annotationLayer.Children.Clear();
            inkLayer.Children.Clear();
            return;
        }
        var fadeOut = new DoubleAnimation(0, TimeSpan.FromSeconds(0.45));
        fadeOut.Completed += (_, _) =>
        {
            annotationLayer.Children.Clear();
            inkLayer.Children.Clear();
            annotationLayer.BeginAnimation(OpacityProperty, null);
            inkLayer.BeginAnimation(OpacityProperty, null);
            annotationLayer.Opacity = 1;
            inkLayer.Opacity = 1;
        };
        annotationLayer.BeginAnimation(OpacityProperty, fadeOut);
        inkLayer.BeginAnimation(OpacityProperty, fadeOut.Clone());
    }

    /// <summary>Adds one drawing; it draws itself in after <paramref name="appearanceDelaySeconds"/>.</summary>
    public void AddDrawing(ScreenDrawing drawing, double appearanceDelaySeconds, int paletteIndex)
    {
        switch (drawing.Kind)
        {
            case DrawingKind.CalloutLabel:
                AddCalloutLabel(ToLocal(drawing.PhysicalPoints[0]), drawing.Label ?? "", appearanceDelaySeconds, paletteIndex);
                break;
            case DrawingKind.StickyNote:
                AddStickyNote(ToLocal(drawing.PhysicalPoints[0]), drawing.Label ?? "", appearanceDelaySeconds);
                break;
            default:
                AddPenDrawing(drawing, appearanceDelaySeconds);
                break;
        }
    }

    private static double Wobble(int seed, int index, double amplitude) => Math.Sin(seed % 997 + index * 1.7) * amplitude;

    private void AddPenDrawing(ScreenDrawing drawing, double appearanceDelaySeconds)
    {
        var randomSeed = Random.Shared.Next(1000);
        var strokeGeometry = new StreamGeometry();
        WpfPoint labelPosition;
        Rect? highlightRect = null;

        using (var geometryContext = strokeGeometry.Open())
        {
            switch (drawing.Kind)
            {
                case DrawingKind.Circle:
                {
                    var center = ToLocal(drawing.PhysicalPoints[0]);
                    var radius = Math.Max(14, ToLocalLength(drawing.PhysicalRadius));
                    const int segmentCount = 56;
                    var totalSweepRadians = 2 * Math.PI * 1.12;
                    var startAngleRadians = -Math.PI * 0.65;
                    for (var segmentIndex = 0; segmentIndex <= segmentCount; segmentIndex++)
                    {
                        var segmentProgress = (double)segmentIndex / segmentCount;
                        var angleRadians = startAngleRadians + segmentProgress * totalSweepRadians;
                        var wobbledRadius = radius * (1 + 0.07 * segmentProgress) + Wobble(randomSeed, segmentIndex / 8, 1.6);
                        var circlePoint = new WpfPoint(center.X + wobbledRadius * 1.15 * Math.Cos(angleRadians), center.Y + wobbledRadius * Math.Sin(angleRadians));
                        if (segmentIndex == 0) geometryContext.BeginFigure(circlePoint, false, false);
                        else geometryContext.LineTo(circlePoint, true, true);
                    }
                    labelPosition = new WpfPoint(center.X + radius * 0.9, center.Y + radius + 14);
                    break;
                }
                case DrawingKind.Highlight:
                {
                    var topLeft = ToLocal(drawing.PhysicalPoints[0]);
                    var rect = new Rect(topLeft.X - 6, topLeft.Y - 4, ToLocalLength(drawing.PhysicalWidth) + 12, ToLocalLength(drawing.PhysicalHeight) + 8);
                    highlightRect = rect;
                    geometryContext.BeginFigure(new WpfPoint(rect.Left + Wobble(randomSeed, 1, 2), rect.Top), false, false);
                    geometryContext.LineTo(new WpfPoint(rect.Right, rect.Top + Wobble(randomSeed, 2, 2)), true, true);
                    geometryContext.LineTo(new WpfPoint(rect.Right + Wobble(randomSeed, 3, 2), rect.Bottom), true, true);
                    geometryContext.LineTo(new WpfPoint(rect.Left, rect.Bottom + Wobble(randomSeed, 4, 2)), true, true);
                    geometryContext.LineTo(new WpfPoint(rect.Left + Wobble(randomSeed, 5, 2), rect.Top - 3), true, true);
                    labelPosition = new WpfPoint(rect.Right - 40, rect.Bottom + 10);
                    break;
                }
                case DrawingKind.Underline:
                {
                    var start = ToLocal(drawing.PhysicalPoints[0]);
                    var end = ToLocal(drawing.PhysicalPoints[1]);
                    var underlineY = start.Y + 4;
                    var underlineWidth = end.X - start.X;
                    geometryContext.BeginFigure(new WpfPoint(start.X - 2, underlineY), false, false);
                    geometryContext.BezierTo(
                        new WpfPoint(start.X + underlineWidth * 0.33, underlineY + 4 + Wobble(randomSeed, 1, 1.5)),
                        new WpfPoint(start.X + underlineWidth * 0.66, underlineY - 3 + Wobble(randomSeed, 2, 1.5)),
                        new WpfPoint(end.X + 2, underlineY - 1), true, true);
                    labelPosition = new WpfPoint((start.X + end.X) / 2, underlineY + 12);
                    break;
                }
                default: // Arrow
                {
                    var start = ToLocal(drawing.PhysicalPoints[0]);
                    var end = ToLocal(drawing.PhysicalPoints[1]);
                    var shaftControlPoint = new WpfPoint((start.X + end.X) / 2 + (end.Y - start.Y) * 0.12, (start.Y + end.Y) / 2 - (end.X - start.X) * 0.12);
                    geometryContext.BeginFigure(start, false, false);
                    geometryContext.QuadraticBezierTo(shaftControlPoint, end, true, true);
                    var arrowAngle = Math.Atan2(end.Y - shaftControlPoint.Y, end.X - shaftControlPoint.X);
                    const double arrowheadLength = 17;
                    const double arrowheadSpread = Math.PI / 7;
                    geometryContext.LineTo(new WpfPoint(end.X - arrowheadLength * Math.Cos(arrowAngle - arrowheadSpread), end.Y - arrowheadLength * Math.Sin(arrowAngle - arrowheadSpread)), true, true);
                    geometryContext.BeginFigure(end, false, false);
                    geometryContext.LineTo(new WpfPoint(end.X - arrowheadLength * Math.Cos(arrowAngle + arrowheadSpread), end.Y - arrowheadLength * Math.Sin(arrowAngle + arrowheadSpread)), true, true);
                    labelPosition = new WpfPoint(start.X - 20, start.Y - 30);
                    break;
                }
            }
        }
        strokeGeometry.Freeze();

        if (highlightRect is { } highlightBounds)
        {
            // Highlighter wash that sweeps in left to right.
            var highlightWash = new Rectangle
            {
                Width = highlightBounds.Width,
                Height = highlightBounds.Height,
                RadiusX = 4,
                RadiusY = 4,
                Fill = new SolidColorBrush(Color.FromArgb(62, MarkerGold.R, MarkerGold.G, MarkerGold.B)),
                RenderTransform = new ScaleTransform(0, 1)
            };
            Canvas.SetLeft(highlightWash, highlightBounds.Left);
            Canvas.SetTop(highlightWash, highlightBounds.Top);
            annotationLayer.Children.Add(highlightWash);
            ((ScaleTransform)highlightWash.RenderTransform).BeginAnimation(ScaleTransform.ScaleXProperty,
                new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.6)) { BeginTime = TimeSpan.FromSeconds(appearanceDelaySeconds + 0.2), EasingFunction = new CubicEase() });
        }

        AnimatePenStroke(strokeGeometry, appearanceDelaySeconds);

        if (!string.IsNullOrWhiteSpace(drawing.Label))
        {
            var labelTag = new Border
            {
                Background = new SolidColorBrush(MarkerGold),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(8, 1, 8, 2),
                Child = new TextBlock { Text = drawing.Label, FontFamily = HandwrittenFont, FontSize = 14, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromRgb(41, 33, 10)) },
                Effect = new DropShadowEffect { BlurRadius = 6, ShadowDepth = 2, Opacity = 0.3 },
                RenderTransformOrigin = new WpfPoint(0.5, 0.5),
                Opacity = 0
            };
            Canvas.SetLeft(labelTag, labelPosition.X);
            Canvas.SetTop(labelTag, labelPosition.Y);
            annotationLayer.Children.Add(labelTag);
            PopIn(labelTag, appearanceDelaySeconds + 0.55, fromScale: 0.6, fromAngle: -6, toAngle: -2);
        }
    }

    /// <summary>
    /// Draws the stroke in like a marker: a soft ink bleed, the solid core, a thin sheen, and a
    /// glowing pen tip that travels along the path. Paced by path length.
    /// </summary>
    private void AnimatePenStroke(Geometry strokeGeometry, double appearanceDelaySeconds)
    {
        var flattenedGeometry = strokeGeometry.GetFlattenedPathGeometry();
        var strokeLength = EstimatePathLength(flattenedGeometry);
        var drawDurationSeconds = Math.Clamp(0.25 + strokeLength / 1400, 0.35, 1.0);

        Path MakeStrokeLayer(Brush strokeBrush, double strokeThickness, Effect? effect) => new()
        {
            Data = strokeGeometry,
            Stroke = strokeBrush,
            StrokeThickness = strokeThickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Effect = effect,
            Opacity = 0
        };

        var strokeLayers = new[]
        {
            MakeStrokeLayer(new SolidColorBrush(Color.FromArgb(56, MarkerGold.R, MarkerGold.G, MarkerGold.B)), 10, new BlurEffect { Radius = 3 }),
            MakeStrokeLayer(new SolidColorBrush(MarkerGold), 3.4, new DropShadowEffect { BlurRadius = 2, ShadowDepth = 1, Opacity = 0.28 }),
            MakeStrokeLayer(new SolidColorBrush(Color.FromArgb(90, 255, 255, 255)), 1, null)
        };
        strokeLayers[2].RenderTransform = new TranslateTransform(-0.6, -0.7);
        foreach (var strokeLayer in strokeLayers) annotationLayer.Children.Add(strokeLayer);

        var penNib = new Ellipse
        {
            Width = 7,
            Height = 7,
            Fill = Brushes.White,
            Effect = new DropShadowEffect { Color = MarkerGold, BlurRadius = 12, ShadowDepth = 0, Opacity = 1 },
            Opacity = 0
        };
        annotationLayer.Children.Add(penNib);

        var animationStart = DateTime.Now.AddSeconds(appearanceDelaySeconds);
        EventHandler? frameHandler = null;
        frameHandler = (_, _) =>
        {
            var elapsedSeconds = (DateTime.Now - animationStart).TotalSeconds;
            if (elapsedSeconds < 0) return;
            var linearProgress = Math.Min(1, elapsedSeconds / drawDurationSeconds);
            // Quick start, gentle landing, like a confident marker stroke.
            var easedProgress = 1 - Math.Pow(1 - linearProgress, 2.6);

            foreach (var strokeLayer in strokeLayers)
            {
                var dashLength = strokeLength / strokeLayer.StrokeThickness + 2;
                strokeLayer.StrokeDashArray = new DoubleCollection { dashLength, dashLength };
                strokeLayer.StrokeDashOffset = dashLength * (1 - easedProgress);
                strokeLayer.Opacity = 1;
            }

            if (linearProgress < 1)
            {
                flattenedGeometry.GetPointAtFractionLength(easedProgress, out var nibPoint, out _);
                Canvas.SetLeft(penNib, nibPoint.X - 3.5);
                Canvas.SetTop(penNib, nibPoint.Y - 3.5);
                penNib.Opacity = 1;
            }
            else
            {
                penNib.Opacity = 0;
                foreach (var strokeLayer in strokeLayers) strokeLayer.StrokeDashArray = null;
                CompositionTarget.Rendering -= frameHandler;
            }
        };
        CompositionTarget.Rendering += frameHandler;
    }

    private static double EstimatePathLength(PathGeometry flattenedGeometry)
    {
        double totalLength = 0;
        foreach (var pathFigure in flattenedGeometry.Figures)
        {
            var previousPoint = pathFigure.StartPoint;
            foreach (var pathSegment in pathFigure.Segments)
            {
                var segmentPoints = pathSegment switch
                {
                    PolyLineSegment polyLine => polyLine.Points.ToList(),
                    LineSegment line => new List<WpfPoint> { line.Point },
                    _ => new List<WpfPoint>()
                };
                foreach (var segmentPoint in segmentPoints)
                {
                    totalLength += (segmentPoint - previousPoint).Length;
                    previousPoint = segmentPoint;
                }
            }
        }
        return Math.Max(totalLength, 1);
    }

    private static readonly (Color Fill, Color Edge)[] PastelPalette =
    {
        (Color.FromRgb(220, 247, 220), Color.FromRgb(90, 191, 102)),
        (Color.FromRgb(223, 238, 255), Color.FromRgb(89, 140, 230)),
        (Color.FromRgb(255, 225, 234), Color.FromRgb(230, 102, 140)),
        (Color.FromRgb(255, 245, 199), Color.FromRgb(230, 184, 51))
    };

    /// <summary>A pastel tag on a leader line: the dot pops, the line draws out, then the tag springs in.</summary>
    private void AddCalloutLabel(WpfPoint anchorPoint, string labelText, double appearanceDelaySeconds, int paletteIndex)
    {
        var (fillColor, edgeColor) = PastelPalette[paletteIndex % PastelPalette.Length];
        var horizontalOffset = anchorPoint.X > ActualWidth / 2 ? 46 : -46;
        var verticalOffset = anchorPoint.Y < 110 ? 72 : -72;
        var labelCenter = new WpfPoint(anchorPoint.X + horizontalOffset, anchorPoint.Y + verticalOffset);

        var leaderLine = new Line
        {
            X1 = anchorPoint.X, Y1 = anchorPoint.Y, X2 = anchorPoint.X, Y2 = anchorPoint.Y,
            Stroke = Brushes.White,
            StrokeThickness = 2,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            Effect = new DropShadowEffect { BlurRadius = 3, ShadowDepth = 0, Opacity = 0.6 }
        };
        annotationLayer.Children.Add(leaderLine);
        var lineBeginTime = TimeSpan.FromSeconds(appearanceDelaySeconds + 0.12);
        leaderLine.BeginAnimation(Line.X2Property, new DoubleAnimation(anchorPoint.X, labelCenter.X, TimeSpan.FromSeconds(0.3)) { BeginTime = lineBeginTime, EasingFunction = new CubicEase() });
        leaderLine.BeginAnimation(Line.Y2Property, new DoubleAnimation(anchorPoint.Y, labelCenter.Y, TimeSpan.FromSeconds(0.3)) { BeginTime = lineBeginTime, EasingFunction = new CubicEase() });

        var anchorDot = new Ellipse
        {
            Width = 9, Height = 9, Fill = Brushes.White, Stroke = new SolidColorBrush(Color.FromArgb(160, 0, 0, 0)), StrokeThickness = 1.5,
            RenderTransformOrigin = new WpfPoint(0.5, 0.5), RenderTransform = new ScaleTransform(0, 0)
        };
        Canvas.SetLeft(anchorDot, anchorPoint.X - 4.5);
        Canvas.SetTop(anchorDot, anchorPoint.Y - 4.5);
        annotationLayer.Children.Add(anchorDot);
        var dotPop = new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.3)) { BeginTime = TimeSpan.FromSeconds(appearanceDelaySeconds), EasingFunction = new BackEase { Amplitude = 0.6 } };
        ((ScaleTransform)anchorDot.RenderTransform).BeginAnimation(ScaleTransform.ScaleXProperty, dotPop);
        ((ScaleTransform)anchorDot.RenderTransform).BeginAnimation(ScaleTransform.ScaleYProperty, dotPop.Clone());

        var tagContent = new Grid();
        tagContent.Children.Add(new Border { Background = new SolidColorBrush(edgeColor), Width = 4, HorizontalAlignment = HorizontalAlignment.Left });
        tagContent.Children.Add(new TextBlock
        {
            Text = labelText,
            FontFamily = HandwrittenFont,
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(Color.FromRgb(31, 31, 34)),
            Margin = new Thickness(13, 2, 10, 3)
        });
        var labelTag = new Border
        {
            Background = new SolidColorBrush(fillColor),
            CornerRadius = new CornerRadius(3),
            Child = tagContent,
            Effect = new DropShadowEffect { BlurRadius = 8, ShadowDepth = 3, Opacity = 0.3 },
            RenderTransformOrigin = new WpfPoint(0.5, 0.5),
            Opacity = 0
        };
        labelTag.Loaded += (_, _) =>
        {
            Canvas.SetLeft(labelTag, labelCenter.X - labelTag.ActualWidth / 2);
            Canvas.SetTop(labelTag, labelCenter.Y - labelTag.ActualHeight / 2);
        };
        annotationLayer.Children.Add(labelTag);
        var restingTilt = paletteIndex % 2 == 0 ? -1.5 : 1.5;
        PopIn(labelTag, appearanceDelaySeconds + 0.36, fromScale: 0.5, fromAngle: restingTilt + 8, toAngle: restingTilt);
    }

    /// <summary>A yellow sticky note that drops onto the screen and lands slightly askew.</summary>
    private void AddStickyNote(WpfPoint centerPoint, string noteText, double appearanceDelaySeconds)
    {
        var clampedCenter = new WpfPoint(Math.Clamp(centerPoint.X, 120, Math.Max(120, ActualWidth - 120)), Math.Clamp(centerPoint.Y, 100, Math.Max(100, ActualHeight - 100)));

        var noteBody = new Grid { Width = 200, MinHeight = 150 };
        noteBody.Children.Add(new Path
        {
            Fill = new SolidColorBrush(Color.FromRgb(255, 234, 140)),
            Stretch = Stretch.Fill,
            Data = Geometry.Parse("M0,0 L100,0 L100,84 L87,100 L0,100 Z")
        });
        noteBody.Children.Add(new Border { Background = new SolidColorBrush(Color.FromRgb(250, 219, 102)), Height = 14, VerticalAlignment = VerticalAlignment.Top });
        noteBody.Children.Add(new Path
        {
            Fill = new SolidColorBrush(Color.FromRgb(232, 201, 84)),
            Width = 26, Height = 24,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Stretch = Stretch.Fill,
            Data = Geometry.Parse("M26,0 L0,24 L0,0 Z")
        });
        noteBody.Children.Add(new TextBlock
        {
            Text = noteText,
            FontFamily = HandwrittenFont,
            FontSize = 17,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(Color.FromRgb(45, 42, 26)),
            Margin = new Thickness(16, 22, 16, 18)
        });

        var stickyNote = new Border
        {
            Child = noteBody,
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 7, Opacity = 0.35, Direction = 290 },
            RenderTransformOrigin = new WpfPoint(0.5, 0.5),
            Opacity = 0
        };
        stickyNote.Loaded += (_, _) =>
        {
            Canvas.SetLeft(stickyNote, clampedCenter.X - stickyNote.ActualWidth / 2);
            Canvas.SetTop(stickyNote, clampedCenter.Y - stickyNote.ActualHeight / 2);
        };
        annotationLayer.Children.Add(stickyNote);
        PopIn(stickyNote, appearanceDelaySeconds, fromScale: 1.18, fromAngle: -12, toAngle: -3, fromOffsetY: -36);
    }

    /// <summary>Spring-in: fade, scale and rotate (and optionally drop) into place.</summary>
    private static void PopIn(UIElement element, double delaySeconds, double fromScale, double fromAngle, double toAngle, double fromOffsetY = 0)
    {
        var scaleTransform = new ScaleTransform(fromScale, fromScale);
        var rotateTransform = new RotateTransform(fromAngle);
        var translateTransform = new TranslateTransform(0, fromOffsetY);
        element.RenderTransform = new TransformGroup { Children = { scaleTransform, rotateTransform, translateTransform } };

        var beginTime = TimeSpan.FromSeconds(delaySeconds);
        var springDuration = TimeSpan.FromSeconds(0.55);
        var springEasing = new ElasticEase { Oscillations = 1, Springiness = 6, EasingMode = EasingMode.EaseOut };
        element.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.18)) { BeginTime = beginTime });
        scaleTransform.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(fromScale, 1, springDuration) { BeginTime = beginTime, EasingFunction = springEasing });
        scaleTransform.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(fromScale, 1, springDuration) { BeginTime = beginTime, EasingFunction = springEasing });
        rotateTransform.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(fromAngle, toAngle, springDuration) { BeginTime = beginTime, EasingFunction = springEasing });
        if (fromOffsetY != 0)
        {
            translateTransform.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(fromOffsetY, 0, TimeSpan.FromSeconds(0.45)) { BeginTime = beginTime, EasingFunction = new BounceEase { Bounces = 1, Bounciness = 4, EasingMode = EasingMode.EaseOut } });
        }
    }
}
