SRC := $(shell find src -name "*.md")

.PHONY: all clean deploy serve build-html test
all: build-html test

define make-html-target
$(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/www/%/index.html,$1)): $1 footer.md macros.md style.css Makefile mdp
	codespell $1
	mkdir -p $(patsubst %/index/,%/,$(patsubst src/%.md, build/preprocess/%/,$1))
	./mdp macros.md $1 footer.md -o $(patsubst %/index/index.md,%/index.md,$(patsubst src/%.md, build/preprocess/%/index.md,$1))
	mkdir -p $(patsubst %/index/,%/,$(patsubst src/%.md, build/www/%/,$1))
	pandoc --shift-heading-level-by=-1 --standalone --embed-resources \
		$(patsubst %/index/index.md,%/index.md,$(patsubst src/%.md, build/preprocess/%/index.md,$1)) \
		--css style.css \
		-o $(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/www/%/index.html,$1))
build-html:: $(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/www/%/index.html,$1))
endef
$(foreach srcfile,$(SRC),$(eval $(call make-html-target,$(srcfile))))

clean:
	rm -rf build

deploy: all
	rsync -rav build/www/. root@wren.wtf:/var/www/www.wren.wtf

serve: all
	python3 -m http.server -d build/www

test:
	make -C test
