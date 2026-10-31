using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Speech.Synthesis;
using System.Text;
using System.Text.RegularExpressions;
using WinFormsScreen = System.Windows.Forms.Screen;

namespace OpenClicky;

// MARK: - Tags in Claude's replies

public enum DrawingKind { Circle, Highlight, Underline, Arrow, CalloutLabel, StickyNote }

/// <summary>A drawing tag, still in screenshot pixel coordinates.</summary>
public sealed record DrawingRequest(DrawingKind Kind, double[] Numbers, string? Label, int? ScreenNumber);

public sealed record ParsedReply(
    string SpokenText,
    PointF? PointCoordinate,
    string? PointLabel,
    int? PointScreenNumber,
    IReadOnlyList<DrawingRequest> Drawings,
    IReadOnlyList<string> FactsToRemember);

/// <summary>
/// Parses the same tags as the macOS app (see ScreenAnnotations.swift / CompanionManager.swift):
/// [POINT:x,y:label:screenN], [CIRCLE:x,y,r:label], [HIGHLIGHT:x,y,w,h:label], [UNDERLINE:x1,x2,y:label],
/// [ARROW:x1,y1,x2,y2:label], [LABEL:x,y:text], [NOTE:x,y:text], [REMEMBER:fact].
/// </summary>
public static class ResponseTagParser
{
    private static readonly Regex FreeTextTagRegexTemplate = new(@"\[{0}:(.+?)\](?=\s*(?:\[|$))", RegexOptions.IgnoreCase | RegexOptions.Singleline);
    private static readonly Regex ShapeTagRegex = new(
        @"\[(CIRCLE|HIGHLIGHT|UNDERLINE|ARROW):\s*(-?\d+(?:\.\d+)?(?:\s*,\s*-?\d+(?:\.\d+)?){2,3})(?::([^\]:]*))?(?::screen(\d+))?\]",
        RegexOptions.IgnoreCase);
    private static readonly Regex TextTagRegex = new(
        @"\[(LABEL|NOTE):\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*:(.+?)(?::screen(\d+))?\]",
        RegexOptions.IgnoreCase);
    private static readonly Regex PointTagRegex = new(
        @"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$",
        RegexOptions.IgnoreCase);

