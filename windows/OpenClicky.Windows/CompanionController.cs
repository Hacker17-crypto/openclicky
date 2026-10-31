using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using DrawingPoint = System.Drawing.Point;
using DrawingPointF = System.Drawing.PointF;
using WinFormsScreen = System.Windows.Forms.Screen;

namespace OpenClicky;

/// <summary>
/// The push-to-talk pipeline, same as the macOS CompanionManager:
/// hold Ctrl+Alt → record (and optionally draw) → release → Whisper → screenshot →
/// Claude Code (streamed) → speak sentence by sentence → point and draw on screen.
/// Everything here runs on the WPF UI thread unless noted.
/// </summary>
public sealed class CompanionController : IDisposable
{
    private readonly AppSettings settings;
    private readonly Dispatcher uiDispatcher;
    private readonly GlobalInputHooks inputHooks = new();
    private readonly MicrophoneRecorder microphoneRecorder = new();
    private readonly WhisperTranscriber whisperTranscriber = new();
    private readonly SpeechOutput speechOutput;
    private readonly ClaudeCodeClient claudeCodeClient;
    private readonly List<ScreenOverlayWindow> overlayWindows = new();
    private readonly StatusPillWindow statusPill = new();
    private readonly List<List<DrawingPoint>> userInkStrokes = new();
    private List<MemoryStore.ConversationExchange> conversationHistory;

    private CancellationTokenSource? currentResponseCancellation;
    private CancellationTokenSource? drawingClearCancellation;
    private WhisperModelFile? selectedWhisperModel;
    private readonly DateTime animationStartTime = DateTime.Now;
    private bool isRecording;

    /// <summary>Raised when OpenClicky needs to tell the user something outside the pill (tray balloon).</summary>
    public event Action<string, string>? NotificationRequested;

    public CompanionController(AppSettings settings)
    {
        this.settings = settings;
        uiDispatcher = Dispatcher.CurrentDispatcher;
        speechOutput = new SpeechOutput(settings);
        claudeCodeClient = new ClaudeCodeClient(settings);
        conversationHistory = settings.IsMemoryEnabled ? MemoryStore.LoadConversationHistory() : new();
    }

    public ClaudeCodeClient ClaudeCode => claudeCodeClient;
    public SpeechOutput Speech => speechOutput;
    public WhisperModelFile? SelectedWhisperModel => selectedWhisperModel;

    public void Start()
    {
        CreateOverlayWindows();
        statusPill.Show();

        inputHooks.TalkPressed += HandleTalkPressed;
        inputHooks.TalkReleased += HandleTalkReleased;
        inputHooks.TalkCancelledByOtherKey += HandleTalkCancelled;
        inputHooks.EscapePressed += HandleEscape;
        inputHooks.InkStrokeBegan += inkPoint => { userInkStrokes.Add(new List<DrawingPoint> { inkPoint }); RefreshInk(); };
        inputHooks.InkStrokeMoved += inkPoint => AppendInkPoint(inkPoint);
        inputHooks.InkStrokeEnded += inkPoint => AppendInkPoint(inkPoint);
        inputHooks.Install();

        microphoneRecorder.AudioLevelChanged += audioLevel => uiDispatcher.BeginInvoke(() => statusPill.SetAudioLevel(audioLevel));
        CompositionTarget.Rendering += HandleAnimationFrame;
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += (_, _) => uiDispatcher.BeginInvoke(CreateOverlayWindows);

        ReloadWhisperModel();
    }

    /// <summary>Picks the configured Whisper model, or the best one found on this PC, and preloads it.</summary>
    public void ReloadWhisperModel()
    {
        Task.Run(() =>
        {
            WhisperModelFile? chosenModel = null;
            if (!string.IsNullOrWhiteSpace(settings.SelectedWhisperModelPath) && System.IO.File.Exists(settings.SelectedWhisperModelPath))
            {
                chosenModel = WhisperModelCatalog.InspectModelFile(settings.SelectedWhisperModelPath, "Selected");
            }
            chosenModel ??= WhisperModelCatalog.FindInstalledModels().FirstOrDefault();
            selectedWhisperModel = chosenModel;
            if (chosenModel != null)
            {
                Log.Write($"Using Whisper model {chosenModel.DisplayName} ({chosenModel.FilePath})");
                _ = whisperTranscriber.PreloadAsync(chosenModel.FilePath);
            }
            else
            {
                Log.Write("No Whisper model found yet");
            }
        });
    }

