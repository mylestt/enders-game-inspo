using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace EndersServerManager;

// Persisted to %APPDATA%\EndersServerManager\settings.json. The SSH password is never
// stored in plain text: it is encrypted with Windows DPAPI scoped to the current user
// account, so only this Windows login can decrypt it.
public class AppSettings
{
    public string Host { get; set; } = "147.182.160.52";
    public int SshPort { get; set; } = 22;
    public string Username { get; set; } = "root";
    public string EncryptedPassword { get; set; } = "";
    public string LocalBinaryPath { get; set; } =
        @"C:\Users\myles\Documents\GitHub\enders-game-inspo\build\enders_server.x86_64";
    public string RemoteDirectory { get; set; } = "/root";
    public int GamePort { get; set; } = 7000;

    private static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "EndersServerManager");

    private static string FilePath => Path.Combine(Dir, "settings.json");

    public string RemoteBinaryPath => RemoteDirectory.TrimEnd('/') + "/enders_server.x86_64";

    public bool HasPassword => !string.IsNullOrEmpty(EncryptedPassword);

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch
        {
            // Corrupt settings fall back to defaults rather than blocking launch.
        }
        return new AppSettings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public void SetPassword(string plain)
    {
        var blob = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), null, DataProtectionScope.CurrentUser);
        EncryptedPassword = Convert.ToBase64String(blob);
    }

    public string GetPassword()
    {
        if (!HasPassword)
            return "";
        var blob = Convert.FromBase64String(EncryptedPassword);
        return Encoding.UTF8.GetString(ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser));
    }
}
