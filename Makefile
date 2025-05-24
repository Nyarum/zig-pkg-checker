
install:
	mkdir -p libs
	git clone -b 098eee58cf62928aaf504af459855f0b8a5d5698 git@github.com:nDimensional/zig-sqlite.git libs/zig-sqlite
	git clone -b 18ec7f1129ce4d0573b7c67f011b4d05c7b195d4 git@github.com:tardy-org/zzz.git libs/zzz

dev:
	mkdir -p libs
	git clone -b 0.14.0 https://github.com/ziglang/zig.git libs/zig