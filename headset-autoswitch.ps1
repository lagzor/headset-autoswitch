# =====================================================================
#  headset-autoswitch
#  Switches Windows audio to your wireless headset when it turns on, and
#  back to your speakers when it turns off.
#
#  Runs in the background at logon (scheduled task "HeadsetAutoswitch",
#  created by install.ps1). How the headset is detected depends on
#  "method" in settings.json:
#    fractal      listens to the Fractal Scape dongle, which reports when the
#                 headset turns on, turns off or is put on its stand
#    steelseries  asks the SteelSeries Arctis Nova Pro Wireless base station
#    device       the headset counts as on while its audio device is active
#                 in Windows (works for many USB and Bluetooth headsets)
#    auto         fractal or steelseries if that hardware is plugged in,
#                 otherwise device
#
#  Troubleshooting, run in PowerShell:
#    .\headset-autoswitch.ps1 -List      lists all audio devices
#    .\headset-autoswitch.ps1 -Test      shows the headset status every 2 seconds
#    .\headset-autoswitch.ps1 -Discover  records how a headset behaves when it is
#                                        turned off and on (saved to discover.txt)
# =====================================================================

param(
  [switch]$List,
  [switch]$Test,
  [switch]$Discover,
  [string]$Name = '',
  [int]$Seconds = 60
)

$ErrorActionPreference = 'Stop'
$Dir = Split-Path -Parent $PSCommandPath
$SettingsFile = Join-Path $Dir 'settings.json'
$StateFile = Join-Path $Dir 'state.json'
$LogFile = Join-Path $Dir 'log.txt'

$Defaults = [ordered]@{
  method             = 'auto'   # auto, fractal, steelseries or device
  headset            = ''       # part of the headset's audio device name (empty = from method)
  speakers           = ''       # part of the speakers' name (empty = whatever was default before the headset)
  switchMicrophone   = $true    # also switch the microphone to the headset while it is on
  fallbackMicrophone = ''       # microphone to use while the headset is off (empty = leave as is)
  pollSeconds        = 3
}

function Write-Log([string]$Text) {
  $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
  if ($Test -or $List) { Write-Host $line }
  try {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 524288) { Remove-Item $LogFile -Force }
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
  } catch { }
}

# Errors that stop the script end up in the log, also when it runs hidden.
trap {
  Write-Log "Stopped on an error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
  break
}

function Read-Settings {
  if (-not (Test-Path $SettingsFile)) {
    [IO.File]::WriteAllText($SettingsFile, ($Defaults | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  }
  $s = Get-Content -Path $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($k in $Defaults.Keys) { if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Defaults[$k] } }
  return $s
}

# ---------- Windows audio devices (Core Audio) ---------------------------------

$audioCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HeadsetAutoswitch {
  [StructLayout(LayoutKind.Sequential)]
  public struct PropertyKey { public Guid fmtid; public int pid; }

  [StructLayout(LayoutKind.Sequential)]
  public struct PropVariant { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }

  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int i, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
  }

  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
  }

  [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int i, out IMMDevice device);
  }

  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int flow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
  }

  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
  class MMDeviceEnumerator { }

  // Undocumented, but used by most audio switchers to change the default device.
  [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPolicyConfig {
    [PreserveSig] int GetMixFormat();
    [PreserveSig] int GetDeviceFormat();
    [PreserveSig] int ResetDeviceFormat();
    [PreserveSig] int SetDeviceFormat();
    [PreserveSig] int GetProcessingPeriod();
    [PreserveSig] int SetProcessingPeriod();
    [PreserveSig] int GetShareMode();
    [PreserveSig] int SetShareMode();
    [PreserveSig] int GetPropertyValue();
    [PreserveSig] int SetPropertyValue();
    [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
  }

  [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
  class PolicyConfigClient { }

  // State: 1 = active, 2 = disabled, 4 = not present, 8 = unplugged.
  public class Endpoint { public string Id; public string Name; public int State; }

  public static class Audio {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pv);

    // flow: 0 = playback, 1 = recording. Active devices only.
    public static List<Endpoint> List(int flow) { return List(flow, 1); }

    // All devices, whatever their state.
    public static List<Endpoint> ListAll(int flow) { return List(flow, 0xF); }

    static List<Endpoint> List(int flow, int mask) {
      var result = new List<Endpoint>();
      var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
      IMMDeviceCollection devices;
      Marshal.ThrowExceptionForHR(en.EnumAudioEndpoints(flow, mask, out devices));
      int count;
      devices.GetCount(out count);
      var nameKey = new PropertyKey { fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), pid = 14 };
      for (int i = 0; i < count; i++) {
        IMMDevice device;
        if (devices.Item(i, out device) != 0) continue;
        string id;
        device.GetId(out id);
        string name = id;
        IPropertyStore store;
        if (device.OpenPropertyStore(0, out store) == 0) {
          PropVariant v;
          if (store.GetValue(ref nameKey, out v) == 0) {
            if (v.vt == 31 && v.p != IntPtr.Zero) name = Marshal.PtrToStringUni(v.p);
            PropVariantClear(ref v);
          }
        }
        int state;
        device.GetState(out state);
        result.Add(new Endpoint { Id = id, Name = name, State = state });
      }
      return result;
    }

    public static string GetDefault(int flow) {
      var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
      IMMDevice device;
      if (en.GetDefaultAudioEndpoint(flow, 0, out device) != 0) return null;
      string id;
      device.GetId(out id);
      return id;
    }

    // Makes the device the default for all roles: console, multimedia and communications.
    public static void SetDefault(string id) {
      var pc = (IPolicyConfig)new PolicyConfigClient();
      for (int role = 0; role < 3; role++) Marshal.ThrowExceptionForHR(pc.SetDefaultEndpoint(id, role));
    }
  }
}
'@
if (-not ('HeadsetAutoswitch.Audio' -as [type])) { Add-Type -TypeDefinition $audioCode }

