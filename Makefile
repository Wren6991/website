.PHONY: all

all:
	mkdir -p build
	pandoc src/index.md -o build/index.html -s

clean:
	rm -rf build

