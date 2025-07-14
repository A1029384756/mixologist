all: mixologist

install:
	install -d $(DESTDIR)/usr/bin
	install -m 0755 builds/mixologist $(DESTDIR)/usr/bin/mixologist

	install -d $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -m 0644 data/mixologist.svg $(DESTDIR)/usr/share/icons/hicolor/scalable/apps
	install -d $(DESTDIR)/usr/share/applications
	install -m 0644 data/mixologist.desktop $(desktop)/usr/share/applications

clean:
	rm builds/mixcli
	rm builds/mixologist

mixologist:
	mkdir -p builds/
	odin build ./src -out:builds/mixologist -show-timings -vet-unused-variables -define:LOG_LEVEL=info -internal-cached

mixologist-dbg:
	mkdir -p builds/
	odin build ./src -out:builds/mixologist -debug -show-timings  -internal-cached

shaders:
	mkdir -p src/resources/shaders/compiled
	glslangValidator -V src/resources/shaders/raw/ui.vert -o src/resources/shaders/compiled/ui.vert.spv
	glslangValidator -V src/resources/shaders/raw/ui.frag -o src/resources/shaders/compiled/ui.frag.spv

shaders-dbg:
	mkdir -p src/resources/shaders/compiled
	glslangValidator -g -V src/resources/shaders/raw/ui.vert -o src/resources/shaders/compiled/ui.vert.spv
	glslangValidator -g -V src/resources/shaders/raw/ui.frag -o src/resources/shaders/compiled/ui.frag.spv

flat:
	flatpak-builder --force-clean --user --install-deps-from=flathub --repo=repo builddir ./flatpak/dev.cstring.mixologist.yml
	flatpak build-bundle repo builds/mixologist.flatpak dev.cstring.Mixologist --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo
