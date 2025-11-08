SRC := $(shell find src -name "*.md")

.PHONY: all clean deploy build-html
all: build/index.html build-html

define make-html-target
$(patsubst src/%.md, build/%/index.html,$1): $1
	mkdir -p $(patsubst src/%.md, build/%/,$1)
	pandoc -s $1 -o $(patsubst src/%.md, build/%/index.html,$1)
build-html:: $(patsubst src/%.md, build/%/index.html,$1)
endef
$(foreach srcfile,$(SRC),$(eval $(call make-html-target,$(srcfile))))

build/index.html: index.md
	mkdir -p build
	pandoc index.md -o build/index.html -s

clean:
	rm -rf build

deploy: all
	scp -r build/* root@176.126.244.103:/var/www/www.wren.wtf

