SRC := $(shell find src -name "*.md")

.PHONY: all clean deploy serve build-html
all: build-html

define make-html-target
$(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/%/index.html,$1)): $1 style.css Makefile
	codespell $1
	mkdir -p $(patsubst %/index/,%/,$(patsubst src/%.md, build/%/,$1))
	pandoc --shift-heading-level-by=-1 --standalone --embed-resources $1 \
		--css style.css \
		-o $(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/%/index.html,$1))
build-html:: $(patsubst %/index/index.html,%/index.html,$(patsubst src/%.md, build/%/index.html,$1))
endef
$(foreach srcfile,$(SRC),$(eval $(call make-html-target,$(srcfile))))

clean:
	rm -rf build

deploy: all
	rsync -rav build/. root@wren.wtf:/var/www/www.wren.wtf

serve: all
	python3 -m http.server -d build