    private void CreateOverlayWindows()
    {
        foreach (var overlayWindow in overlayWindows) overlayWindow.Close();
        overlayWindows.Clear();
        foreach (var screen in WinFormsScreen.AllScreens)
        {
            var overlayWindow = new ScreenOverlayWindow(screen.Bounds);
            overlayWindow.Show();
            overlayWindows.Add(overlayWindow);
        }
    }

    // MARK: Per-frame animation

    private void HandleAnimationFrame(object? sender, EventArgs frameEvent)
    {
        NativeMethods.GetCursorPos(out var cursorPosition);
        var cursorPoint = new DrawingPoint(cursorPosition.X, cursorPosition.Y);
        var elapsedSeconds = (DateTime.Now - animationStartTime).TotalSeconds;
        var buddyPulse = isRecording ? 1 + 0.12 * Math.Sin(elapsedSeconds * 9) : 1;
        var pointingOverlay = overlayWindows.FirstOrDefault(overlayWindow => overlayWindow.IsPointing);

        foreach (var overlayWindow in overlayWindows)
        {
            overlayWindow.UpdateBuddy(cursorPoint, isBuddyEnabled: true, isAnotherScreenPointing: pointingOverlay != null && pointingOverlay != overlayWindow, buddyPulse);
        }
        statusPill.AnimateFrame(elapsedSeconds);
    }

    // MARK: Talk

    private void HandleTalkPressed()
    {
        currentResponseCancellation?.Cancel();
        speechOutput.Stop();
        ClearDrawingsNow();
        userInkStrokes.Clear();

        NativeMethods.GetCursorPos(out var cursorPosition);
        var cursorScreen = WinFormsScreen.FromPoint(new DrawingPoint(cursorPosition.X, cursorPosition.Y));
        statusPill.MoveToScreen(cursorScreen.Bounds);

        if (!claudeCodeClient.IsInstalled)
        {
            statusPill.SetStatus(CompanionStatus.Message, "Install Claude Code first");
            NotificationRequested?.Invoke("Claude Code not found", "Install Claude Code from claude.com/claude-code and run `claude` once to log in.");
            return;
        }

        // Boot Claude Code while the user is still talking (saves about a second).
        claudeCodeClient.Prewarm(BuildSystemPrompt());

        try
        {
            microphoneRecorder.Start();
            isRecording = true;
            statusPill.SetStatus(CompanionStatus.Listening);
        }
        catch (Exception microphoneError)
        {
            statusPill.SetStatus(CompanionStatus.Message, "Microphone unavailable");
            NotificationRequested?.Invoke("Microphone unavailable", microphoneError.Message);
        }
    }

    private void HandleTalkCancelled()
    {
        if (!isRecording) return;
        isRecording = false;
        microphoneRecorder.Stop();
        statusPill.SetStatus(CompanionStatus.Hidden);
    }

    private void HandleTalkReleased()
    {
        if (!isRecording)
        {
            statusPill.SetStatus(CompanionStatus.Hidden);
            return;
        }
        isRecording = false;
        var recordedSamples = microphoneRecorder.Stop();
        var inkForThisQuestion = userInkStrokes.Select(inkStroke => (IReadOnlyList<DrawingPoint>)inkStroke.ToList()).ToList();

        currentResponseCancellation = new CancellationTokenSource();
        _ = RunResponsePipelineAsync(recordedSamples, inkForThisQuestion, currentResponseCancellation.Token);
    }

