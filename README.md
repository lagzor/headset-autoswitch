# headset-autoswitch

Auto-switch Windows audio between your wireless headset and speakers when the headset turns on or off.

Turn the headset on and Windows switches playback (and the microphone) to it. Turn it off, or put it on its stand, and audio goes back to the speakers you used before. No vendor software running in the background, no tray icon: one small PowerShell script started hidden at logon.

## Why

Many wireless headsets use a USB dongle or base station that stays plugged in. Windows sees the headset's audio device as present all the time, so it never switches by itself when you turn the headset off. Vendor apps can do it, but they are large and do a lot more than that. This script asks the dongle directly whether the headset is on.

## Supported headsets

| Headset | Method | How it is detected |
| --- | --- | --- |
| Fractal Design Scape | `fractal` | The dongle is asked for the headset's state every couple of seconds. Off, or on the stand, means it answers off (or does not answer). |
| SteelSeries Arctis Nova Pro Wireless | `steelseries` | Asks the base station for the headset status. |
| Most other USB and Bluetooth headsets | `device` | The headset counts as on while its audio device is active in Windows. Works for headsets whose audio device disappears when they turn off. |

With the default `"method": "auto"`, the script picks `fractal` or `steelseries` when that dongle is plugged in, and `device` otherwise.

Got a headset that does not work? See [Adding a headset](#adding-a-headset).

## Install

1. Download the repository (**Code > Download ZIP**) and unzip it.
2. Double-click **`install.cmd`**.

That's it. The script is copied to `%LOCALAPPDATA%\HeadsetAutoswitch` and a scheduled task named `HeadsetAutoswitch` starts it hidden at every logon. Admin rights are not needed. If your account is not allowed to create scheduled tasks, the installer uses a shortcut in your Startup folder instead.

Running `install.cmd` again updates to the version you downloaded and keeps your settings.

Requirements: Windows 10 or 11 with Windows PowerShell 5.1 (built in).

## Uninstall

Double-click **`uninstall.cmd`**. It stops the script, removes the scheduled task and deletes `%LOCALAPPDATA%\HeadsetAutoswitch`. To keep your settings, run `uninstall.cmd -KeepSettings` from a command prompt.

## Configuration

`%LOCALAPPDATA%\HeadsetAutoswitch\settings.json` is created on first start. Changes are picked up at the next switch, no restart needed.

```json
{
  "method": "auto",
  "headset": "",
  "speakers": "",
  "switchMicrophone": true,
  "fallbackMicrophone": "",
  "pollSeconds": 3
}
```

| Setting | Meaning |
| --- | --- |
| `method` | `auto`, `fractal`, `steelseries` or `device`. |
| `headset` | Part of the headset's audio device name. Empty uses `Fractal Scape` or `Arctis Nova Pro` for those methods; for `device` you need to set it. |
| `speakers` | Part of the speakers' name. Empty means "whatever was the default before the headset turned on". |
| `switchMicrophone` | Also make the headset's microphone the default while it is on. |
| `fallbackMicrophone` | Microphone to switch to when the headset turns off. Empty means the one that was default before. |
| `pollSeconds` | How often the headset is checked. |

To see the names of your audio devices:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\HeadsetAutoswitch\headset-autoswitch.ps1" -List
```

Device names are matched on any part of the name, so `"speakers": "Realtek"` matches `Speakers (Realtek USB Audio)`.

## Troubleshooting

**Check the log.** Everything the script does ends up in `%LOCALAPPDATA%\HeadsetAutoswitch\log.txt`: when it starts, what the headset reports and every switch.

**Watch the status live.** Turn the headset off and on while this runs:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\HeadsetAutoswitch\headset-autoswitch.ps1" -Test
```

**It switches to the wrong device.** Set `headset` and/or `speakers` in `settings.json` using names from `-List`.

**"running scripts is disabled on this system".** Use `install.cmd`, or start PowerShell scripts with `powershell -ExecutionPolicy Bypass -File ...` as in the examples above. The installed task already does this.

**Vendor software fights it.** If SteelSeries GG / Sonar or similar also switches devices, turn that feature off there, or stop using one of them.

## Adding a headset

If your headset is not listed and `device` mode does not work for it, the dongle probably reports its status in a way the script does not know yet. The `-Discover` mode records it:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\HeadsetAutoswitch\headset-autoswitch.ps1" -Discover -Name "part of the headset name"
```

It lists the headset's audio devices, Windows devices and HID interfaces, then listens for 60 seconds while you turn the headset off, on, and (if it has one) put it on its stand and lift it off again. Everything is saved to `discover.txt` in the same folder.

Open an [issue](../../issues) with your headset model and `discover.txt` attached, or send a pull request. This is how Fractal Scape support was added.

## How it works

- Default devices are changed through the Windows Core Audio API (`IPolicyConfig`, the same undocumented interface most audio switchers use), for all three roles: console, multimedia and communications.
- Headsets are read through the HID API directly from inline C# compiled at start, so no external tools are needed.
- A new status has to be seen twice in a row before audio is switched, so one odd reading does not move it.
- After sleep, the audio devices are set right again, since Windows sometimes changes the default device on wake.

## Credits

- The SteelSeries Arctis Nova Pro Wireless status query is based on the protocol documented by [HeadsetControl](https://github.com/Sapd/HeadsetControl). No HeadsetControl code is included.
- The Fractal Design Scape status reports were worked out with `-Discover`.

This project is not affiliated with, endorsed by or supported by Fractal Design or SteelSeries. Product names are trademarks of their respective owners.

## License

[MIT](LICENSE)
