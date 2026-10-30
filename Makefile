# `make hooks` runs every pre-commit hook (lint, then the python and pi tests)
# over the whole repo, which is what CI runs. `make check` adds the neovim tests
# (they need a current neovim with the lazy-installed plugins).
.PHONY: check hooks test test-python test-pi test-neovim

# git sets these for the hook it runs; left in place, they point the tests'
# own git calls in temp repos at this repo's index.
unexport GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE

check: hooks test-neovim

hooks:
	pre-commit run --all-files

test: test-python test-pi test-neovim

test-python:
	@for test in $$(git ls-files '*_test.py'); do \
		echo "== $$test"; python3 -m unittest "$$test" || exit 1; \
	done
	python3 install.py --verify-idempotent

test-pi:
	cd pi/extensions && npm ci --silent && npm run check

test-neovim:
	nvim --headless --clean -l neovim/tests/codediff_base.lua
	nvim --headless --clean -l neovim/tests/codediff_wrap.lua