    private async Task RunResponsePipelineAsync(float[] recordedSamples, List<IReadOnlyList<DrawingPoint>> inkForThisQuestion, CancellationToken cancellationToken)
    {
        try
        {
            if (recordedSamples.Length < 4_800)
            {
                statusPill.SetStatus(CompanionStatus.Hidden);
                return;
            }

            statusPill.SetStatus(CompanionStatus.Thinking);

            if (selectedWhisperModel == null)
            {
                statusPill.SetStatus(CompanionStatus.Message, "No speech model yet. Open Settings");
                NotificationRequested?.Invoke("Pick a speech model", "OpenClicky needs a Whisper model to understand you. Open Settings from the tray icon and download one (Base is 148 MB).");
                return;
            }

            var transcript = await whisperTranscriber.TranscribeAsync(recordedSamples, selectedWhisperModel, "OpenClicky, Claude, Claude Code", cancellationToken);
            if (cancellationToken.IsCancellationRequested) return;
            if (string.IsNullOrWhiteSpace(transcript))
            {
                statusPill.SetStatus(CompanionStatus.Hidden);
                return;
            }
            Log.Write($"Heard: {transcript}");

            var focusedAppContext = FocusedAppContextReader.ReadPromptDescription();
            var screenCaptures = await Task.Run(() => ScreenCapturer.CaptureAllScreens(inkForThisQuestion), cancellationToken);
            var labeledImages = screenCaptures
                .Select(capture => new ClaudeCodeClient.LabeledImage(capture.JpegData, $"{capture.Label} (image dimensions: {capture.ImageWidth}x{capture.ImageHeight} pixels)"))
                .ToList();

            var userPrompt = transcript;
            if (inkForThisQuestion.Count > 0) userPrompt += "\n\n(i drew on my screen in orange to show you what i mean.)";
            if (focusedAppContext != null) userPrompt += "\n\n" + focusedAppContext;

            var speechSegmenter = new StreamingSpeechSegmenter();
            var fullReplyText = await claudeCodeClient.AskAsync(
                labeledImages,
                BuildSystemPrompt(),
                conversationHistory,
                userPrompt,
                accumulatedReplyText => uiDispatcher.BeginInvoke(() =>
                {
                    if (cancellationToken.IsCancellationRequested) return;
                    // Speak each sentence as soon as Claude finishes writing it.
                    var completedSentences = speechSegmenter.TakeCompletedSentences(accumulatedReplyText);
                    if (completedSentences == null) return;
                    speechOutput.Enqueue(completedSentences);
                    statusPill.SetStatus(CompanionStatus.Speaking);
                    if (settings.ShowsCaptions) statusPill.SetCaption(speechSegmenter.SpokenTextSoFar.Trim());
                }),
                cancellationToken);

            await uiDispatcher.InvokeAsync(() => FinishResponse(fullReplyText, transcript, screenCaptures, speechSegmenter));
        }
        catch (OperationCanceledException)
        {
            // The user pressed the hotkey again or Escape.
        }
        catch (ClaudeCodeException claudeError)
        {
            Log.Write(claudeError.Message);
            var spokenError = claudeError.Kind switch
            {
                ClaudeCodeException.FailureKind.NotInstalled => "I can't find Claude Code on this PC. Install it, run claude once to log in, then try again.",
                ClaudeCodeException.FailureKind.NotLoggedIn => "Claude Code isn't logged in. Open a terminal, run claude, and log in, then try again.",
                _ => "Claude Code ran into a problem. Check that you haven't hit your usage limit, then try again."
            };
            speechOutput.SpeakNow(spokenError);
            statusPill.SetStatus(CompanionStatus.Message, "Claude Code problem");
            _ = HidePillWhenSpeechEndsAsync();
        }
        catch (Exception unexpectedError)
        {
            Log.Write($"Response error: {unexpectedError}");
            speechOutput.SpeakNow("Something went wrong. Try again in a moment.");
            statusPill.SetStatus(CompanionStatus.Hidden);
        }
    }