# ---------- Headsets (HID) ------------------------------------------------------
#
# SteelSeries Arctis Nova Pro Wireless: write report 06 b0 to interface 4 of
# the base station and read the reply. Byte 15 is the headset status
# (01 = off, 02 = charging by cable, 08 = on), byte 6 the battery (0-8).
# Protocol as documented by the HeadsetControl project.
#
# Fractal Scape: the dongle (36bc:0001, the interface with usage page ff00) is
# asked for its state every two seconds (report 02 11 21, the same question
# Fractal's Adjust page asks) and answers 02 11 21 00 xx: xx = 01 is on, 00 is
# off or on the stand. No answer for a while also counts as off.

$hidCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace HeadsetAutoswitch {
  public class HidInfo {
    public string Path; public string Product; public int Vid; public int Pid;
    public int UsagePage; public int Usage; public int InputLength; public int OutputLength; public int FeatureLength;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

  public static class Hid {
    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)] static extern bool HidD_GetProductString(SafeFileHandle h, System.Text.StringBuilder b, int len);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, byte[] caps);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll")] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int size, out int req, IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    // Device paths of present HID interfaces whose path contains the filter, e.g. "vid_1038&pid_12e0".
    public static List<string> Paths(string filter) {
      var res = new List<string>();
      Guid g; HidD_GetHidGuid(out g);
      IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
      try {
        var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
        for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d); i++) {
          int req; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
          IntPtr buf = Marshal.AllocHGlobal(req);
          try {
            Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
            if (SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero)) {
              string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
              if (path != null && path.ToLowerInvariant().Contains(filter)) res.Add(path);
            }
          } finally { Marshal.FreeHGlobal(buf); }
        }
      } finally { SetupDiDestroyDeviceInfoList(set); }
      return res;
    }

    public static bool Present(string filter) { return Paths(filter).Count > 0; }

    // All present HID interfaces whose path contains the filter, with their details.
    public static List<HidInfo> All(string filter) {
      var res = new List<HidInfo>();
      foreach (var path in Paths(filter)) {
        var info = Info(path);
        if (info != null) res.Add(info);
      }
      return res;
    }

    public static List<HidInfo> All() { return All("hid#"); }

    public static HidInfo Info(string path) {
      try {
        using (var h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
          if (h.IsInvalid) return null;
          var info = new HidInfo { Path = path };
          var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a);
          if (HidD_GetAttributes(h, ref a)) { info.Vid = a.VendorID; info.Pid = a.ProductID; }
          var sb = new System.Text.StringBuilder(256);
          if (HidD_GetProductString(h, sb, 512)) info.Product = sb.ToString();
          IntPtr pre;
          if (HidD_GetPreparsedData(h, out pre)) {
            var caps = new byte[64];
            try { HidP_GetCaps(pre, caps); } finally { HidD_FreePreparsedData(pre); }
            info.Usage = BitConverter.ToUInt16(caps, 0); info.UsagePage = BitConverter.ToUInt16(caps, 2);
            info.InputLength = BitConverter.ToUInt16(caps, 4); info.OutputLength = BitConverter.ToUInt16(caps, 6);
            info.FeatureLength = BitConverter.ToUInt16(caps, 8);
          }
          return info;
        }
      } catch { return null; }
    }

    public static SafeFileHandle Open(string path, bool write) {
      return CreateFile(path, write ? 0xC0000000 : 0x80000000, 3, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
    }

    public static string Hex(byte[] b, int n) { return BitConverter.ToString(b, 0, Math.Min(n, b.Length)).Replace("-", " "); }
  }

  // ---------- SteelSeries Arctis Nova Pro Wireless ----------------------------------
  public class SteelSeriesReply { public string Status = "unknown"; public int Battery = -1; public string Error; public string Raw; }

  public static class SteelSeries {
    public static readonly string[] Ids = { "vid_1038&pid_12e0", "vid_1038&pid_12e5" };

    public static bool Present() { foreach (var id in Ids) if (Hid.Present(id)) return true; return false; }

    public static SteelSeriesReply Query(int timeoutMs) {
      var reply = new SteelSeriesReply();
      var paths = new List<string>();
      foreach (var id in Ids) paths.AddRange(Hid.Paths(id));
      if (paths.Count == 0) { reply.Error = "Base station not found"; return reply; }
      var errors = new List<string>();
      // Interface 4 first.
      paths.Sort((a, b) => (b.ToLowerInvariant().Contains("mi_04") ? 1 : 0) - (a.ToLowerInvariant().Contains("mi_04") ? 1 : 0));
      foreach (var path in paths) {
        var info = Hid.Info(path);
        if (info == null || info.OutputLength < 2 || info.InputLength < 16) continue;
        try {
          using (var h = Hid.Open(info.Path, true)) {
            if (h.IsInvalid) { errors.Add("open: " + Marshal.GetLastWin32Error()); continue; }
            using (var fs = new FileStream(h, FileAccess.ReadWrite, 1, true)) {
              var outBuf = new byte[info.OutputLength];
              outBuf[0] = 0x06; outBuf[1] = 0xb0;
              var w = fs.WriteAsync(outBuf, 0, outBuf.Length);
              if (!w.Wait(timeoutMs)) { errors.Add("write: timeout"); continue; }
              var end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
              while (DateTime.UtcNow < end) {
                var inBuf = new byte[info.InputLength];
                var r = fs.ReadAsync(inBuf, 0, inBuf.Length);
                int left = (int)Math.Max(1, (end - DateTime.UtcNow).TotalMilliseconds);
                if (!r.Wait(left)) { errors.Add("read: timeout"); break; }
                if (r.Result < 16) continue;
                if (inBuf[0] != 0x06 || inBuf[1] != 0xb0) continue;   // another report, e.g. volume
                reply.Raw = Hid.Hex(inBuf, 20);
                reply.Battery = inBuf[6];
                byte st = inBuf[15];
                reply.Status = st == 0x01 ? "off" : st == 0x02 ? "charging" : st == 0x08 ? "on" : "unknown";
                if (reply.Status == "unknown") reply.Error = "Unknown status 0x" + st.ToString("x2");
                return reply;
              }
            }
          }
        } catch (AggregateException ex) {
          errors.Add(ex.InnerException != null ? ex.InnerException.Message : ex.Message);
        } catch (Exception ex) {
          errors.Add(ex.Message);
        }
      }
      reply.Error = "No reply from the base station (" + string.Join("; ", errors) + ")";
      return reply;
    }
  }

  // ---------- Fractal Scape -------------------------------------------------------------
  public static class Fractal {
    public const string Id = "vid_36bc&pid_0001";
    static readonly object gate = new object();
    static volatile bool running;
    static long lastReport;      // DateTime.UtcNow.Ticks of the last status report
    static long started;
    static int state = -1;       // 1 = on, 0 = off, -1 = nothing heard yet
    public static string Error;

    public static bool Present() { return Hid.Present(Id); }

    public static bool Start() {
      lock (gate) {
        if (running) return true;
        HidInfo target = null;
        foreach (var g in Hid.All(Id)) {
          if (g.UsagePage == 0xff00 && g.InputLength >= 5) { target = g; break; }
        }
        if (target == null) { Error = "Fractal Scape dongle not found"; return false; }
        var h = Hid.Open(target.Path, false);
        if (h == null || h.IsInvalid) { Error = "Could not open the Fractal Scape dongle (" + Marshal.GetLastWin32Error() + ")"; return false; }
        var fs = new FileStream(h, FileAccess.Read, 1, true);
        int length = target.InputLength;
        int outLength = Math.Max(3, target.OutputLength);
        // A second handle for asking: the dongle only reports its state when asked.
        var wh = Hid.Open(target.Path, true);
        FileStream ws = (wh == null || wh.IsInvalid) ? null : new FileStream(wh, FileAccess.Write, 1, true);
        if (ws == null) Error = "Could not open the Fractal Scape dongle for writing (" + Marshal.GetLastWin32Error() + ")";
        running = true;
        if (ws != null) Error = null;
        started = DateTime.UtcNow.Ticks;
        if (ws != null) Task.Run(async () => {
          var ask = new byte[outLength];
          ask[0] = 0x02; ask[1] = 0x11; ask[2] = 0x21;   // report 2: dongle, get state
          try {
            while (running) {
              try { await ws.WriteAsync(ask, 0, ask.Length); }
              catch (Exception ex) { Error = "Could not ask the dongle: " + ex.Message; }
              await Task.Delay(2000);
            }
          } finally {
            try { ws.Dispose(); } catch { }
          }
        });
        Task.Run(async () => {
          try {
            while (true) {
              var buf = new byte[length];
              int n = await fs.ReadAsync(buf, 0, buf.Length);
              if (n <= 0) break;
              if (n >= 5 && buf[0] == 0x02 && (buf[1] == 0x11 || buf[1] == 0xF1) && buf[2] == 0x21) {
                state = buf[4] == 0x01 ? 1 : 0;
                lastReport = DateTime.UtcNow.Ticks;
              }
            }
          } catch (Exception ex) {
            Error = "Stopped reading from the dongle: " + ex.Message;
          } finally {
            try { fs.Dispose(); } catch { }
            running = false;
          }
        });
        return true;
      }
    }

    // "on", "off" or "unknown" (right after start, before the dongle has reported).
    public static string Status(int quietSeconds) {
      if (!running && !Start()) return Error == "Fractal Scape dongle not found" ? "off" : "unknown";
      var now = DateTime.UtcNow.Ticks;
      var quiet = TimeSpan.FromSeconds(quietSeconds).Ticks;
      if (state == -1) return (now - started) > quiet ? "off" : "unknown";
      if ((now - lastReport) > quiet) return "off";
      return state == 1 ? "on" : "off";
    }
  }

  // ---------- Discover: records every report from a HID interface ------------------
  public static class Recorder {
    public static System.Collections.Concurrent.ConcurrentQueue<string> Lines = new System.Collections.Concurrent.ConcurrentQueue<string>();

    public static string Start(string path, string label, int inputLength) {
      if (inputLength < 1) return "no input reports";
      var h = Hid.Open(path, false);
      if (h.IsInvalid) return "could not be opened (" + Marshal.GetLastWin32Error() + ")";
      var fs = new FileStream(h, FileAccess.Read, 1, true);
      Task.Run(async () => {
        string previous = null;
        try {
          while (true) {
            var buf = new byte[inputLength];
            int n = await fs.ReadAsync(buf, 0, buf.Length);
            if (n <= 0) break;
            string hex = Hid.Hex(buf, Math.Min(n, 32));
            if (hex == previous) continue;
            previous = hex;
            Lines.Enqueue(DateTime.Now.ToString("HH:mm:ss.f") + "  HID " + label + ": " + hex);
          }
        } catch (Exception ex) {
          Lines.Enqueue(DateTime.Now.ToString("HH:mm:ss.f") + "  HID " + label + ": stopped reading (" + ex.Message + ")");
        }
      });
      return null;
    }
  }
}
'@
if (-not ('HeadsetAutoswitch.Fractal' -as [type])) { Add-Type -TypeDefinition $hidCode }