    public static ParsedReply Parse(string replyText)
    {
        var remainingText = replyText;

        // [REMEMBER:...] can contain anything, so it ends at the "]" before the next tag or the end.
        var rememberRegex = new Regex(@"\[REMEMBER:(.+?)\](?=\s*(?:\[|$))", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        var factsToRemember = rememberRegex.Matches(remainingText).Select(match => match.Groups[1].Value.Trim()).Where(fact => fact.Length > 0).ToList();
        remainingText = rememberRegex.Replace(remainingText, "");

        var drawings = new List<DrawingRequest>();
        foreach (Match shapeMatch in ShapeTagRegex.Matches(remainingText))
        {
            var kind = shapeMatch.Groups[1].Value.ToUpperInvariant() switch
            {
                "CIRCLE" => DrawingKind.Circle,
                "HIGHLIGHT" => DrawingKind.Highlight,
                "UNDERLINE" => DrawingKind.Underline,
                _ => DrawingKind.Arrow
            };
            var numbers = shapeMatch.Groups[2].Value.Split(',').Select(numberText => double.Parse(numberText.Trim(), System.Globalization.CultureInfo.InvariantCulture)).ToArray();
            var expectedNumberCount = kind is DrawingKind.Circle or DrawingKind.Underline ? 3 : 4;
            if (numbers.Length != expectedNumberCount) continue;
            drawings.Add(new DrawingRequest(kind, numbers, EmptyToNull(shapeMatch.Groups[3].Value), ParseScreenNumber(shapeMatch.Groups[4].Value)));
        }
        remainingText = ShapeTagRegex.Replace(remainingText, "");

        foreach (Match textMatch in TextTagRegex.Matches(remainingText))
        {
            var kind = textMatch.Groups[1].Value.Equals("LABEL", StringComparison.OrdinalIgnoreCase) ? DrawingKind.CalloutLabel : DrawingKind.StickyNote;
            var numbers = new[]
            {
                double.Parse(textMatch.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture),
                double.Parse(textMatch.Groups[3].Value, System.Globalization.CultureInfo.InvariantCulture)
            };
            var tagText = textMatch.Groups[4].Value.Replace("\\n", "\n").Trim();
            if (tagText.Length == 0) continue;
            drawings.Add(new DrawingRequest(kind, numbers, tagText, ParseScreenNumber(textMatch.Groups[5].Value)));
        }
        remainingText = TextTagRegex.Replace(remainingText, "");
        remainingText = Regex.Replace(remainingText, @"[ \t]*\n[ \t\n]*", "\n").Trim();

        PointF? pointCoordinate = null;
        string? pointLabel = null;
        int? pointScreenNumber = null;
        var pointMatch = PointTagRegex.Match(remainingText);
        if (pointMatch.Success)
        {
            if (pointMatch.Groups[1].Success && pointMatch.Groups[2].Success)
            {
                pointCoordinate = new PointF(float.Parse(pointMatch.Groups[1].Value), float.Parse(pointMatch.Groups[2].Value));
                pointLabel = EmptyToNull(pointMatch.Groups[3].Value);
                pointScreenNumber = ParseScreenNumber(pointMatch.Groups[4].Value);
            }
            remainingText = remainingText[..pointMatch.Index].Trim();
        }

        return new ParsedReply(remainingText, pointCoordinate, pointLabel, pointScreenNumber, drawings.Take(8).ToList(), factsToRemember);
    }

    private static string? EmptyToNull(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    private static int? ParseScreenNumber(string text) => int.TryParse(text, out var screenNumber) ? screenNumber : null;
}

/// <summary>
/// Splits a reply that's still streaming into complete sentences so speech can start right away.
/// Only text before the first "[" tag counts (tags come at the end). Port of the macOS segmenter.
/// </summary>
public sealed class StreamingSpeechSegmenter
{
    private int consumedCharacterCount;
    public string SpokenTextSoFar { get; private set; } = "";
    public bool HasSpokenAnything => consumedCharacterCount > 0;

    public static string SpeakablePrefix(string replyText)
    {
        var tagStartIndex = replyText.IndexOf('[');
        return tagStartIndex >= 0 ? replyText[..tagStartIndex] : replyText;
    }

    public string? TakeCompletedSentences(string accumulatedReplyText)
    {
        var speakableText = SpeakablePrefix(accumulatedReplyText);
        if (speakableText.Length <= consumedCharacterCount) return null;

        int? lastSentenceEndIndex = null;
        for (var characterIndex = speakableText.Length - 1; characterIndex >= consumedCharacterCount; characterIndex--)
        {
            var character = speakableText[characterIndex];
            if (character == '\n') { lastSentenceEndIndex = characterIndex + 1; break; }
            if (character is '.' or '!' or '?' && characterIndex + 1 < speakableText.Length && char.IsWhiteSpace(speakableText[characterIndex + 1]))
            {
                lastSentenceEndIndex = characterIndex + 1;
                break;
            }
        }
        if (lastSentenceEndIndex is not { } sentenceEndIndex || sentenceEndIndex <= consumedCharacterCount) return null;

        var newSentencesText = speakableText[consumedCharacterCount..sentenceEndIndex];
        if (newSentencesText.Trim().Length < 8 && consumedCharacterCount == 0) return null;
        consumedCharacterCount = sentenceEndIndex;
        SpokenTextSoFar += newSentencesText;
        return newSentencesText;
    }

    public string? TakeRemainder(string fullReplyText)
    {
        var speakableText = SpeakablePrefix(fullReplyText);
        if (speakableText.Length <= consumedCharacterCount) return null;
        var remainderText = speakableText[consumedCharacterCount..];
        consumedCharacterCount = speakableText.Length;
        SpokenTextSoFar += remainderText;
        return string.IsNullOrWhiteSpace(remainderText) ? null : remainderText.Trim();
    }
}

// MARK: - Speech output

/// <summary>Speaks with installed Windows voices. Sentences queue up so playback is continuous.</summary>
public sealed class SpeechOutput : IDisposable
{
    private readonly SpeechSynthesizer speechSynthesizer = new();
    private readonly AppSettings settings;
    private int queuedUtteranceCount;

    public SpeechOutput(AppSettings settings)
    {
        this.settings = settings;
        speechSynthesizer.SetOutputToDefaultAudioDevice();
        speechSynthesizer.SpeakCompleted += (_, _) => Interlocked.Decrement(ref queuedUtteranceCount);
        ApplyVoiceSettings();
    }

    public bool IsSpeaking => Volatile.Read(ref queuedUtteranceCount) > 0;

    public static IReadOnlyList<string> InstalledVoiceNames()
    {
        using var temporarySynthesizer = new SpeechSynthesizer();
        return temporarySynthesizer.GetInstalledVoices().Where(voice => voice.Enabled).Select(voice => voice.VoiceInfo.Name).ToList();
    }

    public void ApplyVoiceSettings()
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(settings.VoiceName)) speechSynthesizer.SelectVoice(settings.VoiceName);
        }
        catch (Exception voiceError)
        {
            Log.Write($"Voice '{settings.VoiceName}' unavailable: {voiceError.Message}");
        }
        speechSynthesizer.Rate = Math.Clamp(settings.SpeechRate, -10, 10);
    }

    public void Enqueue(string text)
    {
        var trimmedText = text.Trim();
        if (trimmedText.Length == 0) return;
        Interlocked.Increment(ref queuedUtteranceCount);
        speechSynthesizer.SpeakAsync(trimmedText);
    }

    public void SpeakNow(string text)
    {
        Stop();
        Enqueue(text);
    }

    public void Stop()
    {
        speechSynthesizer.SpeakAsyncCancelAll();
        Interlocked.Exchange(ref queuedUtteranceCount, 0);
    }

    public void Dispose() => speechSynthesizer.Dispose();
}

