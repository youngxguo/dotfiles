# `make check` is what CI runs, minus the neovim tests (they need a current
# neovim with the lazy-installed plugins).
.PHONY: check lint test test-python test-pi test-neovim

check: lint test

lint:
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
