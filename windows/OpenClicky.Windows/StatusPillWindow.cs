using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using DrawingRectangle = System.Drawing.Rectangle;

namespace OpenClicky;

public enum CompanionStatus { Hidden, Listening, Thinking, Speaking, Message }

/// <summary>
/// A black pill hanging from the top-center of the screen: Listening (live mic waveform),
/// Thinking (pulsing dots), Speaking (waveform + captions). Click-through, never focused,
/// excluded from screen capture.
/// </summary>
public sealed class StatusPillWindow : Window
{
    private const double PanelWidth = 640;
    private const double PanelHeight = 220;

    private readonly Border pillBorder;
    private readonly TextBlock statusTitleText;
    private readonly Ellipse statusDot;
    private readonly StackPanel waveformBars;
    private readonly TextBlock captionText;
    private IntPtr windowHandle;
    private DrawingRectangle currentScreenBounds;

    private CompanionStatus currentStatus = CompanionStatus.Hidden;
    private float liveAudioLevel;

    public StatusPillWindow()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        Width = PanelWidth;
        Height = PanelHeight;

        statusDot = new Ellipse { Width = 8, Height = 8, Fill = new SolidColorBrush(ScreenOverlayWindow.UserInkCoral), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        statusTitleText = new TextBlock { Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };

        waveformBars = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        for (var barIndex = 0; barIndex < 7; barIndex++)
        {
            waveformBars.Children.Add(new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White, Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center });
        }

        var headerRow = new DockPanel { LastChildFill = false, Height = 26 };
        var leadingGroup = new StackPanel { Orientation = Orientation.Horizontal };
        leadingGroup.Children.Add(statusDot);
        leadingGroup.Children.Add(statusTitleText);
        DockPanel.SetDock(leadingGroup, Dock.Left);
        DockPanel.SetDock(waveformBars, Dock.Right);
        headerRow.Children.Add(leadingGroup);
        headerRow.Children.Add(waveformBars);

        captionText = new TextBlock
        {
            Foreground = new SolidColorBrush(Color.FromArgb(240, 255, 255, 255)),
            FontSize = 14.5,
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
            MaxHeight = 84,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Margin = new Thickness(0, 6, 0, 2),
            Visibility = Visibility.Collapsed
        };

        var pillContent = new StackPanel();
        pillContent.Children.Add(headerRow);
        pillContent.Children.Add(captionText);