// MARK: - Screen capture

/// <summary>One screenshot of one monitor. Bounds are physical pixels (the app is per-monitor DPI aware).</summary>
public sealed record ScreenCapture(
    byte[] JpegData,
    string Label,
    bool IsCursorScreen,
    Rectangle PhysicalBounds,
    int ImageWidth,
    int ImageHeight)
{
    /// <summary>Screenshot pixel (top-left origin) → physical screen point.</summary>
    public PointF ToScreenPoint(double screenshotX, double screenshotY) => new(
        (float)(PhysicalBounds.X + Math.Clamp(screenshotX, 0, ImageWidth) * PhysicalBounds.Width / ImageWidth),
        (float)(PhysicalBounds.Y + Math.Clamp(screenshotY, 0, ImageHeight) * PhysicalBounds.Height / ImageHeight));

    public float ToScreenLength(double screenshotLength) => (float)(screenshotLength * PhysicalBounds.Width / ImageWidth);

    public PointF ToScreenshotPixel(Point screenPoint) => new(
        (float)((screenPoint.X - PhysicalBounds.X) * (double)ImageWidth / PhysicalBounds.Width),
        (float)((screenPoint.Y - PhysicalBounds.Y) * (double)ImageHeight / PhysicalBounds.Height));
}

public static class ScreenCapturer
{
    /// <summary>Screenshots are scaled down to this width to keep requests small and fast.</summary>
    private const int MaximumScreenshotWidth = 1440;

