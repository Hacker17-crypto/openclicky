using System.IO;
using System.Text.Json;

namespace OpenClicky;

/// <summary>Where OpenClicky keeps its files: %APPDATA%\OpenClicky.</summary>
public static class AppPaths
{
    public static string DataDirectory => EnsureDirectory(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenClicky"));

    public static string SettingsFile => Path.Combine(DataDirectory, "settings.json");
    public static string ProfileFile => Path.Combine(DataDirectory, "PROFILE.md");
    public static string ConversationFile => Path.Combine(DataDirectory, "conversation.json");
    public static string TalkSystemPromptFile => Path.Combine(DataDirectory, "talk-system-prompt.txt");
    public static string WhisperModelsDirectory => EnsureDirectory(Path.Combine(DataDirectory, "whisper-models"));

    /// <summary>Claude Code runs here so no project's CLAUDE.md or settings get picked up.</summary>
    public static string ClaudeWorkspaceDirectory => EnsureDirectory(Path.Combine(DataDirectory, "claude-workspace"));

    private static string EnsureDirectory(string directoryPath)
    {
        Directory.CreateDirectory(directoryPath);
        return directoryPath;
    }
}

/// <summary>User preferences, persisted as JSON.</summary>
public sealed class AppSettings
{
    /// <summary>Claude Code model alias: "haiku", "sonnet" or "opus".</summary>
    public string ClaudeModel { get; set; } = "sonnet";

    /// <summary>Optional full path to claude.exe when it isn't found automatically.</summary>
    public string ClaudeExecutablePathOverride { get; set; } = "";

    /// <summary>Installed Windows voice name; empty picks the default voice.</summary>
    public string VoiceName { get; set; } = "";

    /// <summary>System.Speech rate, -10 (slow) to 10 (fast).</summary>
    public int SpeechRate { get; set; } = 1;

    public bool ShowsCaptions { get; set; } = true;
    public bool IsMemoryEnabled { get; set; } = true;
    public string SelectedWhisperModelPath { get; set; } = "";
    public bool HasCompletedFirstRun { get; set; }

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(AppPaths.SettingsFile))
            {
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(AppPaths.SettingsFile)) ?? new AppSettings();
            }
        }
        catch (Exception loadError)
        {
            Log.Write($"Settings unreadable, using defaults: {loadError.Message}");
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            File.WriteAllText(AppPaths.SettingsFile, JsonSerializer.Serialize(this, JsonOptions));
        }
        catch (Exception saveError)
        {
            Log.Write($"Couldn't save settings: {saveError.Message}");
        }
    }
}

/// <summary>
/// Long-term memory as plain files the user can read and edit: PROFILE.md (facts about the
/// user) and conversation.json (the last 20 exchanges).
/// </summary>
public static class MemoryStore
{
    public const int MaximumStoredExchangeCount = 20;

    public sealed record ConversationExchange(string UserTranscript, string AssistantResponse);

    public static string ReadProfileText()
    {
        try
        {
            return File.Exists(AppPaths.ProfileFile) ? File.ReadAllText(AppPaths.ProfileFile).Trim() : "";
        }
        catch
        {
            return "";
        }
    }

    public static void RememberFact(string fact)
    {
        var trimmedFact = fact.Trim();
        if (trimmedFact.Length == 0) return;

        var existingProfileText = ReadProfileText();
        if (existingProfileText.Length == 0)
        {
            existingProfileText = "# What OpenClicky knows about you\n\n<!-- Edit freely. Each bullet is sent to Claude with your questions. -->\n";
        }

        var factBulletLine = "- " + trimmedFact;
        if (existingProfileText.Contains(factBulletLine, StringComparison.OrdinalIgnoreCase)) return;

        File.WriteAllText(AppPaths.ProfileFile, existingProfileText + "\n" + factBulletLine + "\n");
        Log.Write($"Remembered: {trimmedFact}");
    }

    public static void OpenProfileInEditor()
    {
        if (!File.Exists(AppPaths.ProfileFile))
        {
            File.WriteAllText(AppPaths.ProfileFile, "# What OpenClicky knows about you\n\n<!-- Edit freely. Each bullet is sent to Claude with your questions. -->\n");
        }
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppPaths.ProfileFile) { UseShellExecute = true });
    }

    public static List<ConversationExchange> LoadConversationHistory()
    {
        try
        {
            if (!File.Exists(AppPaths.ConversationFile)) return new();
            var storedExchanges = JsonSerializer.Deserialize<List<ConversationExchange>>(File.ReadAllText(AppPaths.ConversationFile)) ?? new();
            return storedExchanges.TakeLast(MaximumStoredExchangeCount).ToList();
        }
        catch
        {
            return new();
        }
    }

    public static void SaveConversationHistory(List<ConversationExchange> conversationHistory)
    {
        try
        {
            File.WriteAllText(AppPaths.ConversationFile, JsonSerializer.Serialize(conversationHistory.TakeLast(MaximumStoredExchangeCount).ToList()));
        }
        catch (Exception saveError)
        {
            Log.Write($"Couldn't save conversation: {saveError.Message}");
        }
    }

    public static void ClearConversationHistory()
    {
        try { File.Delete(AppPaths.ConversationFile); } catch { }
    }
}

/// <summary>Plain-text log at %APPDATA%\OpenClicky\openclicky.log (for troubleshooting).</summary>
public static class Log
{
    private static readonly object LogFileLock = new();

    public static void Write(string message)
    {
        var logLine = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}";
        System.Diagnostics.Debug.WriteLine(logLine);
        try
        {
            lock (LogFileLock)
            {
                var logFilePath = Path.Combine(AppPaths.DataDirectory, "openclicky.log");
                if (File.Exists(logFilePath) && new FileInfo(logFilePath).Length > 2_000_000)
                {
                    File.Delete(logFilePath);
                }
                File.AppendAllText(logFilePath, logLine + Environment.NewLine);
            }
        }
        catch
        {
            // Logging must never break the app.
        }
    }
}
