using System.IO;
using System.Net.Http;
using NAudio.Wave;
using Whisper.net;

namespace OpenClicky;

/// <summary>Records 16 kHz mono audio from the default microphone while push-to-talk is held.</summary>
public sealed class MicrophoneRecorder : IDisposable
{
    /// <summary>Live input level, 0 to 1, for the status pill's waveform.</summary>
    public event Action<float>? AudioLevelChanged;

    private WaveInEvent? activeWaveInput;
    private readonly List<float> recordedSamples = new();
    private readonly object recordedSamplesLock = new();

    public bool IsRecording => activeWaveInput != null;

    public void Start()
    {
        Stop();
        lock (recordedSamplesLock) recordedSamples.Clear();

        var waveInput = new WaveInEvent
        {
            WaveFormat = new WaveFormat(16_000, 16, 1),
            BufferMilliseconds = 50
        };
        waveInput.DataAvailable += HandleAudioData;
        try
        {
            waveInput.StartRecording();
            activeWaveInput = waveInput;
        }
        catch (Exception microphoneError)
        {
            waveInput.Dispose();
            Log.Write($"Microphone unavailable: {microphoneError.Message}");
            throw new InvalidOperationException("I can't reach your microphone. Check Windows Settings, Privacy and security, Microphone.", microphoneError);
        }
    }

    /// <summary>Stops recording and returns the samples as floats in [-1, 1].</summary>
    public float[] Stop()
    {
        if (activeWaveInput != null)
        {
            activeWaveInput.DataAvailable -= HandleAudioData;
            try { activeWaveInput.StopRecording(); } catch { }
            activeWaveInput.Dispose();
            activeWaveInput = null;
        }
        lock (recordedSamplesLock) return recordedSamples.ToArray();
    }

    private void HandleAudioData(object? sender, WaveInEventArgs audioEvent)
    {
        var sampleCount = audioEvent.BytesRecorded / 2;
        var squaredSum = 0.0;
        var newSamples = new float[sampleCount];
        for (var sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++)
        {
            var sampleValue = BitConverter.ToInt16(audioEvent.Buffer, sampleIndex * 2) / 32768f;
            newSamples[sampleIndex] = sampleValue;
            squaredSum += sampleValue * sampleValue;
        }
        lock (recordedSamplesLock) recordedSamples.AddRange(newSamples);

        var rootMeanSquare = sampleCount > 0 ? Math.Sqrt(squaredSum / sampleCount) : 0;
        AudioLevelChanged?.Invoke((float)Math.Min(1.0, rootMeanSquare * 6));
    }

    public void Dispose() => Stop();
}

/// <summary>A Whisper model in whisper.cpp's ggml format, identified by its file header.</summary>
public sealed record WhisperModelFile(
    string FilePath,
    long SizeInBytes,
    string SourceName,
    int AudioLayerCount,
    int TextLayerCount,
    int VocabularySize,
    int MelBandCount,
    string QuantizationName)
{
    /// <summary>English-only Whisper checkpoints have a 51864-token vocabulary.</summary>
    public bool IsEnglishOnly => VocabularySize == 51864;

    public string SizeName => AudioLayerCount switch
    {
        4 => "Tiny",
        6 => "Base",
        12 => "Small",
        24 => "Medium",
        32 => TextLayerCount <= 4 ? "Large v3 Turbo" : (MelBandCount == 128 ? "Large v3" : "Large v2"),
        _ => "Whisper"
    };

    public string DisplayName =>
        SizeName + (IsEnglishOnly ? " (English)" : "") + (QuantizationName is "f16" or "f32" ? "" : " " + QuantizationName);

    public int QualityRank => AudioLayerCount * 10 + (QuantizationName is "f16" or "f32" ? 2 : 0) + (TextLayerCount > 4 ? 1 : 0);
}

/// <summary>
/// Finds Whisper models already on this PC (from any app: Superwhisper, Buzz, Hugging Face
/// downloads, whisper.cpp, Downloads) by reading each candidate file's ggml header, and
/// downloads one when none exists.
/// </summary>
public static class WhisperModelCatalog
{
    public sealed record DownloadableModel(string FileName, string Title, string ApproximateSize, string Detail)
    {
        public string DownloadUrl => $"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}";
    }

    public static readonly DownloadableModel[] DownloadableModels =
    {
        new("ggml-base.en.bin", "Base (English)", "148 MB", "Fast, good for short commands"),
        new("ggml-small.en.bin", "Small (English)", "488 MB", "More accurate"),
        new("ggml-large-v3-turbo-q5_0.bin", "Large v3 Turbo", "574 MB", "Most accurate, 99 languages")
    };

