all: mixcli mix

install:
	install -d $(DESTDIR)/usr/bin
	install -m 0755 builds/mixcli $(DESTDIR)/usr/bin/mixcli
	install -m 0755 builds/mixologist $(DESTDIR)/usr/bin/mixologist

	install -d $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -m 0644 data/mixologist.svg $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -d $(DESTDIR)/usr/share/applications
	install -m 0644 data/mixologist.desktop $(desktop)/usr/share/applications

clean:
	rm builds/mixcli
	rm builds/mixologist

mixcli:
	mkdir -p builds/
	odin build ./mixologist_cli -out:builds/mixcli -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mixcli-dbg:
	mkdir -p builds/
	odin build ./mixologist_cli -out:builds/mixcli -debug -show-timings -vet-unused -internal-cached

mix:
	mkdir -p builds/
	odin build ./mixologist -out:builds/mixologist -show-timings -vet-unused -define:LOG_LEVEL=info -internal-cached

mix-dbg:
	mkdir -p builds/
	odin build ./mixologist -out:builds/mixologist -debug -show-timings  -internal-cached

shaders:
	mkdir -p mixologist/resources/shaders/compiled
	glslangValidator -V mixologist/resources/shaders/raw/ui.vert -o mixologist/resources/shaders/compiled/ui.vert.spv
	glslangValidator -V mixologist/resources/shaders/raw/ui.frag -o mixologist/resources/shaders/compiled/ui.frag.spv

shaders-dbg:
	mkdir -p mixologist/resources/shaders/compiled
	glslangValidator -g -V mixologist/resources/shaders/raw/ui.vert -o mixologist/resources/shaders/compiled/ui.vert.spv
	glslangValidator -g -V mixologist/resources/shaders/raw/ui.frag -o mixologist/resources/shaders/compiled/ui.frag.spv

flat:
	flatpak build-bundle repo builds/mixologist.flatpak dev.cstring.Mixologist --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo
