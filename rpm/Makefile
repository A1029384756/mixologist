.PHONY: rpm
rpm:
	spectool -g mixologist.spec
	rpmbuild -ba \
		--define '_sourcedir $(shell pwd)' \
		--define '_rpmdir %{_sourcedir}/RPMS' \
		--define '_srcrpmdir %{_sourcedir}/SRPMS' \
		--define '_builddir %{_sourcedir}/BUILD' \
		mixologist.spec
	@echo ___RPMS can be found in rpm/RPMS/.___
	@echo ___Undo any changes to Version, Source0 and %autosetup in rpm/mixologist.spec before committing.___