        pillBorder = new Border
        {
            Background = Brushes.Black,
            CornerRadius = new CornerRadius(0, 0, 20, 20),
            Padding = new Thickness(18, 6, 18, 10),
            Width = 300,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Child = pillContent,
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 6, Opacity = 0.45, Direction = 270 },
            Opacity = 0,
            RenderTransformOrigin = new Point(0.5, 0),
            RenderTransform = new ScaleTransform(0.7, 0.7)
        };
        Content = new Grid { Children = { pillBorder } };

        SourceInitialized += (_, _) =>
        {
            windowHandle = new WindowInteropHelper(this).Handle;
            NativeMethods.MakeOverlayWindow(windowHandle);
        };
    }

    /// <summary>Moves the pill to the top-center of the monitor the user is on.</summary>
    public void MoveToScreen(DrawingRectangle screenPhysicalBounds)
    {
        if (windowHandle == IntPtr.Zero || screenPhysicalBounds == currentScreenBounds) return;
        currentScreenBounds = screenPhysicalBounds;
        var dpiScale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var physicalWidth = (int)(PanelWidth * dpiScale);
        var physicalHeight = (int)(PanelHeight * dpiScale);
        NativeMethods.SetWindowPos(windowHandle, NativeMethods.HWND_TOPMOST,
            screenPhysicalBounds.X + (screenPhysicalBounds.Width - physicalWidth) / 2, screenPhysicalBounds.Y,
            physicalWidth, physicalHeight, NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
    }

    public void SetStatus(CompanionStatus newStatus, string? messageText = null)
    {
        if (newStatus == CompanionStatus.Message)
        {
            statusTitleText.Text = messageText ?? "";
        }
        else
        {
            statusTitleText.Text = newStatus switch
            {
                CompanionStatus.Listening => "Listening",
                CompanionStatus.Thinking => "Thinking",
                CompanionStatus.Speaking => "Speaking",
                _ => statusTitleText.Text
            };
        }
        statusDot.Fill = new SolidColorBrush(newStatus == CompanionStatus.Listening ? ScreenOverlayWindow.UserInkCoral : ScreenOverlayWindow.BuddyBlue);
        waveformBars.Visibility = newStatus is CompanionStatus.Listening or CompanionStatus.Speaking or CompanionStatus.Thinking ? Visibility.Visible : Visibility.Collapsed;

        var wasHidden = currentStatus == CompanionStatus.Hidden;
        currentStatus = newStatus;
        if (newStatus != CompanionStatus.Speaking) SetCaption(null);

        if (newStatus == CompanionStatus.Hidden)
        {
            AnimatePill(targetOpacity: 0, targetScale: 0.8);
        }
        else if (wasHidden)
        {
            AnimatePill(targetOpacity: 1, targetScale: 1);
        }
    }

    public void SetCaption(string? caption)
    {
        var hasCaption = !string.IsNullOrWhiteSpace(caption);
        captionText.Text = caption ?? "";
        captionText.Visibility = hasCaption ? Visibility.Visible : Visibility.Collapsed;
        pillBorder.BeginAnimation(WidthProperty, new DoubleAnimation(hasCaption ? 520 : 300, TimeSpan.FromSeconds(0.3)) { EasingFunction = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut } });
    }

    public void SetAudioLevel(float audioLevel) => liveAudioLevel = audioLevel;

    private void AnimatePill(double targetOpacity, double targetScale)
    {
        var springEasing = new BackEase { Amplitude = 0.4, EasingMode = EasingMode.EaseOut };
        pillBorder.BeginAnimation(OpacityProperty, new DoubleAnimation(targetOpacity, TimeSpan.FromSeconds(0.22)));
        var scaleTransform = (ScaleTransform)pillBorder.RenderTransform;
        scaleTransform.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(targetScale, TimeSpan.FromSeconds(0.35)) { EasingFunction = springEasing });
        scaleTransform.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(targetScale, TimeSpan.FromSeconds(0.35)) { EasingFunction = springEasing });
    }

    /// <summary>Called every frame to animate the waveform / thinking dots.</summary>
    public void AnimateFrame(double elapsedSeconds)
    {
        if (currentStatus == CompanionStatus.Hidden) return;
        double[] barShapeWeights = { 0.45, 0.75, 1.0, 0.65, 0.9, 0.55, 0.7 };
        for (var barIndex = 0; barIndex < waveformBars.Children.Count; barIndex++)
        {
            var waveformBar = (Rectangle)waveformBars.Children[barIndex];
            var wobble = (Math.Sin(elapsedSeconds * 7 + barIndex * 0.9) + 1) / 2;
            double barLevel = currentStatus switch
            {
                CompanionStatus.Listening => Math.Min(1, liveAudioLevel * 1.6) * (0.55 + 0.45 * wobble),
                CompanionStatus.Speaking => 0.35 + 0.65 * wobble,
                // Thinking: a slow ripple across the bars
                _ => 0.25 + 0.35 * ((Math.Sin(elapsedSeconds * 5 - barIndex * 0.8) + 1) / 2)
            };
            waveformBar.Height = Math.Max(3, 18 * barLevel * barShapeWeights[barIndex]);
            waveformBar.Fill = currentStatus == CompanionStatus.Speaking
                ? new SolidColorBrush(Color.FromRgb(125, 196, 255))
                : Brushes.White;
        }
    }
}