    /// <summary>
    /// Captures every monitor. OpenClicky's own windows are excluded from capture by Windows
    /// (WDA_EXCLUDEFROMCAPTURE); the user's ink strokes are drawn into the image explicitly.
    /// </summary>
    public static List<ScreenCapture> CaptureAllScreens(IReadOnlyList<IReadOnlyList<Point>> userInkStrokes)
    {
        NativeMethods.GetCursorPos(out var cursorPosition);
        var cursorPoint = new Point(cursorPosition.X, cursorPosition.Y);
        var allScreens = WinFormsScreen.AllScreens;
        var screenCaptures = new List<ScreenCapture>();

        for (var screenIndex = 0; screenIndex < allScreens.Length; screenIndex++)
        {
            var screenBounds = allScreens[screenIndex].Bounds;
            using var fullResolutionBitmap = new Bitmap(screenBounds.Width, screenBounds.Height, PixelFormat.Format24bppRgb);
            using (var screenGraphics = Graphics.FromImage(fullResolutionBitmap))
            {
                screenGraphics.CopyFromScreen(screenBounds.Location, Point.Empty, screenBounds.Size);
            }

            var scaleFactor = Math.Min(1.0, (double)MaximumScreenshotWidth / screenBounds.Width);
            var imageWidth = (int)Math.Round(screenBounds.Width * scaleFactor);
            var imageHeight = (int)Math.Round(screenBounds.Height * scaleFactor);
            using var scaledBitmap = new Bitmap(imageWidth, imageHeight, PixelFormat.Format24bppRgb);
            using (var scaledGraphics = Graphics.FromImage(scaledBitmap))
            {
                scaledGraphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                scaledGraphics.DrawImage(fullResolutionBitmap, 0, 0, imageWidth, imageHeight);

                // Burn in the user's ink so Claude sees exactly what they marked.
                using var inkPen = new Pen(Color.FromArgb(255, 255, 107, 61), Math.Max(4f, imageWidth / 320f))
                {
                    StartCap = System.Drawing.Drawing2D.LineCap.Round,
                    EndCap = System.Drawing.Drawing2D.LineCap.Round,
                    LineJoin = System.Drawing.Drawing2D.LineJoin.Round
                };
                foreach (var inkStroke in userInkStrokes)
                {
                    if (inkStroke.Count < 2 || !inkStroke.Any(screenBounds.Contains)) continue;
                    var imagePoints = inkStroke.Select(screenPoint => new PointF(
                        (float)((screenPoint.X - screenBounds.X) * scaleFactor),
                        (float)((screenPoint.Y - screenBounds.Y) * scaleFactor))).ToArray();
                    scaledGraphics.DrawLines(inkPen, imagePoints);
                }
            }

            var isCursorScreen = screenBounds.Contains(cursorPoint);
            var screenLabel = allScreens.Length == 1
                ? "user's screen (cursor is here)"
                : $"screen {screenIndex + 1} of {allScreens.Length}" + (isCursorScreen ? " — cursor is on this screen (primary focus)" : " — secondary screen");
            screenCaptures.Add(new ScreenCapture(EncodeJpeg(scaledBitmap, 80), screenLabel, isCursorScreen, screenBounds, imageWidth, imageHeight));
        }
        return screenCaptures;
    }

    private static byte[] EncodeJpeg(Bitmap bitmap, long quality)
    {
        var jpegEncoder = ImageCodecInfo.GetImageEncoders().First(encoder => encoder.FormatID == ImageFormat.Jpeg.Guid);
        using var encoderParameters = new EncoderParameters(1);
        encoderParameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        using var jpegStream = new MemoryStream();
        bitmap.Save(jpegStream, jpegEncoder, encoderParameters);
        return jpegStream.ToArray();
    }
}

/// <summary>The app and window the user is working in, sent with the question for context.</summary>
public static class FocusedAppContextReader
{
    public static string? ReadPromptDescription()
    {
        try
        {
            var foregroundWindowHandle = NativeMethods.GetForegroundWindow();
            if (foregroundWindowHandle == IntPtr.Zero) return null;

            var windowTitleBuilder = new StringBuilder(512);
            NativeMethods.GetWindowText(foregroundWindowHandle, windowTitleBuilder, windowTitleBuilder.Capacity);
            NativeMethods.GetWindowThreadProcessId(foregroundWindowHandle, out var processIdentifier);
            if (processIdentifier == Environment.ProcessId) return null;

            string? applicationName = null;
            try
            {
                using var foregroundProcess = System.Diagnostics.Process.GetProcessById((int)processIdentifier);
                applicationName = foregroundProcess.MainModule?.FileVersionInfo.FileDescription;
                if (string.IsNullOrWhiteSpace(applicationName)) applicationName = foregroundProcess.ProcessName;
            }
            catch
            {
                // Elevated processes can't be inspected; the window title is still useful.
            }

            var windowTitle = windowTitleBuilder.ToString().Trim();
            if (applicationName == null && windowTitle.Length == 0) return null;
            return windowTitle.Length > 0
                ? $"(context: i'm in {applicationName ?? "an app"}, window \"{(windowTitle.Length > 200 ? windowTitle[..200] : windowTitle)}\")"
                : $"(context: i'm in {applicationName})";
        }
        catch
        {
            return null;
        }
    }
}
