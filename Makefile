mixd:
	odin build ./mixologist_daemon -out:builds/mixd -debug -show-timings -vet-unused -define:LOG_LEVEL=info

mixcli:
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -vet-unused -define:LOG_LEVEL=info

mixd-dbg:
	odin build ./mixologist_daemon -out:builds/mixd -debug -show-timings -vet-unused

mixcli-dbg:
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -vet-unused