    private void FinishResponse(string fullReplyText, string transcript, List<ScreenCapture> screenCaptures, StreamingSpeechSegmenter speechSegmenter)
    {
        var parsedReply = ResponseTagParser.Parse(fullReplyText);
        Log.Write($"Reply: {fullReplyText}");

        var remainingSpeech = speechSegmenter.TakeRemainder(fullReplyText);
        if (remainingSpeech != null) speechOutput.Enqueue(remainingSpeech);
        if (speechSegmenter.HasSpokenAnything)
        {
            statusPill.SetStatus(CompanionStatus.Speaking);
            if (settings.ShowsCaptions) statusPill.SetCaption(parsedReply.SpokenText);
        }

        if (settings.IsMemoryEnabled)
        {
            foreach (var factToRemember in parsedReply.FactsToRemember) MemoryStore.RememberFact(factToRemember);
        }

        conversationHistory.Add(new MemoryStore.ConversationExchange(transcript, parsedReply.SpokenText));
        if (conversationHistory.Count > MemoryStore.MaximumStoredExchangeCount)
        {
            conversationHistory.RemoveRange(0, conversationHistory.Count - MemoryStore.MaximumStoredExchangeCount);
        }
        if (settings.IsMemoryEnabled) MemoryStore.SaveConversationHistory(conversationHistory);

        ShowDrawings(parsedReply.Drawings, screenCaptures);

        if (parsedReply.PointCoordinate is { } pointCoordinate)
        {
            var targetCapture = PickCapture(screenCaptures, parsedReply.PointScreenNumber);
            if (targetCapture != null)
            {
                var targetPhysicalPoint = targetCapture.ToScreenPoint(pointCoordinate.X, pointCoordinate.Y);
                var targetOverlay = overlayWindows.FirstOrDefault(overlayWindow => overlayWindow.ContainsPhysicalPoint(DrawingPoint.Round(targetPhysicalPoint)));
                _ = targetOverlay?.FlyToAndPointAsync(targetPhysicalPoint, parsedReply.PointLabel);
            }
        }

        _ = HidePillWhenSpeechEndsAsync();
    }

    private static ScreenCapture? PickCapture(IReadOnlyList<ScreenCapture> screenCaptures, int? screenNumber)
    {
        if (screenNumber is { } requestedScreenNumber && requestedScreenNumber >= 1 && requestedScreenNumber <= screenCaptures.Count)
        {
            return screenCaptures[requestedScreenNumber - 1];
        }
        return screenCaptures.FirstOrDefault(capture => capture.IsCursorScreen) ?? screenCaptures.FirstOrDefault();
    }

    private void ShowDrawings(IReadOnlyList<DrawingRequest> drawingRequests, IReadOnlyList<ScreenCapture> screenCaptures)
    {
        for (var drawingIndex = 0; drawingIndex < drawingRequests.Count; drawingIndex++)
        {
            var drawingRequest = drawingRequests[drawingIndex];
            var targetCapture = PickCapture(screenCaptures, drawingRequest.ScreenNumber);
            if (targetCapture == null) continue;

            var numbers = drawingRequest.Numbers;
            ScreenDrawing screenDrawing = drawingRequest.Kind switch
            {
                DrawingKind.Circle => new(DrawingKind.Circle, new[] { targetCapture.ToScreenPoint(numbers[0], numbers[1]) }, targetCapture.ToScreenLength(numbers[2]), 0, 0, drawingRequest.Label),
                DrawingKind.Highlight => new(DrawingKind.Highlight, new[] { targetCapture.ToScreenPoint(numbers[0], numbers[1]) }, 0, targetCapture.ToScreenLength(numbers[2]), targetCapture.ToScreenLength(numbers[3]), drawingRequest.Label),
                DrawingKind.Underline => new(DrawingKind.Underline, new[] { targetCapture.ToScreenPoint(numbers[0], numbers[2]), targetCapture.ToScreenPoint(numbers[1], numbers[2]) }, 0, 0, 0, drawingRequest.Label),
                DrawingKind.Arrow => new(DrawingKind.Arrow, new[] { targetCapture.ToScreenPoint(numbers[0], numbers[1]), targetCapture.ToScreenPoint(numbers[2], numbers[3]) }, 0, 0, 0, drawingRequest.Label),
                _ => new(drawingRequest.Kind, new[] { targetCapture.ToScreenPoint(numbers[0], numbers[1]) }, 0, 0, 0, drawingRequest.Label)
            };

            var targetOverlay = overlayWindows.FirstOrDefault(overlayWindow => overlayWindow.PhysicalBounds == targetCapture.PhysicalBounds);
            // One drawing after another, like a person moving the pen.
            targetOverlay?.AddDrawing(screenDrawing, appearanceDelaySeconds: drawingIndex * 0.38, paletteIndex: drawingIndex);
        }
    }