# ---------- Choosing devices ------------------------------------------------------------

function Find-Endpoint([int]$Flow, [string]$Part) {
  if (-not $Part) { return $null }
  $hits = @([HeadsetAutoswitch.Audio]::List($Flow) | Where-Object { $_.Name -like "*$Part*" })
  if (-not $hits.Count) { return $null }
  # Several with the same name: prefer the headphones / headset device.
  $best = $hits | Where-Object { $_.Name -match '^(Headphones|Headset|Microphone)' } | Select-Object -First 1
  if ($best) { return $best }
  return $hits[0]
}

function Set-Default([int]$Flow, $Endpoint) {
  if (-not $Endpoint) { return $false }
  if ([HeadsetAutoswitch.Audio]::GetDefault($Flow) -eq $Endpoint.Id) { return $false }
  [HeadsetAutoswitch.Audio]::SetDefault($Endpoint.Id)
  return $true
}

$script:LastError = $null
# Logs an error once, not every few seconds.
function Write-ErrorOnce([string]$Text) {
  if ($script:LastError -ne $Text) { Write-Log $Text; $script:LastError = $Text }
}

$script:AutoMethod = $null
$script:AutoMethodAt = [datetime]::MinValue

function Get-Method($S) {
  $m = "$($S.method)".ToLower()
  if ($m -eq 'fractal' -or $m -eq 'steelseries' -or $m -eq 'device') { return $m }
  # auto: look for known hardware at most once a minute.
  if (-not $script:AutoMethod -or ((Get-Date) - $script:AutoMethodAt).TotalSeconds -gt 60) {
    $found = 'device'
    if ([HeadsetAutoswitch.Fractal]::Present()) { $found = 'fractal' }
    elseif ([HeadsetAutoswitch.SteelSeries]::Present()) { $found = 'steelseries' }
    if ($script:AutoMethod -and $script:AutoMethod -ne $found) { Write-Log "Method changed to $found." }
    $script:AutoMethod = $found
    $script:AutoMethodAt = Get-Date
  }
  return $script:AutoMethod
}

