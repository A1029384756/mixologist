all: mixd mixcli mixgui

install:
	install -d $(DESTDIR)/usr/bin
	install -m 0755 builds/mixd $(DESTDIR)/usr/bin/mixd
	install -m 0755 builds/mixcli $(DESTDIR)/usr/bin/mixcli
	install -m 0755 builds/mixgui $(DESTDIR)/usr/bin/mixgui

	install -d $(DESTDIR)/usr/lib/systemd/user
	install -m 0644	data/mixd.service $(DESTDIR)/usr/lib/systemd/user/mixd.service
	install -d $(DESTDIR)/usr/lib/systemd/user-preset
	install -m 0644	data/50-mixd.preset $(DESTDIR)/usr/lib/systemd/user-preset/50-mixd.preset

	install -d $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -m 0644 data/mixologist.svg $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -d $(DESTDIR)/usr/share/applications
	install -m 0644 data/mixologist.desktop $(desktop)/usr/share/applications

clean:
	rm builds/mixd
	rm builds/mixcli
	rm builds/mixgui

mixd:
	mkdir -p builds/
	odin build ./mixologist_daemon -out:builds/mixd -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixd-dbg:
	mkdir -p builds/
	odin build ./mixologist_daemon -out:builds/mixd -debug -show-timings -vet-unused -internal-cached

mixcli:
	mkdir -p builds/
	odin build ./mixologist_cli -out:builds/mixcli -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixcli-dbg:
	mkdir -p builds/
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -vet-unused -internal-cached

mixgui:
	mkdir -p builds/
	odin build ./mixologist_gui -out:builds/mixgui -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixgui-dbg:
	mkdir -p builds/
	odin build ./mixologist_gui -out:builds/mixgui -debug -show-timings  -internal-cached