    private static IEnumerable<(string DirectoryPath, string SourceName)> SearchLocations()
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);

        yield return (AppPaths.WhisperModelsDirectory, "OpenClicky");
        yield return (Path.Combine(userProfile, "superwhisper"), "Superwhisper");
        yield return (Path.Combine(documents, "superwhisper"), "Superwhisper");
        yield return (Path.Combine(roamingAppData, "superwhisper"), "Superwhisper");
        yield return (Path.Combine(localAppData, "superwhisper"), "Superwhisper");
        yield return (Path.Combine(localAppData, "Buzz"), "Buzz");
        yield return (Path.Combine(roamingAppData, "Buzz"), "Buzz");
        yield return (Path.Combine(localAppData, "WhisperDesktop"), "Whisper Desktop");
        yield return (Path.Combine(userProfile, ".cache", "whisper"), "whisper.cpp");
        yield return (Path.Combine(userProfile, "whisper.cpp", "models"), "whisper.cpp");
        yield return (Path.Combine(userProfile, ".cache", "huggingface", "hub"), "Hugging Face cache");
        yield return (Path.Combine(userProfile, "Downloads"), "Downloads");
    }

    public static List<WhisperModelFile> FindInstalledModels()
    {
        var foundModels = new List<WhisperModelFile>();
        var seenFullPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var (directoryPath, sourceName) in SearchLocations())
        {
            if (!Directory.Exists(directoryPath)) continue;
            var isDownloadsFolder = sourceName == "Downloads";
            var enumerationOptions = new EnumerationOptions
            {
                RecurseSubdirectories = true,
                MaxRecursionDepth = isDownloadsFolder ? 2 : 7,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.System
            };

            var visitedFileCount = 0;
            IEnumerable<string> candidateFiles;
            try { candidateFiles = Directory.EnumerateFiles(directoryPath, "*", enumerationOptions); }
            catch { continue; }

            foreach (var candidateFilePath in candidateFiles)
            {
                if (++visitedFileCount > 20_000) break;
                try
                {
                    var fileInfo = new FileInfo(candidateFilePath);
                    // Whisper models are at least ~30 MB; skip everything smaller without opening it.
                    if (fileInfo.Length < 25_000_000) continue;
                    var resolvedPath = fileInfo.LinkTarget != null ? Path.GetFullPath(fileInfo.LinkTarget, fileInfo.DirectoryName!) : fileInfo.FullName;
                    if (!seenFullPaths.Add(resolvedPath)) continue;
                    var inspectedModel = InspectModelFile(candidateFilePath, sourceName);
                    if (inspectedModel != null) foundModels.Add(inspectedModel);
                }
                catch
                {
                    // unreadable file; ignore
                }
            }
        }

        return foundModels.OrderByDescending(model => model.QualityRank).ToList();
    }

    /// <summary>
    /// Reads the 48-byte whisper.cpp header: magic 0x67676d6c ("ggml"), then n_vocab, n_audio_ctx,
    /// n_audio_state, n_audio_head, n_audio_layer, n_text_ctx, n_text_state, n_text_head,
    /// n_text_layer, n_mels, ftype as little-endian int32s.
    /// </summary>
    public static WhisperModelFile? InspectModelFile(string filePath, string sourceName)
    {
        using var fileStream = File.OpenRead(filePath);
        var headerBytes = new byte[48];
        if (fileStream.Read(headerBytes, 0, 48) != 48) return null;
        if (headerBytes[0] != 0x6c || headerBytes[1] != 0x6d || headerBytes[2] != 0x67 || headerBytes[3] != 0x67) return null;

        int HeaderInteger(int fieldIndex) => BitConverter.ToInt32(headerBytes, 4 + fieldIndex * 4);
        var vocabularySize = HeaderInteger(0);
        var audioLayerCount = HeaderInteger(4);
        if (vocabularySize is < 51000 or > 52000 || audioLayerCount is < 1 or > 64) return null;

        var fileType = HeaderInteger(10) % 1000; // may carry quantization version x 1000
        var quantizationName = fileType switch
        {
            0 => "f32", 1 => "f16", 2 => "q4_0", 3 => "q4_1", 7 => "q8_0", 8 => "q5_0", 9 => "q5_1",
            10 => "q2_k", 11 => "q3_k", 12 => "q4_k", 13 => "q5_k", 14 => "q6_k", _ => "q" + fileType
        };

        return new WhisperModelFile(filePath, fileStream.Length, sourceName, audioLayerCount, HeaderInteger(8), vocabularySize, HeaderInteger(9), quantizationName);
    }

    /// <summary>Downloads a model into OpenClicky's models folder, reporting progress 0..1.</summary>
    public static async Task<string> DownloadModelAsync(DownloadableModel model, IProgress<double> progress, CancellationToken cancellationToken)
    {
        var destinationPath = Path.Combine(AppPaths.WhisperModelsDirectory, model.FileName);
        var partialDownloadPath = destinationPath + ".part";

        using var httpClient = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        using var response = await httpClient.GetAsync(model.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        var totalByteCount = response.Content.Headers.ContentLength ?? 0;

        await using (var downloadStream = await response.Content.ReadAsStreamAsync(cancellationToken))
        await using (var fileStream = File.Create(partialDownloadPath))
        {
            var copyBuffer = new byte[1 << 16];
            long downloadedByteCount = 0;
            int readByteCount;
            while ((readByteCount = await downloadStream.ReadAsync(copyBuffer, cancellationToken)) > 0)
            {
                await fileStream.WriteAsync(copyBuffer.AsMemory(0, readByteCount), cancellationToken);
                downloadedByteCount += readByteCount;
                if (totalByteCount > 0) progress.Report((double)downloadedByteCount / totalByteCount);
            }
        }

        File.Move(partialDownloadPath, destinationPath, overwrite: true);
        return destinationPath;
    }
}

