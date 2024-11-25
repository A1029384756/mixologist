mixd:
	odin build ./mixologist_daemon -out:builds/mixd -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixd-dbg:
	odin build ./mixologist_daemon -out:builds/mixd -debug -show-timings -vet-unused -internal-cached

mixcli:
	odin build ./mixologist_cli -out:builds/mixcli -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixcli-dbg:
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -vet-unused -internal-cached

mixgui:
	odin build ./mixologist_gui -out:builds/mixgui -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixgui-dbg:
	odin build ./mixologist_gui -out:builds/mixgui -debug -show-timings -vet-unused -internal-cached