# The part of the headset's audio device name to look for.
function Get-HeadsetName($S) {
  if ("$($S.headset)") { return "$($S.headset)" }
  switch (Get-Method $S) {
    'fractal' { return 'Fractal Scape' }
    'steelseries' { return 'Arctis Nova Pro' }
  }
  return ''
}

# ---------- Headset status ------------------------------------------------------------

function Get-DeviceStatus($S) {
  $part = Get-HeadsetName $S
  if (-not $part) { Write-ErrorOnce 'Set "headset" in settings.json to part of your headset''s name (see -List).'; return 'unknown' }
  $all = @([HeadsetAutoswitch.Audio]::ListAll(0) | Where-Object { $_.Name -like "*$part*" })
  if (@($all | Where-Object { $_.State -eq 1 }).Count) { return 'on' }
  return 'off'
}

function Get-FractalStatus {
  $st = [HeadsetAutoswitch.Fractal]::Status(8)
  if ([HeadsetAutoswitch.Fractal]::Error) { Write-ErrorOnce "Fractal: $([HeadsetAutoswitch.Fractal]::Error)" }
  return $st
}

function Get-SteelSeriesStatus {
  try {
    $r = [HeadsetAutoswitch.SteelSeries]::Query(1500)
    if ($r.Status -eq 'on' -or $r.Status -eq 'charging') { return 'on' }
    if ($r.Status -eq 'off') { return 'off' }
    if ($r.Error -eq 'Base station not found') { return 'off' }
    if ($r.Error) { Write-ErrorOnce "SteelSeries: $($r.Error)" }
  } catch {
    Write-ErrorOnce "SteelSeries: $($_.Exception.Message)"
  }
  return 'unknown'
}