/// <summary>Runs Whisper in-process (whisper.cpp via Whisper.net). Keeps the model loaded between presses.</summary>
public sealed class WhisperTranscriber : IDisposable
{
    private WhisperFactory? loadedFactory;
    private string? loadedModelPath;
    private readonly SemaphoreSlim transcriptionGate = new(1, 1);

    /// <summary>Loads the model ahead of time so the first press is fast.</summary>
    public Task PreloadAsync(string modelPath) => Task.Run(async () =>
    {
        await transcriptionGate.WaitAsync();
        try { EnsureModelLoaded(modelPath); }
        catch (Exception loadError) { Log.Write($"Whisper preload failed: {loadError.Message}"); }
        finally { transcriptionGate.Release(); }
    });

    public async Task<string> TranscribeAsync(float[] samples, WhisperModelFile model, string vocabularyPrompt, CancellationToken cancellationToken)
    {
        // Under ~0.3 s there's nothing to transcribe, and Whisper tends to hallucinate on silence.
        if (samples.Length < 4_800) return "";

        await transcriptionGate.WaitAsync(cancellationToken);
        try
        {
            return await Task.Run(async () =>
            {
                var whisperFactory = EnsureModelLoaded(model.FilePath);
                var processorBuilder = whisperFactory.CreateBuilder()
                    .WithLanguage(model.IsEnglishOnly ? "en" : "auto")
                    .WithThreads(Math.Clamp(Environment.ProcessorCount - 2, 2, 8));
                if (!string.IsNullOrWhiteSpace(vocabularyPrompt))
                {
                    processorBuilder = processorBuilder.WithPrompt(vocabularyPrompt);
                }

                using var whisperProcessor = processorBuilder.Build();
                var transcriptBuilder = new System.Text.StringBuilder();
                var transcriptionStartTime = DateTime.Now;
                await foreach (var segment in whisperProcessor.ProcessAsync(samples, cancellationToken))
                {
                    transcriptBuilder.Append(segment.Text);
                }
                Log.Write($"Whisper ({model.DisplayName}) transcribed {samples.Length / 16000.0:0.0}s in {(DateTime.Now - transcriptionStartTime).TotalSeconds:0.00}s");
                return CleanWhisperOutput(transcriptBuilder.ToString());
            }, cancellationToken);
        }
        finally
        {
            transcriptionGate.Release();
        }
    }

    private WhisperFactory EnsureModelLoaded(string modelPath)
    {
        if (loadedFactory != null && string.Equals(loadedModelPath, modelPath, StringComparison.OrdinalIgnoreCase))
        {
            return loadedFactory;
        }
        loadedFactory?.Dispose();
        loadedFactory = WhisperFactory.FromPath(modelPath);
        loadedModelPath = modelPath;
        Log.Write($"Whisper model loaded: {modelPath}");
        return loadedFactory;
    }

    /// <summary>Drops Whisper's non-speech markers like [BLANK_AUDIO] or (music).</summary>
    private static string CleanWhisperOutput(string rawTranscript)
    {
        var withoutMarkers = System.Text.RegularExpressions.Regex.Replace(rawTranscript, @"\[[^\]]*\]", "");
        withoutMarkers = System.Text.RegularExpressions.Regex.Replace(withoutMarkers, @"\((?:music|applause|laughter|silence|noise|inaudible)[^)]*\)", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return System.Text.RegularExpressions.Regex.Replace(withoutMarkers, @"\s{2,}", " ").Trim();
    }

    public void Dispose()
    {
        loadedFactory?.Dispose();
        transcriptionGate.Dispose();
    }
}
