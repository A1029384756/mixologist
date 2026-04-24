APP_ID = mixologist
PREFIX = /usr

all: shaders mixologist

install: shaders mixologist
	install -Dm0755 builds/mixologist $(DESTDIR)$(PREFIX)/bin/$(APP_ID)
	install -Dm0644 data/mixologist.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APP_ID).svg                                               
	install -Dm0644 data/mixologist.desktop $(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop     

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(APP_ID)                                                                                                               
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APP_ID).svg                                                                             
	rm -f $(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop                                                                                        

clean:
	rm builds/mixologist

mixologist:
	mkdir -p builds/
	odin build ./src -out:builds/$(APP_ID) -show-timings -vet-unused-variables -define:LOG_LEVEL=info $(EXTRA_ODIN_FLAGS)

mixologist-dbg:
	mkdir -p builds/
	odin build ./src -out:builds/mixologist -debug -show-timings

shaders:
	mkdir -p src/ui/resources/shaders/compiled
	glslangValidator -V src/ui/resources/shaders/raw/ui.vert -o src/ui/resources/shaders/compiled/ui.vert.spv
	glslangValidator -V src/ui/resources/shaders/raw/ui.frag -o src/ui/resources/shaders/compiled/ui.frag.spv

shaders-dbg:
	mkdir -p src/ui/resources/shaders/compiled
	glslangValidator -g -V src/ui/resources/shaders/raw/ui.vert -o src/ui/resources/shaders/compiled/ui.vert.spv
	glslangValidator -g -V src/ui/resources/shaders/raw/ui.frag -o src/ui/resources/shaders/compiled/ui.frag.spv

flat:
	flatpak-builder --disable-rofiles-fuse --force-clean --user --install-deps-from=flathub --repo=repo builddir ./flatpak/dev.cstring.Mixologist.yml
	flatpak build-bundle repo builds/mixologist.flatpak dev.cstring.Mixologist --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo
