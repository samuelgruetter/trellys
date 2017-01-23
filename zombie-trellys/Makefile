# Main Rules
# ==========
#
# make [all]: does a sandboxed install of zombie trellys.
#             Assumes you have Cabal installed, and that the default
#             Cabal install dir is on your path (~/.cabal/bin for
#             default "per-user" setup).

.PHONY: all sandbox-install sandbox-trellys \
	    clean test ghci cabal-dev-ghci

all: sandbox-install

sandbox-install: sandbox-trellys

.cabal-sandbox:
	cabal sandbox init

sandbox-trellys: .cabal-sandbox
	cabal install --disable-documentation .
	ln -fs `pwd`/.cabal-sandbox/bin/trellys test

test:
	cd test && make

etags:
	find ./ -name .svn -prune -o -name '*.hs' -print | xargs hasktags --etags

# Start ghci through cabal-dev.
#
# This kind of works, but I'm not sure how to load the Trellys (main)
# module here and it's not available from `:m + Trellys` in the ghci
# started.
cabal-dev-ghci:
	cd src && cabal-dev ghci