# 'on', 'off' or 'unknown'.
function Get-HeadsetStatus {
  switch (Get-Method $settings) {
    'fractal' { return (Get-FractalStatus) }
    'steelseries' { return (Get-SteelSeriesStatus) }
  }
  return (Get-DeviceStatus $settings)
}

# ---------- Switching -------------------------------------------------------------------
# When the headset turns on, the current defaults are remembered (in state.json),
# so that audio goes back to the same speakers and microphone when it turns off.

function Read-State {
  try { if (Test-Path $StateFile) { return (Get-Content -Path $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { }
  return [pscustomobject]@{ playback = $null; recording = $null }
}

function Save-State($St) {
  try { [IO.File]::WriteAllText($StateFile, ($St | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Get-EndpointById([int]$Flow, [string]$Id) {
  if (-not $Id) { return $null }
  return [HeadsetAutoswitch.Audio]::List($Flow) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Invoke-Switch([string]$Status, $S) {
  $part = Get-HeadsetName $S
  if ($Status -eq 'on') {
    $headset = Find-Endpoint 0 $part
    if (-not $headset) { Write-ErrorOnce "No active audio device named '$part'. Run -List and fix ""headset"" in settings.json."; return }
    $st = Read-State
    $current = [HeadsetAutoswitch.Audio]::GetDefault(0)
    if ($current -and $current -ne $headset.Id) { $st.playback = $current }
    $mic = if ($S.switchMicrophone) { Find-Endpoint 1 $part } else { $null }
    $currentMic = [HeadsetAutoswitch.Audio]::GetDefault(1)
    if ($mic -and $currentMic -and $currentMic -ne $mic.Id) { $st.recording = $currentMic }
    Save-State $st
    $changed = Set-Default 0 $headset
    if ($mic) { Set-Default 1 $mic | Out-Null }
    if ($changed) { Write-Log "Headset on: audio to $($headset.Name)." }
  } elseif ($Status -eq 'off') {
    $st = Read-State
    $speakers = if ("$($S.speakers)") { Find-Endpoint 0 "$($S.speakers)" } else { Get-EndpointById 0 $st.playback }
    if (-not $speakers -and "$($S.speakers)") {
      Write-ErrorOnce "No active audio device named '$($S.speakers)'. Run -List and fix ""speakers"" in settings.json."
      return
    }
    if (-not $speakers) {
      # Nothing remembered yet (first start with the headset already on): take another active device.
      $others = @([HeadsetAutoswitch.Audio]::List(0) | Where-Object { -not ($part -and $_.Name -like "*$part*") })
      $speakers = $others | Where-Object { $_.Name -like 'Speakers*' } | Select-Object -First 1
      if (-not $speakers) { $speakers = $others | Select-Object -First 1 }
      if (-not $speakers) { Write-ErrorOnce 'No other active audio device to switch to.'; return }
    }
    if ($part -and $speakers.Name -like "*$part*") { return }
    $changed = Set-Default 0 $speakers
    $mic = if ("$($S.fallbackMicrophone)") { Find-Endpoint 1 "$($S.fallbackMicrophone)" } else { Get-EndpointById 1 $st.recording }
    if ($mic -and -not ($part -and $mic.Name -like "*$part*")) { Set-Default 1 $mic | Out-Null }
    if ($changed) { Write-Log "Headset off: audio to $($speakers.Name)." }
  }
}

# ---------- Modes ----------------------------------------------------------------------

if ($List) {
  $stateName = @{ 1 = 'active'; 2 = 'disabled'; 4 = 'not present'; 8 = 'unplugged' }
  foreach ($f in 0, 1) {
    Write-Host $(if ($f -eq 0) { 'Playback:' } else { 'Recording:' }) -ForegroundColor Cyan
    [HeadsetAutoswitch.Audio]::ListAll($f) | Where-Object { $_.State -ne 4 } | Sort-Object -Property @("State", "Name") | ForEach-Object {
      Write-Host ("  {0,-12} {1}" -f $stateName[$_.State], $_.Name)
    }
  }
  return
}

if ($Discover) {
  # Every line goes to the file right away, so nothing is lost if something fails.
  $file = Join-Path $Dir 'discover.txt'
  [IO.File]::WriteAllText($file, '', (New-Object Text.UTF8Encoding($true)))
  function Out-Line([string]$t, [string]$color = 'Gray') {
    Write-Host $t -ForegroundColor $color
    try { [IO.File]::AppendAllText($file, "$t`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
  }
  trap {
    Out-Line "ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" 'Red'
    continue
  }

  if (-not $Name) { $Name = Get-HeadsetName (Read-Settings) }
  if (-not $Name) {
    Out-Line 'Which headset? Run again with -Name and part of its name, e.g. -Name "Arctis".' 'Yellow'
    Out-Line 'Audio devices:' 'Cyan'
    foreach ($e in [HeadsetAutoswitch.Audio]::List(0)) { Out-Line "  $($e.Name)" }
    return
  }

  Out-Line "Discover $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), looking for '$Name'" 'Cyan'
  Out-Line ''
  Out-Line 'Audio devices (1 = active, 2 = disabled, 4 = not present, 8 = unplugged):' 'Cyan'
  foreach ($f in 0, 1) {
    foreach ($e in [HeadsetAutoswitch.Audio]::ListAll($f)) {
      if ($e.State -eq 4) { continue }
      Out-Line ("  {0} [{1}] {2}" -f $(if ($f -eq 0) { 'out' } else { 'in ' }), $e.State, $e.Name)
    }
  }

  # Everything that belongs to the same physical device (same ContainerId) as the matches.
  Out-Line ''
  Out-Line 'Windows devices that belong to the headset:' 'Cyan'
  Write-Host '  (searching, takes a few seconds)' -ForegroundColor DarkGray
  $vidpid = New-Object System.Collections.Generic.HashSet[string]
  $pnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
  $container = @{}
  $pnp | Get-PnpDeviceProperty -KeyName DEVPKEY_Device_ContainerId -ErrorAction SilentlyContinue | ForEach-Object { $container[$_.InstanceId] = "$($_.Data)" }
  $containers = @($pnp | Where-Object { $_.FriendlyName -match $Name } | ForEach-Object { $container[$_.InstanceId] } | Where-Object { $_ -and $_ -ne '{00000000-0000-0000-ffff-ffffffffffff}' } | Select-Object -Unique)
  $related = @($pnp | Where-Object { ($containers -contains $container[$_.InstanceId]) -or ($_.FriendlyName -match $Name) })
  foreach ($d in $related) {
    Out-Line ("  [{0}] {1} | {2} | {3}" -f $d.Status, $d.Class, $d.FriendlyName, $d.InstanceId)
    if ($d.InstanceId -match 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { [void]$vidpid.Add(("{0}:{1}" -f $Matches[1], $Matches[2]).ToLower()) }
  }
  if (-not $related.Count) { Out-Line "  Nothing matches '$Name'. Run again with -Name and part of the name." 'Yellow' }

  Out-Line ''
  Out-Line 'HID interfaces:' 'Cyan'
  $interfaces = @([HeadsetAutoswitch.Hid]::All() | Where-Object {
      $vidpid.Contains(("{0:x4}:{1:x4}" -f $_.Vid, $_.Pid)) -or ("$($_.Product)" -match $Name)
    })
  $i = 0
  foreach ($g in $interfaces) {
    $i++
    $label = "#$i"
    Out-Line ("  {0} {1:x4}:{2:x4} '{3}' usage {4:x4}/{5:x4} in {6} out {7} feature {8}" -f $label, $g.Vid, $g.Pid, $g.Product, $g.UsagePage, $g.Usage, $g.InputLength, $g.OutputLength, $g.FeatureLength)
    $err = [HeadsetAutoswitch.Recorder]::Start($g.Path, $label, $g.InputLength)
    if ($err) { Out-Line "      not listening: $err" 'DarkGray' }
  }
  if (-not $interfaces.Count) { Out-Line '  No HID interfaces found.' 'Yellow' }

  Out-Line ''
  Out-Line "Listening for $Seconds seconds. With a few seconds between each step:" 'Cyan'
  Out-Line '  1. Turn the headset off.' 'White'
  Out-Line '  2. Turn it on again.' 'White'
  Out-Line '  3. If it has a stand or dock: put it there, then lift it off again.' 'White'
  Out-Line ''

  $previous = @{}
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    foreach ($f in 0, 1) {
      foreach ($e in [HeadsetAutoswitch.Audio]::ListAll($f)) {
        $key = "$f|$($e.Id)"
        if ($previous.ContainsKey($key) -and $previous[$key] -ne $e.State) {
          Out-Line ("{0:HH:mm:ss.f}  AUDIO {1} '{2}': {3} -> {4}" -f (Get-Date), $(if ($f -eq 0) { 'out' } else { 'in' }), $e.Name, $previous[$key], $e.State) 'Green'
        }
        $previous[$key] = $e.State
      }
    }
    foreach ($d in $related) {
      $st = (Get-PnpDevice -InstanceId $d.InstanceId -ErrorAction SilentlyContinue).Status
      $key = "pnp|$($d.InstanceId)"
      if ($previous.ContainsKey($key) -and $previous[$key] -ne $st) {
        Out-Line ("{0:HH:mm:ss.f}  DEVICE '{1}': {2} -> {3}" -f (Get-Date), $d.FriendlyName, $previous[$key], $st) 'Green'
      }
      $previous[$key] = $st
    }
    $line = $null
    while ([HeadsetAutoswitch.Recorder]::Lines.TryDequeue([ref]$line)) { Out-Line $line 'Yellow' }
    Start-Sleep -Milliseconds 400
  }
  Out-Line ''
  Out-Line 'Done.' 'Cyan'
  Write-Host "Saved to $file" -ForegroundColor DarkGray
  return
}

$settings = Read-Settings

if ($Test) {
  $method = Get-Method $settings
  $part = Get-HeadsetName $settings
  $h = Find-Endpoint 0 $part
  Write-Host "Method:   $method" -ForegroundColor Cyan
  Write-Host "Headset:  $(if ($h) { $h.Name } elseif ($part) { "'$part' (not active right now)" } else { 'not set, see -List' })"
  Write-Host "Speakers: $(if ("$($settings.speakers)") { $settings.speakers } else { 'whatever was default before the headset turned on' })"
  Write-Host 'Turn the headset off and on and watch the status change. Ctrl+C to stop.' -ForegroundColor Cyan
  while ($true) {
    Write-Host ('{0:HH:mm:ss}  headset: {1}' -f (Get-Date), (Get-HeadsetStatus))
    Start-Sleep -Seconds 2
  }
}

# Background mode: follows the headset. A new status must be seen twice in a
# row before audio is switched, so a single odd reading does not move it.
# After sleep (a long gap between two rounds) audio is set right again,
# since Windows sometimes changes the default device when it wakes up.
$last = Get-HeadsetStatus
for ($w = 0; $last -eq 'unknown' -and $w -lt 10; $w++) { Start-Sleep -Seconds 1; $last = Get-HeadsetStatus }
$script:LastReported = $last
$defaultName = ([HeadsetAutoswitch.Audio]::List(0) | Where-Object { $_.Id -eq [HeadsetAutoswitch.Audio]::GetDefault(0) }).Name
Write-Log "Started. Method: $(Get-Method $settings). Headset: $last. Default device: $defaultName"
try { Invoke-Switch $last $settings } catch { Write-Log "Error: $($_.Exception.Message)" }
$candidate = $null
$previousRound = Get-Date
$lastAlive = Get-Date
while ($true) {
  Start-Sleep -Seconds ([Math]::Max(1, [int]$settings.pollSeconds))
  $now = Get-Date
  $woke = ($now - $previousRound).TotalSeconds -gt 60
  $previousRound = $now
  if (($now - $lastAlive).TotalHours -ge 6) { Write-Log "Running. Headset: $last."; $lastAlive = $now }

  $status = Get-HeadsetStatus
  if ($status -ne $script:LastReported) { Write-Log "Headset reports: $status"; $script:LastReported = $status }
  if ($status -eq 'unknown') { $candidate = $null; continue }
  if ($woke) {
    Write-Log 'The computer woke up, checking audio.'
    try { $settings = Read-Settings; Invoke-Switch $status $settings; $last = $status } catch { Write-Log "Error: $($_.Exception.Message)" }
    $candidate = $null
    continue
  }
  if ($status -eq $last) { $candidate = $null; continue }
  if ($candidate -ne $status) { $candidate = $status; continue }
  try {
    $settings = Read-Settings
    Invoke-Switch $status $settings
    $last = $status
  } catch {
    Write-Log "Error: $($_.Exception.Message)"
  }
  $candidate = $null
}
