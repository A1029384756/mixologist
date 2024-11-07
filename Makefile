mixd:
	odin build ./mixologist_daemon -out:builds/mixd -debug -show-timings -define:LOG_LEVEL=info

mixcli:
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -define:LOG_LEVEL=info
