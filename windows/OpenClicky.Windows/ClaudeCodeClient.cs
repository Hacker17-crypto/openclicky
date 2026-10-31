using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OpenClicky;

public sealed class ClaudeCodeException : Exception
{
    public enum FailureKind { NotInstalled, NotLoggedIn, RequestFailed }

    public FailureKind Kind { get; }

    public ClaudeCodeException(FailureKind kind, string message) : base(message)
    {
        Kind = kind;
    }
}

/// <summary>
/// Talks to Claude through the user's local Claude Code CLI, the same way the macOS app does:
///   claude --print --input-format stream-json --output-format stream-json --verbose
///          --include-partial-messages --model M --system-prompt-file F --tools ""
///          --strict-mcp-config --setting-sources user --disable-slash-commands --no-session-persistence
/// One user message (history, screenshots, question) goes to stdin; text deltas stream back.
/// A process is pre-started while the user is still talking to hide Claude Code's startup time.
/// </summary>
public sealed class ClaudeCodeClient
{
    private readonly AppSettings settings;
    private readonly object prewarmLock = new();
    private PreparedProcess? prewarmedProcess;

    private sealed record PreparedProcess(Process Process, string SystemPrompt, string Model, DateTime CreatedAt);

    public ClaudeCodeClient(AppSettings settings)
    {
        this.settings = settings;
    }

    // MARK: Finding Claude Code

    /// <summary>How to launch Claude Code: either claude.exe directly, or node.exe + the npm package's cli.js.</summary>
    private sealed record ClaudeLaunchCommand(string ExecutablePath, string? ScriptPath);

    private ClaudeLaunchCommand? cachedLaunchCommand;

    public bool IsInstalled => TryResolveLaunchCommand() != null;

    private ClaudeLaunchCommand? TryResolveLaunchCommand()
    {
        if (cachedLaunchCommand != null && File.Exists(cachedLaunchCommand.ExecutablePath)) return cachedLaunchCommand;

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        var executableCandidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(settings.ClaudeExecutablePathOverride)) executableCandidates.Add(settings.ClaudeExecutablePathOverride.Trim().Trim('"'));
        executableCandidates.Add(Path.Combine(userProfile, ".local", "bin", "claude.exe"));
        executableCandidates.Add(Path.Combine(localAppData, "Programs", "claude", "claude.exe"));
        executableCandidates.Add(Path.Combine(localAppData, "Microsoft", "WinGet", "Links", "claude.exe"));
        executableCandidates.AddRange(FindOnPath("claude.exe"));

        foreach (var executableCandidate in executableCandidates)
        {
            if (File.Exists(executableCandidate))
            {
                return cachedLaunchCommand = new ClaudeLaunchCommand(executableCandidate, null);
            }
        }

        // npm install -g @anthropic-ai/claude-code: run its cli.js with node directly (avoids cmd.exe quoting).
        var npmCliScriptPath = Path.Combine(roamingAppData, "npm", "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        if (File.Exists(npmCliScriptPath))
        {
            var nodeExecutablePath = FindOnPath("node.exe").FirstOrDefault()
                ?? new[] { @"C:\Program Files\nodejs\node.exe", Path.Combine(localAppData, "Programs", "nodejs", "node.exe") }.FirstOrDefault(File.Exists);
            if (nodeExecutablePath != null)
            {
                return cachedLaunchCommand = new ClaudeLaunchCommand(nodeExecutablePath, npmCliScriptPath);
            }
        }

        return null;
    }

