# Mixologist
A utility for mixing your audio between programs.
Experience changing audio levels without having
to dig through a volume mixer wtih quick and easy
program based filtering.

Mixologist uses [PipeWire](https://pipewire.org) to
rewire connections on the fly to two separate
channels as you see fit. Raise the volume of your
discord call and lower the volume of your game
without having to touch any audio settings.

![Diagram](assets/mixologist-diagram.png)

---

> [!WARNING]
> This is **ALPHA** software, breaking changes
> will be kept to a minimum but are possible

## Getting Started
Mixologist can be installed via the latest 
[release](https://github.com/A1029384756/mixologist/releases).

### Building from Source
Dependencies:
- [Odin](https://odin-lang.org)
- `libpipewire`
- `sdl2` (for mixgui)
- `systemd` (if using systemd unit)

```
$ make
$ sudo make install
```

## Usage
If using `systemd`, the Mixologist daemon
(`mixd`) should start at launch.
`mixcli` can then be used as shown:

```
Flags:
	-add-program:<string>, multiple     | name of program to add to aux
	-remove-program:<string>, multiple  | name of program to remove from aux
	-set-volume:<f32>                   | volume to assign nodes
	-shift-volume:<f32>                 | volume to increment nodes
```

If you wish to have hardware volume control,
set keybinds in your desktop environment to the
corresponding `mixcli` command that you wish to
invoke. For example:
```
Shift + F10 -> mixcli -set-volume:0 #resets volume
Shift + F11 -> mixcli -shift-volume:-0.1 #balance one way
Shift + F12 -> mixcli -shift-volume:0.1 #balance the other way
```

Volume is a single value that can range from -1 to 1 where:
- 0 is both channels at full volume
- 1 is only the programs in the "program list"
- -1 is only every other program

### Configuration
The config file resides at `~/.config/mixologist/mixologist.conf`
and is a list of programs (one per line). This represents
the set of programs you wish to isolate. The config file
is hot-reloaded and can be modified by `mixcli` or just
editing it with your favorite text editor.

## Planned Features
- [ ] GUI
- [ ] Flatpak distribution (GUI-only)
- [ ] Improved Packaging for:
    - Debian
    - NixOS