    /// <summary>Hides the pill shortly after speech ends; clears drawings 5 seconds later.</summary>
    private async Task HidePillWhenSpeechEndsAsync()
    {
        drawingClearCancellation?.Cancel();
        var clearCancellation = new CancellationTokenSource();
        drawingClearCancellation = clearCancellation;
        try
        {
            await Task.Delay(800, clearCancellation.Token);
            while (speechOutput.IsSpeaking) await Task.Delay(250, clearCancellation.Token);
            await Task.Delay(1500, clearCancellation.Token);
            statusPill.SetStatus(CompanionStatus.Hidden);
            await Task.Delay(5000, clearCancellation.Token);
            foreach (var overlayWindow in overlayWindows) overlayWindow.ClearDrawings();
            userInkStrokes.Clear();
        }
        catch (TaskCanceledException)
        {
        }
    }

    private void ClearDrawingsNow()
    {
        drawingClearCancellation?.Cancel();
        foreach (var overlayWindow in overlayWindows) overlayWindow.ClearDrawings(isAnimated: false);
    }

    // MARK: Escape and ink

    private void HandleEscape()
    {
        var isBusy = isRecording || speechOutput.IsSpeaking || currentResponseCancellation is { IsCancellationRequested: false };
        if (!isBusy) return;
        currentResponseCancellation?.Cancel();
        if (isRecording)
        {
            isRecording = false;
            microphoneRecorder.Stop();
        }
        speechOutput.Stop();
        claudeCodeClient.DiscardPrewarmedProcess();
        foreach (var overlayWindow in overlayWindows) overlayWindow.ClearDrawings();
        userInkStrokes.Clear();
        statusPill.SetStatus(CompanionStatus.Hidden);
    }

    private void AppendInkPoint(DrawingPoint inkPoint)
    {
        if (userInkStrokes.Count == 0) return;
        var currentInkStroke = userInkStrokes[^1];
        var lastInkPoint = currentInkStroke[^1];
        if (Math.Abs(inkPoint.X - lastInkPoint.X) + Math.Abs(inkPoint.Y - lastInkPoint.Y) < 3) return;
        currentInkStroke.Add(inkPoint);
        RefreshInk();
    }

    private void RefreshInk()
    {
        foreach (var overlayWindow in overlayWindows) overlayWindow.ShowUserInk(userInkStrokes);
    }

    // MARK: Prompt

    private string BuildSystemPrompt()
    {
        var systemPrompt = Prompts.CompanionPersona + "\n" + Prompts.CompanionCapabilities;
        if (settings.IsMemoryEnabled)
        {
            var profileText = MemoryStore.ReadProfileText();
            if (profileText.Length > 0) systemPrompt += "\n\nwhat you already know about the user (from earlier conversations):\n" + profileText;
        }
        return systemPrompt;
    }

    public void ClearConversation()
    {
        conversationHistory.Clear();
        MemoryStore.ClearConversationHistory();
    }

    /// <summary>First-run hello: the pill introduces the shortcut and the buddy says hi.</summary>
    public async Task ShowWelcomeAsync()
    {
        NativeMethods.GetCursorPos(out var cursorPosition);
        statusPill.MoveToScreen(WinFormsScreen.FromPoint(new DrawingPoint(cursorPosition.X, cursorPosition.Y)).Bounds);
        statusPill.SetStatus(CompanionStatus.Message, "Hold Ctrl + Alt and talk to me");
        speechOutput.SpeakNow("hey! i'm openclicky. hold control and alt, and ask me anything about your screen.");
        await Task.Delay(7000);
        statusPill.SetStatus(CompanionStatus.Hidden);
    }

    public void Dispose()
    {
        CompositionTarget.Rendering -= HandleAnimationFrame;
        currentResponseCancellation?.Cancel();
        claudeCodeClient.DiscardPrewarmedProcess();
        inputHooks.Dispose();
        microphoneRecorder.Dispose();
        whisperTranscriber.Dispose();
        speechOutput.Dispose();
        foreach (var overlayWindow in overlayWindows) overlayWindow.Close();
        statusPill.Close();
    }
}