    private static IEnumerable<string> FindOnPath(string executableName)
    {
        var searchPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directoryPath in searchPath.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidatePath;
            try { candidatePath = Path.Combine(directoryPath.Trim(), executableName); }
            catch { continue; }
            if (File.Exists(candidatePath)) yield return candidatePath;
        }
    }

    // MARK: Process Setup

    private Process StartClaudeProcess(string systemPrompt, string model)
    {
        var launchCommand = TryResolveLaunchCommand() ?? throw new ClaudeCodeException(
            ClaudeCodeException.FailureKind.NotInstalled,
            "Claude Code isn't installed. Install it from claude.com/claude-code, run claude once to log in, then try again.");

        // Long prompts with quotes and newlines are fragile as Windows command-line arguments.
        var systemPromptFilePath = Path.Combine(AppPaths.DataDirectory, $"system-prompt-{Guid.NewGuid():N}.txt");
        File.WriteAllText(systemPromptFilePath, systemPrompt, new UTF8Encoding(false));

        var startInfo = new ProcessStartInfo
        {
            FileName = launchCommand.ExecutablePath,
            WorkingDirectory = AppPaths.ClaudeWorkspaceDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false)
        };
        if (launchCommand.ScriptPath != null) startInfo.ArgumentList.Add(launchCommand.ScriptPath);
        foreach (var argument in new[]
        {
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--system-prompt-file", systemPromptFilePath,
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "user",
            "--disable-slash-commands",
            "--no-session-persistence"
        })
        {
            startInfo.ArgumentList.Add(argument);
        }
        // Don't let a child of a Claude Code terminal think it's nested.
        startInfo.Environment.Remove("CLAUDECODE");
        startInfo.Environment.Remove("CLAUDE_CODE_ENTRYPOINT");

        var claudeProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        claudeProcess.Exited += (_, _) =>
        {
            try { File.Delete(systemPromptFilePath); } catch { }
        };
        claudeProcess.Start();
        return claudeProcess;
    }

    /// <summary>Starts Claude Code while the user is still talking; it waits on stdin until used.</summary>
    public void Prewarm(string systemPrompt)
    {
        var model = settings.ClaudeModel;
        Task.Run(async () =>
        {
            DiscardPrewarmedProcess();
            Process claudeProcess;
            try { claudeProcess = StartClaudeProcess(systemPrompt, model); }
            catch { return; }

            var preparedProcess = new PreparedProcess(claudeProcess, systemPrompt, model, DateTime.UtcNow);
            lock (prewarmLock) prewarmedProcess = preparedProcess;

            // Don't keep an unused process around if the user never asks anything.
            await Task.Delay(TimeSpan.FromMinutes(2));
            var isStillUnused = false;
            lock (prewarmLock) isStillUnused = ReferenceEquals(prewarmedProcess, preparedProcess);
            if (isStillUnused) DiscardPrewarmedProcess();
        });
    }

    public void DiscardPrewarmedProcess()
    {
        PreparedProcess? unusedProcess;
        lock (prewarmLock)
        {
            unusedProcess = prewarmedProcess;
            prewarmedProcess = null;
        }
        TryKill(unusedProcess?.Process);
    }

    private Process? TakePrewarmedProcess(string systemPrompt, string model)
    {
        PreparedProcess? candidateProcess;
        lock (prewarmLock)
        {
            candidateProcess = prewarmedProcess;
            prewarmedProcess = null;
        }
        if (candidateProcess == null) return null;

        var isUsable = !candidateProcess.Process.HasExited
            && candidateProcess.SystemPrompt == systemPrompt
            && candidateProcess.Model == model
            && DateTime.UtcNow - candidateProcess.CreatedAt < TimeSpan.FromMinutes(2);
        if (isUsable) return candidateProcess.Process;

        TryKill(candidateProcess.Process);
        return null;
    }

    private static void TryKill(Process? process)
    {
        try { if (process != null && !process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    // MARK: Requests

    public sealed record LabeledImage(byte[] JpegData, string Label);

    /// <summary>
    /// Sends screenshots + question (with prior exchanges as context) and streams the reply.
    /// <paramref name="onAccumulatedText"/> receives the full text so far after each chunk.
    /// </summary>
    public async Task<string> AskAsync(
        IReadOnlyList<LabeledImage> images,
        string systemPrompt,
        IReadOnlyList<MemoryStore.ConversationExchange> conversationHistory,
        string userPrompt,
        Action<string> onAccumulatedText,
        CancellationToken cancellationToken,
        string? modelOverride = null)
    {
        var model = modelOverride ?? settings.ClaudeModel;
        var claudeProcess = TakePrewarmedProcess(systemPrompt, model) ?? StartClaudeProcess(systemPrompt, model);
        using var cancellationRegistration = cancellationToken.Register(() => TryKill(claudeProcess));

        var standardErrorTask = claudeProcess.StandardError.ReadToEndAsync();

        // One stream-json user message, then close stdin so Claude Code knows the turn is complete.
        var userMessageLine = BuildUserMessageLine(images, conversationHistory, userPrompt);
        try
        {
            await claudeProcess.StandardInput.WriteLineAsync(userMessageLine.AsMemory(), cancellationToken);
            await claudeProcess.StandardInput.FlushAsync(cancellationToken);
            claudeProcess.StandardInput.Close();
        }
        catch (IOException)
        {
            // Claude Code exited early (e.g. not logged in); its output below explains why.
        }

        var accumulatedText = new StringBuilder();
        string? finalResultText = null;
        string? finalErrorMessage = null;

        while (await claudeProcess.StandardOutput.ReadLineAsync(cancellationToken) is { } outputLine)
        {
            JsonNode? outputEvent;
            try { outputEvent = JsonNode.Parse(outputLine); }
            catch { continue; }
            var eventType = outputEvent?["type"]?.GetValue<string>();

            switch (eventType)
            {
                case "stream_event":
                    var streamEvent = outputEvent!["event"];
                    if (streamEvent?["type"]?.GetValue<string>() == "content_block_delta"
                        && streamEvent["delta"]?["type"]?.GetValue<string>() == "text_delta")
                    {
                        accumulatedText.Append(streamEvent["delta"]?["text"]?.GetValue<string>());
                        onAccumulatedText(accumulatedText.ToString());
                    }
                    break;

                case "assistant" when accumulatedText.Length == 0:
                    var contentBlocks = outputEvent!["message"]?["content"]?.AsArray();
                    if (contentBlocks != null)
                    {
                        foreach (var contentBlock in contentBlocks)
                        {
                            if (contentBlock?["type"]?.GetValue<string>() == "text") accumulatedText.Append(contentBlock["text"]?.GetValue<string>());
                        }
                        if (accumulatedText.Length > 0) onAccumulatedText(accumulatedText.ToString());
                    }
                    break;

                case "result":
                    var isErrorResult = outputEvent!["is_error"]?.GetValue<bool>() ?? false;
                    var resultSubtype = outputEvent["subtype"]?.GetValue<string>();
                    var resultText = outputEvent["result"]?.GetValue<string>();
                    if (isErrorResult || (resultSubtype != null && resultSubtype != "success"))
                    {
                        finalErrorMessage = resultText ?? resultSubtype ?? "Claude Code reported an error";
                    }
                    else
                    {
                        finalResultText = resultText;
                    }
                    break;
            }
        }

        await claudeProcess.WaitForExitAsync(cancellationToken);
        var standardErrorText = (await standardErrorTask).Trim();

        if (finalErrorMessage != null) throw ClassifyError(finalErrorMessage);
        if (accumulatedText.Length == 0 && !string.IsNullOrEmpty(finalResultText))
        {
            accumulatedText.Append(finalResultText);
            onAccumulatedText(finalResultText);
        }
        if (accumulatedText.Length == 0)
        {
            throw ClassifyError(standardErrorText.Length > 0 ? standardErrorText : $"Claude Code exited with code {claudeProcess.ExitCode} and no response");
        }
        return accumulatedText.ToString();
    }

    private static string BuildUserMessageLine(
        IReadOnlyList<LabeledImage> images,
        IReadOnlyList<MemoryStore.ConversationExchange> conversationHistory,
        string userPrompt)
    {
        var contentBlocks = new JsonArray();
        if (conversationHistory.Count > 0)
        {
            var conversationTranscript = new StringBuilder("for context, here's our conversation so far (oldest first):\n");
            foreach (var exchange in conversationHistory)
            {
                conversationTranscript.Append($"\nuser: {exchange.UserTranscript}\nyou: {exchange.AssistantResponse}\n");
            }
            contentBlocks.Add(new JsonObject { ["type"] = "text", ["text"] = conversationTranscript.ToString() });
        }
        foreach (var image in images)
        {
            contentBlocks.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject
                {
                    ["type"] = "base64",
                    ["media_type"] = "image/jpeg",
                    ["data"] = Convert.ToBase64String(image.JpegData)
                }
            });
            contentBlocks.Add(new JsonObject { ["type"] = "text", ["text"] = image.Label });
        }
        contentBlocks.Add(new JsonObject { ["type"] = "text", ["text"] = userPrompt });

        var userMessage = new JsonObject
        {
            ["type"] = "user",
            ["message"] = new JsonObject { ["role"] = "user", ["content"] = contentBlocks }
        };
        return userMessage.ToJsonString(new JsonSerializerOptions { WriteIndented = false });
    }

    private static ClaudeCodeException ClassifyError(string cliMessage)
    {
        var lowercasedMessage = cliMessage.ToLowerInvariant();
        var looksLikeAuthenticationProblem = lowercasedMessage.Contains("/login") || lowercasedMessage.Contains("not logged in")
            || lowercasedMessage.Contains("invalid api key") || lowercasedMessage.Contains("authentication") || lowercasedMessage.Contains("oauth");
        return new ClaudeCodeException(
            looksLikeAuthenticationProblem ? ClaudeCodeException.FailureKind.NotLoggedIn : ClaudeCodeException.FailureKind.RequestFailed,
            "Claude Code: " + cliMessage);
    }
}
